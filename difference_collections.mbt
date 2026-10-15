///|
pub impl Semigroup for Unit with fn plus(_, _) {
  ()
}

///|
pub impl Semigroup for Unit with fn is_zero(_) {
  true
}

///|
pub impl Monoid for Unit with fn zero() {
  ()
}

///|
pub impl Abelian for Unit with fn negate(_) {
  ()
}

///|
pub impl[A : Semigroup, B : Semigroup, C : Semigroup] Semigroup for (A, B, C) with fn plus(
  self,
  other,
) {
  (self.0.plus(other.0), self.1.plus(other.1), self.2.plus(other.2))
}

///|
pub impl[A : Semigroup, B : Semigroup, C : Semigroup] Semigroup for (A, B, C) with fn is_zero(
  self,
) {
  self.0.is_zero() && self.1.is_zero() && self.2.is_zero()
}

///|
pub impl[A : Monoid, B : Monoid, C : Monoid] Monoid for (A, B, C) with fn zero() {
  (A::zero(), B::zero(), C::zero())
}

///|
pub impl[A : Abelian, B : Abelian, C : Abelian] Abelian for (A, B, C) with fn negate(
  self,
) {
  (self.0.negate(), self.1.negate(), self.2.negate())
}

///|
pub impl[A : Semigroup, B : Semigroup, C : Semigroup, D : Semigroup] Semigroup for (
  A,
  B,
  C,
  D,
) with fn plus(self, other) {
  (
    self.0.plus(other.0),
    self.1.plus(other.1),
    self.2.plus(other.2),
    self.3.plus(other.3),
  )
}

///|
pub impl[A : Semigroup, B : Semigroup, C : Semigroup, D : Semigroup] Semigroup for (
  A,
  B,
  C,
  D,
) with fn is_zero(self) {
  self.0.is_zero() && self.1.is_zero() && self.2.is_zero() && self.3.is_zero()
}

///|
pub impl[A : Monoid, B : Monoid, C : Monoid, D : Monoid] Monoid for (A, B, C, D) with fn zero() {
  (A::zero(), B::zero(), C::zero(), D::zero())
}

///|
pub impl[A : Abelian, B : Abelian, C : Abelian, D : Abelian] Abelian for (
  A,
  B,
  C,
  D,
) with fn negate(self) {
  (self.0.negate(), self.1.negate(), self.2.negate(), self.3.negate())
}

///|
/// Immutable vector difference. Addition keeps the longer vector, treating missing
/// suffix entries as identities. Trailing zeros need not have a canonical length.
pub struct VectorDiff[R] {
  priv values : Array[R]
} derive(Eq, Compare, Debug)

///|
pub fn[R] VectorDiff::VectorDiff(values : Array[R]) -> VectorDiff[R] {
  { values: values.copy(), }
}

///|
pub fn[R] VectorDiff::to_array(self : VectorDiff[R]) -> Array[R] {
  self.values.copy()
}

///|
pub impl[R : Semigroup] Semigroup for VectorDiff[R] with fn plus(self, other) {
  let length = if self.values.length() > other.values.length() {
    self.values.length()
  } else {
    other.values.length()
  }
  VectorDiff(
    Array::makei(length, fn(index) {
      match (self.values.get(index), other.values.get(index)) {
        (Some(a), Some(b)) => a.plus(b)
        (Some(a), None) => a
        (None, Some(b)) => b
        (None, None) => abort("invalid vector difference index")
      }
    }),
  )
}

///|
pub impl[R : Semigroup] Semigroup for VectorDiff[R] with fn is_zero(self) {
  self.values.iter().all(fn(value) { value.is_zero() })
}

///|
pub impl[R : Monoid] Monoid for VectorDiff[R] with fn zero() {
  VectorDiff([])
}

///|
pub impl[R : Abelian] Abelian for VectorDiff[R] with fn negate(self) {
  VectorDiff(self.values.map(fn(value) { value.negate() }))
}

///|
pub fn[R, S, T] VectorDiff::scale(
  self : VectorDiff[R],
  scalar : S,
  multiply : (R, S) -> T,
) -> VectorDiff[T] {
  VectorDiff(self.values.map(fn(value) { multiply(value, scalar) }))
}

///|
pub extend VectorDiff with Eq::{equal, not_equal}

///|
pub extend VectorDiff with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend VectorDiff with Debug::{to_repr}

///|
pub extend VectorDiff with Semigroup::{plus, is_zero}

///|
pub extend VectorDiff with Monoid::{zero}

///|
pub extend VectorDiff with Abelian::{negate}

///|
pub fn[T] Present::multiply(_self : Present, value : T) -> T {
  value
}
