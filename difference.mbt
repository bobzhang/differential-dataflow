///|
/// Associative, commutative accumulation and an additive-identity test.
pub(open) trait Semigroup {
  fn plus(Self, Self) -> Self
  fn is_zero(Self) -> Bool
}

///|
pub(open) trait Monoid: Semigroup {
  fn zero() -> Self
}

///|
pub(open) trait Abelian: Monoid {
  fn negate(Self) -> Self
}

///|
pub impl Semigroup for Int64 with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for Int64 with fn is_zero(self) {
  self == 0
}

///|
pub impl Monoid for Int64 with fn zero() {
  0
}

///|
pub impl Abelian for Int64 with fn negate(self) {
  -self
}

///|
pub impl Semigroup for Int32 with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for Int32 with fn is_zero(self) {
  self == 0
}

///|
pub impl Monoid for Int32 with fn zero() {
  0
}

///|
pub impl Abelian for Int32 with fn negate(self) {
  -self
}

///|
/// Presence-only semigroup: there is no zero or retraction.
pub(all) enum Present {
  Present
} derive(Eq, Debug)

///|
pub impl Semigroup for Present with fn plus(self, _other) {
  self
}

///|
pub impl Semigroup for Present with fn is_zero(_self) {
  false
}

///|
pub extend Present with Eq::{equal, not_equal}

///|
pub extend Present with Debug::{to_repr}

///|
pub extend Present with Semigroup::{plus, is_zero}

///|
pub impl[A : Semigroup, B : Semigroup] Semigroup for (A, B) with fn plus(
  self,
  other,
) {
  (self.0.plus(other.0), self.1.plus(other.1))
}

///|
pub impl[A : Semigroup, B : Semigroup] Semigroup for (A, B) with fn is_zero(
  self,
) {
  self.0.is_zero() && self.1.is_zero()
}

///|
pub impl[A : Monoid, B : Monoid] Monoid for (A, B) with fn zero() {
  (A::zero(), B::zero())
}

///|
pub impl[A : Abelian, B : Abelian] Abelian for (A, B) with fn negate(self) {
  (self.0.negate(), self.1.negate())
}
