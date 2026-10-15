///|
pub fn[T] Antichain::is_empty(self : Antichain[T]) -> Bool {
  self.elements.is_empty()
}

///|
pub fn[T] Antichain::clear(self : Antichain[T]) -> Unit {
  self.elements.clear()
}

///|
pub fn[T : Lattice] Antichain::less_than(self : Antichain[T], time : T) -> Bool {
  self.elements.iter().any(fn(t) { t != time && t.less_equal(time) })
}

///|
/// Reference counts of outstanding timestamps and their minimal positive frontier.
pub struct MutableAntichain[T] {
  priv counts : ChangeBatch[T]
  priv mut frontier : Antichain[T]
}

///|
pub fn[T : Lattice] MutableAntichain::MutableAntichain() -> MutableAntichain[T] {
  { counts: ChangeBatch(), frontier: Antichain([]), }
}

///|
/// Apply a batch atomically and return only changes to frontier membership.
pub fn[T : Lattice] MutableAntichain::update_all(
  self : MutableAntichain[T],
  changes : Array[(T, Int64)],
) -> Array[(T, Int64)] {
  let delta = ChangeBatch()
  for time in self.frontier.elements {
    delta.update(time, -1)
  }
  self.counts.update_all(changes)
  let next = []
  for (time, count) in self.counts.to_array() {
    if count > 0 {
      next.push(time)
    }
  }
  self.frontier = Antichain(next)
  for time in self.frontier.elements {
    delta.update(time, 1)
  }
  delta.drain()
}

///|
pub fn[T : Lattice] MutableAntichain::frontier(
  self : MutableAntichain[T],
) -> Antichain[T] {
  Antichain(self.frontier.elements)
}

///|
pub fn[T : Lattice] MutableAntichain::count_for(
  self : MutableAntichain[T],
  time : T,
) -> Int64 {
  for (key, count) in self.counts.to_array() {
    if key == time {
      return count
    }
  }
  0
}

///|
pub fn[T : Lattice] MutableAntichain::updates(
  self : MutableAntichain[T],
) -> Array[(T, Int64)] {
  self.counts.to_array()
}

///|
pub fn[T] MutableAntichain::clear(self : MutableAntichain[T]) -> Unit {
  self.counts.clear()
  self.frontier.clear()
}
