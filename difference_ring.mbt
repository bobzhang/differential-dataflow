///|
/// An Abelian difference with a multiplicative identity and closed multiplication.
/// This packages upstream's Abelian + Multiply<Self> + From<i8> requirements for
/// generic graph algorithms. Arithmetic must obey the ring laws.
pub(open) trait Ring: Abelian {
  fn one() -> Self
  fn multiply(Self, Self) -> Self
}

///|
pub impl Ring for Int8 with fn one() {
  Int8(1)
}

///|
pub impl Ring for Int8 with fn multiply(self, other) {
  Int8::multiply(self, other)
}

///|
pub impl Ring for Int16 with fn one() {
  1
}

///|
pub impl Ring for Int16 with fn multiply(self, other) {
  self * other
}

///|
pub impl Ring for Int32 with fn one() {
  1
}

///|
pub impl Ring for Int32 with fn multiply(self, other) {
  self * other
}

///|
pub impl Ring for Int64 with fn one() {
  1L
}

///|
pub impl Ring for Int64 with fn multiply(self, other) {
  self * other
}

///|
pub impl Ring for Int128 with fn one() {
  Int128(1)
}

///|
pub impl Ring for Int128 with fn multiply(self, other) {
  Int128::multiply(self, other)
}

///|
/// Explicit wrapping signed difference adapter. MoonBit integer difference
/// arithmetic already wraps on every backend; this preserves that behavior while
/// giving translated Rust Wrapping<T> programs a distinct public type.
pub struct Wrapping[R] {
  priv inner : R
} derive(Eq, Compare, Debug, Hash)

///|
pub fn[R] Wrapping::Wrapping(value : R) -> Wrapping[R] {
  { inner: value, }
}

///|
pub fn[R] Wrapping::value(self : Wrapping[R]) -> R {
  self.inner
}

///|
pub impl[R : Semigroup] Semigroup for Wrapping[R] with fn plus(self, other) {
  Wrapping(self.inner.plus(other.inner))
}

///|
pub impl[R : Semigroup] Semigroup for Wrapping[R] with fn is_zero(self) {
  self.inner.is_zero()
}

///|
pub impl[R : Monoid] Monoid for Wrapping[R] with fn zero() {
  Wrapping(R::zero())
}

///|
pub impl[R : Abelian] Abelian for Wrapping[R] with fn negate(self) {
  Wrapping(self.inner.negate())
}

///|
pub impl[R : Ring] Ring for Wrapping[R] with fn one() {
  Wrapping(R::one())
}

///|
pub impl[R : Ring] Ring for Wrapping[R] with fn multiply(self, other) {
  Wrapping(self.inner.multiply(other.inner))
}

///|
pub extend Wrapping with Eq::{equal, not_equal}

///|
pub extend Wrapping with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend Wrapping with Debug::{to_repr}

///|
pub extend Wrapping with Hash::{hash, hash_combine}

///|
pub extend Wrapping with Semigroup::{plus, is_zero}

///|
pub extend Wrapping with Monoid::{zero}

///|
pub extend Wrapping with Abelian::{negate}

///|
pub extend Wrapping with Ring::{one, multiply}

///|
pub extend Int8 with Ring::{one}

///|
pub extend Int128 with Ring::{one}
