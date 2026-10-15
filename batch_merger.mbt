///|
/// Incrementally merge consecutive immutable batches. One work unit consumes an
/// input update; a call may exceed its fuel to complete one data record's group.
/// This accounting is conservative compared with upstream's output-based fuel.
pub struct BatchMerger[D, T, R] {
  priv mut left : Batch[D, T, R]?
  priv mut right : Batch[D, T, R]?
  priv mut a : Int32
  priv mut b : Int32
  priv mut output : Array[(D, T, R)]
  priv pack : (Array[(D, T, R)]) -> UpdateStorage[D, T, R]
  priv description : Description[T]
  priv mut complete : Bool
  priv mut finished : Bool
}

///|
pub fn[D, T : Lattice, R] BatchMerger::BatchMerger(
  left : Batch[D, T, R],
  right : Batch[D, T, R],
  since : Antichain[T],
) -> BatchMerger[D, T, R] {
  guard left.description.upper.elements == right.description.lower.elements else {
    abort("merged batches must be consecutive")
  }
  let since = left.description.since.join(right.description.since).join(since)
  {
    left: Some(left),
    right: Some(right),
    pack: left.updates.merge_packer(right.updates),
    a: 0,
    b: 0,
    output: [],
    description: Description(
      left.description.lower,
      right.description.upper,
      since,
    ),
    complete: left.is_empty() && right.is_empty(),
    finished: false,
  }
}

///|
pub fn[D, T, R] BatchMerger::is_complete(self : BatchMerger[D, T, R]) -> Bool {
  self.complete
}

///|
/// Return unspent fuel. A positive remainder guarantees completion. A zero or
/// negative remainder may also be complete; is_complete disambiguates this case.
pub fn[D : Compare, T : Lattice, R : Semigroup] BatchMerger::work(
  self : BatchMerger[D, T, R],
  fuel : Int32,
) -> Int32 {
  guard !self.finished else { abort("batch merger was consumed") }
  let left = self.left.unwrap().updates.reader()
  let right = self.right.unwrap().updates.reader()
  let mut remaining = fuel
  while remaining > 0 && !self.complete {
    let data = if self.a == left.length() {
      right[self.b].0
    } else if self.b == right.length() {
      left[self.a].0
    } else if left[self.a].0 <= right[self.b].0 {
      left[self.a].0
    } else {
      right[self.b].0
    }
    let group = []
    while self.a < left.length() && left[self.a].0 == data {
      let update = left[self.a]
      group.push((data, advance_by(update.1, self.description.since), update.2))
      self.a += 1
      remaining -= 1
    }
    while self.b < right.length() && right[self.b].0 == data {
      let update = right[self.b]
      group.push((data, advance_by(update.1, self.description.since), update.2))
      self.b += 1
      remaining -= 1
    }
    for update in consolidate_updates(group) {
      self.output.push(update)
    }
    self.complete = self.a == left.length() && self.b == right.length()
  }
  remaining
}

///|
pub fn[D, T, R] BatchMerger::done(
  self : BatchMerger[D, T, R],
) -> Batch[D, T, R] {
  guard self.complete && !self.finished else {
    abort("batch merge is unfinished or consumed")
  }
  self.finished = true
  self.left = None
  self.right = None
  let updates = self.output
  self.output = []
  { updates: (self.pack)(updates), description: self.description, }
}

///|
pub fn[D, T : Lattice, R] Batch::begin_merge(
  self : Batch[D, T, R],
  other : Batch[D, T, R],
  since : Antichain[T],
) -> BatchMerger[D, T, R] {
  BatchMerger(self, other, since)
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Batch::merge(
  self : Batch[D, T, R],
  other : Batch[D, T, R],
  since : Antichain[T],
) -> Batch[D, T, R] {
  let merger = self.begin_merge(other, since)
  while !merger.is_complete() {
    let _ = merger.work(4096)
  }
  merger.done()
}
