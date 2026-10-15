///|
/// Signed 8-bit integer. Construction and difference arithmetic wrap modulo 256;
/// timestamp advancement uses checked addition instead.
pub struct Int8 {
  priv value : Int32
} derive(Eq, Compare, Debug, Hash)

///|
pub fn Int8::Int8(value : Int32) -> Int8 {
  { value: ((value & 255) ^ 128) - 128, }
}

///|
pub fn Int8::to_int(self : Int8) -> Int32 {
  self.value
}

///|
pub fn Int8::checked_add(self : Int8, other : Int8) -> Int8? {
  let sum = self.value + other.value
  if sum < -128 || sum > 127 {
    None
  } else {
    Some(Int8(sum))
  }
}

///|
pub fn Int8::multiply(self : Int8, other : Int8) -> Int8 {
  Int8(self.value * other.value)
}

///|
pub impl Lattice for Int8 with fn less_equal(self, other) {
  self.value <= other.value
}

///|
pub impl Lattice for Int8 with fn join(self, other) {
  if self.value >= other.value {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Int8 with fn meet(self, other) {
  if self.value <= other.value {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for Int8

///|
pub impl Semigroup for Int8 with fn plus(self, other) {
  Int8(self.value + other.value)
}

///|
pub impl Semigroup for Int8 with fn is_zero(self) {
  self.value == 0
}

///|
pub impl Monoid for Int8 with fn zero() {
  Int8(0)
}

///|
pub impl Abelian for Int8 with fn negate(self) {
  Int8(-self.value)
}

///|
pub fn SummaryDomain::int8() -> SummaryDomain[Int8, Int8] {
  SummaryDomain(
    Int8(0),
    apply=fn(a, b) { a.checked_add(b) },
    compose=fn(a, b) { a.checked_add(b) },
    less_equal=fn(a, b) { a.value <= b.value },
  )
}

///|
pub extend Int8 with Eq::{equal, not_equal}

///|
pub extend Int8 with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend Int8 with Debug::{to_repr}

///|
pub extend Int8 with Hash::{hash, hash_combine}

///|
pub extend Int8 with Lattice::{less_equal, join, meet}

///|
pub extend Int8 with Semigroup::{plus, is_zero}

///|
pub extend Int8 with Monoid::{zero}

///|
pub extend Int8 with Abelian::{negate}
