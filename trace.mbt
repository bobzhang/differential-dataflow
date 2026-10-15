///|
/// Ordered batches with independent logical and physical compaction frontiers.
pub struct Trace[D, T, R] {
  priv mut batches : Array[Batch[D, T, R]]
  priv mut upper : Antichain[T]
  priv mut logical : Antichain[T]
  priv mut physical : Antichain[T]
}

///|
pub fn[D, T : Lattice, R] Trace::Trace(minimum : T) -> Trace[D, T, R] {
  {
    batches: [],
    upper: Antichain([minimum]),
    logical: Antichain([minimum]),
    physical: Antichain([minimum]),
  }
}

///|
pub fn[D, T : Lattice, R] Trace::insert(
  self : Trace[D, T, R],
  batch : Batch[D, T, R],
) -> Unit {
  guard self.upper.elements == batch.description.lower.elements else {
    abort("trace batches must be contiguous")
  }
  guard !self.upper.is_empty() else { abort("trace is closed") }
  guard batch.description.lower.elements != batch.description.upper.elements else {
    abort("trace batch must advance the frontier")
  }
  self.batches.push(batch)
  self.upper = batch.description.upper()
}

///|
pub fn[D, T : Lattice, R] Trace::upper(self : Trace[D, T, R]) -> Antichain[T] {
  Antichain(self.upper.elements)
}

///|
pub fn[D, T : Lattice, R] Trace::logical_compaction(
  self : Trace[D, T, R],
) -> Antichain[T] {
  Antichain(self.logical.elements)
}

///|
pub fn[D, T : Lattice, R] Trace::physical_compaction(
  self : Trace[D, T, R],
) -> Antichain[T] {
  Antichain(self.physical.elements)
}

///|
/// Permit changing update times while preserving all queries beyond this frontier.
pub fn[D : Compare, T : Lattice, R : Semigroup] Trace::set_logical_compaction(
  self : Trace[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  guard self.logical.precedes(frontier) else {
    abort("logical compaction cannot move backward")
  }
  self.logical = Antichain(frontier.elements)
  for index, batch in self.batches {
    // A newly sealed batch can begin later than the requested frontier.
    let since = batch.description.since.join(frontier)
    self.batches[index] = batch.compact(since)
  }
}

///|
/// Permit merging batch boundaries no longer needed by readers.
pub fn[D : Compare, T : Lattice, R : Semigroup] Trace::set_physical_compaction(
  self : Trace[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  guard self.physical.precedes(frontier) else {
    abort("physical compaction cannot move backward")
  }
  self.physical = Antichain(frontier.elements)
  let retained = []
  let mut pending : Batch[D, T, R]? = None
  for batch in self.batches {
    if batch.description.upper.precedes(frontier) {
      match pending {
        None => pending = Some(batch)
        Some(previous) => {
          let combined = previous.updates.copy()
          for update in batch.updates.iter() {
            combined.push(update)
          }
          let since = Antichain(
            previous.description.since.elements +
            batch.description.since.elements,
          )
          pending = Some({
            updates: previous.updates.merge_packer(batch.updates)(
              consolidate_updates(combined),
            ),
            description: Description(
              previous.description.lower,
              batch.description.upper,
              since,
            ),
          })
        }
      }
    } else {
      retained.push(batch)
    }
  }
  self.batches = match pending {
    None => retained
    Some(batch) => [batch] + retained
  }
}

///|
/// Return an exact batch cut, or None when physical compaction removed it.
pub fn[D, T : Lattice, R] Trace::batches_through(
  self : Trace[D, T, R],
  upper : Antichain[T],
) -> Array[Batch[D, T, R]]? {
  if upper.is_empty() {
    return Some(self.batches.copy())
  }
  let result = []
  for batch in self.batches {
    if batch.description.lower.elements == upper.elements {
      return Some(result)
    }
    if !batch.description.upper.precedes(upper) {
      return None
    }
    result.push(batch)
    if batch.description.upper.elements == upper.elements {
      return Some(result)
    }
  }
  if self.upper.elements == upper.elements {
    Some(result)
  } else {
    None
  }
}

///|
/// Consolidated snapshot at a completed timestamp, subject to the logical frontier.
pub fn[D : Compare, T : Lattice, R : Semigroup] Trace::snapshot(
  self : Trace[D, T, R],
  time : T,
) -> Array[(D, R)] {
  guard self.logical.less_equal(time) else {
    abort("query precedes logical compaction")
  }
  guard !self.upper.less_equal(time) else {
    abort("query timestamp is not complete")
  }
  let values = []
  for batch in self.batches {
    for (data, at, diff) in batch.updates.iter() {
      if at.less_equal(time) {
        values.push((data, diff))
      }
    }
  }
  consolidate(values)
}

///|
/// Seal the remaining interval with an empty batch. Repeated close is harmless.
pub fn[D, T : Lattice, R] Trace::close(self : Trace[D, T, R]) -> Unit {
  if !self.upper.is_empty() {
    self.insert(Batch::empty(lower=self.upper, upper=Antichain([])))
  }
}

///|
/// Visit retained batches in interval order, including empty progress batches.
pub fn[D, T, R] Trace::map_batches(
  self : Trace[D, T, R],
  visit : (Batch[D, T, R]) -> Unit,
) -> Unit {
  for batch in self.batches {
    visit(batch)
  }
}

///|
/// Advance a supplied bound across consecutive empty intervals without mutating it.
pub fn[D, T : Lattice, R] Trace::advance_upper(
  self : Trace[D, T, R],
  upper : Antichain[T],
) -> Antichain[T] {
  let mut result = Antichain(upper.elements)
  self.map_batches(fn(batch) {
    if batch.is_empty() && batch.description.lower.elements == result.elements {
      result = batch.description.upper()
    }
  })
  result
}
