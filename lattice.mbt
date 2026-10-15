///|
/// A partial order with least upper bounds and greatest lower bounds.
/// Compare is a consistent total extension used only for storage order.
pub(open) trait Lattice: Compare {
  fn less_equal(Self, Self) -> Bool
  fn join(Self, Self) -> Self
  fn meet(Self, Self) -> Self
}

///|
pub impl Lattice for Int64 with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for Int64 with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Int64 with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
/// Product partial order; its Compare implementation is lexicographic.
pub(all) struct Product[A, B] {
  outer : A
  inner : B
} derive(Eq, Compare, Debug)

///|
pub fn[A, B] Product::Product(outer : A, inner : B) -> Product[A, B] {
  { outer, inner, }
}

///|
pub impl[A : Lattice, B : Lattice] Lattice for Product[A, B] with fn less_equal(
  self,
  other,
) {
  self.outer.less_equal(other.outer) && self.inner.less_equal(other.inner)
}

///|
pub impl[A : Lattice, B : Lattice] Lattice for Product[A, B] with fn join(
  self,
  other,
) {
  Product(self.outer.join(other.outer), self.inner.join(other.inner))
}

///|
pub impl[A : Lattice, B : Lattice] Lattice for Product[A, B] with fn meet(
  self,
  other,
) {
  Product(self.outer.meet(other.outer), self.inner.meet(other.inner))
}

///|
/// Minimal incomparable timestamps; empty means no future times remain.
pub struct Antichain[T] {
  priv elements : Array[T]
}

///|
pub fn[T : Lattice] Antichain::Antichain(elements : Array[T]) -> Antichain[T] {
  let result = { elements: [], }
  for time in elements {
    let _ = result.insert(time)
  }
  result
}

///|
pub fn[T : Lattice] Antichain::insert(self : Antichain[T], time : T) -> Bool {
  if self.less_equal(time) {
    return false
  }
  let retained = self.elements.filter(fn(old) { !time.less_equal(old) })
  self.elements.clear()
  for old in retained {
    self.elements.push(old)
  }
  self.elements.push(time)
  self.elements.sort()
  true
}

///|
pub fn[T] Antichain::to_array(self : Antichain[T]) -> Array[T] {
  self.elements.copy()
}

///|
pub fn[T : Lattice] Antichain::less_equal(
  self : Antichain[T],
  time : T,
) -> Bool {
  self.elements.iter().any(fn(t) { t.less_equal(time) })
}

///|
/// True if this frontier is no later than the other frontier.
pub fn[T : Lattice] Antichain::precedes(
  self : Antichain[T],
  other : Antichain[T],
) -> Bool {
  other.elements.iter().all(fn(t) { self.less_equal(t) })
}

///|
/// Upstream lattice compaction: meet of joins with frontier elements.
pub fn[T : Lattice] advance_by(time : T, frontier : Antichain[T]) -> T {
  guard frontier.elements.get(0) is Some(first) else { return time }
  let mut result = time.join(first)
  for f in frontier.elements {
    result = result.meet(time.join(f))
  }
  result
}

///|
pub extend Product with Eq::{equal, not_equal}

///|
pub extend Product with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend Product with Debug::{to_repr}

///|
pub extend Product with Lattice::{less_equal, join, meet}
