///|
/// Immutable sorted updates with a sealed timestamp interval.
pub struct Batch[D, T, R] {
  priv updates : UpdateStorage[D, T, R]
  priv description : Description[T]
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Batch::Batch(
  updates : Array[(D, T, R)],
  lower~ : Antichain[T],
  upper~ : Antichain[T],
) -> Batch[D, T, R] {
  let description = Description(lower, upper, lower)
  for (_, time, _) in updates {
    guard lower.less_equal(time) && !upper.less_equal(time) else {
      abort("update is outside batch interval")
    }
  }
  { updates: Rows(consolidate_updates(updates)), description, }
}

///|
pub fn[D, T, R] Batch::to_array(self : Batch[D, T, R]) -> Array[(D, T, R)] {
  self.updates.copy()
}

///|
pub fn[D, T, R] Batch::description(self : Batch[D, T, R]) -> Description[T] {
  self.description
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Batch::compact(
  self : Batch[D, T, R],
  since : Antichain[T],
) -> Batch[D, T, R] {
  guard self.description.since.precedes(since) else {
    abort("logical compaction cannot move backward")
  }
  {
    updates: self.updates.packer()(
      consolidate_updates(
        self.updates
        .iter()
        .map(fn(u) { (u.0, advance_by(u.1, since), u.2) })
        .to_array(),
      ),
    ),
    description: Description(
      self.description.lower,
      self.description.upper,
      since,
    ),
  }
}

///|
pub fn[D, T : Lattice, R] Batch::empty(
  lower~ : Antichain[T],
  upper~ : Antichain[T],
) -> Batch[D, T, R] {
  { updates: Rows([]), description: Description(lower, upper, lower), }
}

///|
pub fn[D, T, R] Batch::length(self : Batch[D, T, R]) -> Int32 {
  self.updates.length()
}

///|
pub fn[D, T, R] Batch::is_empty(self : Batch[D, T, R]) -> Bool {
  self.updates.is_empty()
}
