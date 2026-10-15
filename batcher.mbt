///|
/// Collect updates in geometrically sized sorted chains, then seal intervals at
/// arbitrary antichain frontiers. The explicit minimum adapts Rust Timestamp.
pub struct Batcher[D, T, R] {
  priv logger : TraceLogger?
  priv chains : Array[Array[(D, T, R)]]
  priv minimum : T
  priv mut lower : Antichain[T]
  priv mut retained_frontier : Antichain[T]
}

///|
pub fn[D, T : Lattice, R] Batcher::Batcher(
  minimum : T,
  logger? : TraceLogger,
) -> Batcher[D, T, R] {
  {
    logger,
    chains: [],
    minimum,
    lower: Antichain([minimum]),
    retained_frontier: Antichain([]),
  }
}

///|
/// Consume a chunk; sorting and consolidation are performed before merging it.
pub fn[D : Compare, T : Lattice, R : Semigroup] Batcher::push(
  self : Batcher[D, T, R],
  chunk : Array[(D, T, R)],
) -> Unit {
  guard !self.lower.is_empty() else { abort("batcher is closed") }
  for (_, time, _) in chunk {
    guard self.lower.less_equal(time) else {
      abort("batcher update precedes sealed frontier")
    }
  }
  let before = self.record_count()
  let sorted = consolidate_updates(chunk)
  chunk.clear()
  if !sorted.is_empty() {
    self.chains.push(sorted)
  }
  while self.chains.length() >= 2 {
    let count = self.chains.length()
    if self.chains[count - 1].length() < self.chains[count - 2].length() / 2 {
      break
    }
    let right = self.chains.pop().unwrap()
    let left = self.chains.pop().unwrap()
    let merged = merge_update_chains(left, right)
    if !merged.is_empty() {
      self.chains.push(merged)
    }
  }
  if self.logger is Some(logger) {
    logger.batcher(self.record_count() - before)
  }
}

///|
/// Frontier of records retained by the most recent seal, after consolidation.
/// New pushes do not update this cached frontier, matching upstream Batcher.
pub fn[D, T : Lattice, R] Batcher::frontier(
  self : Batcher[D, T, R],
) -> Antichain[T] {
  Antichain(self.retained_frontier.elements)
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Batcher::seal(
  self : Batcher[D, T, R],
  upper : Antichain[T],
) -> (Array[Array[(D, T, R)]], Description[T]) {
  guard !self.lower.is_empty() && self.lower.precedes(upper) else {
    abort("batcher frontier must advance monotonically")
  }
  let before = self.record_count()
  while self.chains.length() > 1 {
    let right = self.chains.pop().unwrap()
    let left = self.chains.pop().unwrap()
    self.chains.push(merge_update_chains(left, right))
  }
  let combined = self.chains.pop().unwrap_or([])
  let ready = []
  let kept = []
  let frontier = Antichain([])
  for update in combined {
    if upper.less_equal(update.1) {
      kept.push(update)
      let _ = frontier.insert(update.1)
    } else {
      ready.push(update)
    }
  }
  if !kept.is_empty() {
    self.chains.push(kept)
  }
  let description = Description(self.lower, upper, Antichain([self.minimum]))
  self.lower = Antichain(upper.elements)
  self.retained_frontier = frontier
  if self.logger is Some(logger) {
    logger.batcher(self.record_count() - before)
  }
  (if ready.is_empty() { [] } else { [ready] }, description)
}

///|
fn[D : Compare, T : Compare, R : Semigroup] merge_update_chains(
  left : Array[(D, T, R)],
  right : Array[(D, T, R)],
) -> Array[(D, T, R)] {
  let result = Array(capacity=left.length() + right.length())
  let mut a = 0
  let mut b = 0
  while a < left.length() && b < right.length() {
    let x = left[a]
    let y = right[b]
    let order = Compare::compare((x.0, x.1), (y.0, y.1))
    if order < 0 {
      result.push(x)
      a += 1
    } else if order > 0 {
      result.push(y)
      b += 1
    } else {
      let sum = x.2.plus(y.2)
      if !sum.is_zero() {
        result.push((x.0, x.1, sum))
      }
      a += 1
      b += 1
    }
  }
  for i in a..<left.length() {
    result.push(left[i])
  }
  for i in b..<right.length() {
    result.push(right[i])
  }
  result
}

///|
fn[D, T, R] Batcher::record_count(self : Batcher[D, T, R]) -> Int32 {
  self.chains.iter().fold(init=0, fn(sum, chain) { sum + chain.length() })
}

///|
/// Abandon pending records and release storage without sealing an output batch.
pub fn[D, T : Lattice, R] Batcher::dispose(self : Batcher[D, T, R]) -> Unit {
  if self.logger is Some(logger) {
    logger.batcher(-self.record_count())
  }
  self.chains.clear()
  self.lower = Antichain([])
  self.retained_frontier = Antichain([])
}
