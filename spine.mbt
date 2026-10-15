///|
/// A fueled spine of immutable batches. Reader cuts remain available until the
/// physical frontier permits merging. In-progress merges retain both sources;
/// a completed merge replaces them atomically, so cursors keep stable storage.
pub struct Spine[D, T, R] {
  priv trace : Trace[D, T, R]
  priv minimum : T
  priv mut merging : (Int32, BatchMerger[D, T, R])?
  priv mut exert_logic : (Array[(Int32, Int32, Int32)]) -> Int32?
}

///|
pub fn[D, T : Lattice, R] Spine::Spine(minimum : T) -> Spine[D, T, R] {
  {
    trace: Trace(minimum),
    minimum,
    merging: None,
    exert_logic: fn(_) { Some(1024) },
  }
}

///|
pub fn[D, T : Lattice, R] Spine::upper(self : Spine[D, T, R]) -> Antichain[T] {
  self.trace.upper()
}

///|
pub fn[D, T : Lattice, R] Spine::logical_compaction(
  self : Spine[D, T, R],
) -> Antichain[T] {
  self.trace.logical_compaction()
}

///|
pub fn[D, T : Lattice, R] Spine::physical_compaction(
  self : Spine[D, T, R],
) -> Antichain[T] {
  self.trace.physical_compaction()
}

///|
pub fn[D, T : Lattice, R] Spine::set_logical_compaction(
  self : Spine[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  guard self.trace.logical.precedes(frontier) else {
    abort("logical compaction cannot move backward")
  }
  self.trace.logical = Antichain(frontier.elements)
}

///|
pub fn[D, T : Lattice, R] Spine::set_physical_compaction(
  self : Spine[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  guard self.trace.physical.precedes(frontier) else {
    abort("physical compaction cannot move backward")
  }
  self.trace.physical = Antichain(frontier.elements)
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Spine::insert(
  self : Spine[D, T, R],
  batch : Batch[D, T, R],
) -> Unit {
  // An exact interval can safely use the global minimum as its since frontier:
  // all queries before lower see no records. This also adapts Batch's explicit
  // lower-bound constructor to upstream builders' Timestamp::minimum metadata.
  let batch = if batch.description.since.precedes(batch.description.lower) {
    {
      updates: batch.updates,
      description: Description(
        batch.description.lower,
        batch.description.upper,
        Antichain([self.minimum]),
      ),
    }
  } else {
    guard batch.description.since.precedes(self.trace.logical) else {
      abort("inserted batch was compacted beyond the spine reader")
    }
    batch
  }
  self.trace.insert(batch)
  let size = batch.length()
  let fuel = if size > 0x1fff_ffff { 0x7fff_ffff } else { size * 4 + 4 }
  let _ = self.work(fuel, false)
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Spine::close(
  self : Spine[D, T, R],
) -> Unit {
  if !self.upper().is_empty() {
    self.insert(Batch::empty(lower=self.upper(), upper=Antichain([])))
  }
}

///|
/// Exertion receives occupied levels, largest first, as (level, batch count,
/// update count). Returning None or nonpositive fuel declines background work.
pub fn[D, T, R] Spine::set_exert_logic(
  self : Spine[D, T, R],
  logic : (Array[(Int32, Int32, Int32)]) -> Int32?,
) -> Unit {
  self.exert_logic = logic
}

///|
pub fn[D, T, R] Spine::levels(
  self : Spine[D, T, R],
) -> Array[(Int32, Int32, Int32)] {
  let levels : Map[Int32, (Int32, Int32)] = Map([])
  for batch in self.trace.batches {
    let mut level = 0
    let mut weight = if batch.length() == 0 { 0 } else { batch.length() - 1 }
    while weight > 0 {
      weight = weight >> 1
      level += 1
    }
    let previous = levels.get(level).unwrap_or((0, 0))
    levels[level] = (previous.0 + 1, previous.1 + batch.length())
  }
  let result = levels
    .to_array()
    .map(fn(entry) { (entry.0, entry.1.0, entry.1.1) })
  result.sort_by(fn(a, b) { Compare::compare(b.0, a.0) })
  result
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Spine::exert(
  self : Spine[D, T, R],
) -> Unit {
  if (self.exert_logic)(self.levels()) is Some(fuel) && fuel > 0 {
    let _ = self.work(fuel, true)
  }
}

///|
/// Perform bounded merge work, returning remaining fuel. As for BatchMerger,
/// one data group may overshoot the budget. Input batches remain queryable.
pub fn[D : Compare, T : Lattice, R : Semigroup] Spine::exert_with_fuel(
  self : Spine[D, T, R],
  fuel : Int32,
) -> Int32 {
  self.work(fuel, true)
}

///|
fn[D : Compare, T : Lattice, R : Semigroup] Spine::work(
  self : Spine[D, T, R],
  fuel : Int32,
  force : Bool,
) -> Int32 {
  let mut remaining = fuel
  if self.trace.logical.is_empty() && self.trace.physical.is_empty() {
    self.merging = None
    self.trace.batches.clear()
    return remaining
  }
  while remaining > 0 {
    if self.merging is None {
      let mut choice : Int32? = None
      let mut smallest = 0L
      for index in 0..<(self.trace.batches.length() - 1) {
        let left = self.trace.batches[index]
        let right = self.trace.batches[index + 1]
        let a = Int32::max(1, left.length()).to_int64()
        let b = Int32::max(1, right.length()).to_int64()
        if right.description.upper.precedes(self.trace.physical) &&
          (force || a <= b * 2) &&
          (choice is None || a + b < smallest) {
          choice = Some(index)
          smallest = a + b
        }
      }
      guard choice is Some(index) else { break }
      self.merging = Some(
        (
          index,
          self.trace.batches[index].begin_merge(
            self.trace.batches[index + 1],
            self.trace.logical,
          ),
        ),
      )
    }
    let (index, merger) = self.merging.unwrap()
    remaining = merger.work(remaining)
    if merger.is_complete() {
      let merged = merger.done()
      let batches = []
      for position, batch in self.trace.batches {
        if position == index {
          batches.push(merged)
        } else if position != index + 1 {
          batches.push(batch)
        }
      }
      self.trace.batches = batches
      self.merging = None
    }
  }
  remaining
}

///|
pub fn[D, T : Lattice, R] Spine::batches_through(
  self : Spine[D, T, R],
  upper : Antichain[T],
) -> Array[Batch[D, T, R]]? {
  if upper.less_equal(self.minimum) {
    return Some([])
  }
  guard self.trace.physical.precedes(upper) else { return None }
  self.trace.batches_through(upper)
}

///|
pub fn[D, T, R] Spine::map_batches(
  self : Spine[D, T, R],
  visit : (Batch[D, T, R]) -> Unit,
) -> Unit {
  self.trace.map_batches(visit)
}

///|
pub fn[D, T : Lattice, R] Spine::advance_upper(
  self : Spine[D, T, R],
  upper : Antichain[T],
) -> Antichain[T] {
  self.trace.advance_upper(upper)
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Spine::snapshot(
  self : Spine[D, T, R],
  time : T,
) -> Array[(D, R)] {
  self.trace.snapshot(time)
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] Spine::cursor_through(
  self : Spine[(K, V), T, R],
  upper : Antichain[T],
) -> Cursor[K, V, T, R]? {
  self
  .batches_through(upper)
  .map(fn(batches) { Cursor(batches.map(fn(batch) { batch.view() })) })
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] Spine::cursor(
  self : Spine[(K, V), T, R],
) -> Cursor[K, V, T, R] {
  self.cursor_through(Antichain([])).unwrap()
}
