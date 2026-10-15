///|
let wide_modulus : @bigint.BigInt = @bigint.BigInt::from_int(1) << 128

///|
let wide_sign : @bigint.BigInt = @bigint.BigInt::from_int(1) << 127

///|
let wide_mask : @bigint.BigInt = wide_modulus - @bigint.BigInt::from_int(1)

///|
let word_mask : @bigint.BigInt = (@bigint.BigInt::from_int(1) << 64) -
  @bigint.BigInt::from_int(1)

///|
/// Fixed-width signed 128-bit integer. Difference arithmetic wraps modulo
/// 2^128; timestamp summary arithmetic detects overflow. Storage uses core BigInt.
pub struct Int128 {
  priv value : @bigint.BigInt
} derive(Eq, Compare, Debug, Hash)

///|
pub fn Int128::Int128(value : Int64) -> Int128 {
  { value: @bigint.BigInt::from_int64(value), }
}

///|
pub fn Int128::from_words(high : Int64, low : UInt64) -> Int128 {
  {
    value: (@bigint.BigInt::from_int64(high) << 64) +
    @bigint.BigInt::from_uint64(low),
  }
}

///|
pub fn Int128::to_words(self : Int128) -> (Int64, UInt64) {
  ((self.value >> 64).to_int64(), (self.value & word_mask).to_uint64())
}

///|
pub fn Int128::to_string(self : Int128) -> String {
  self.value.to_string()
}

///|
pub fn Int128::try_from_bigint(value : @bigint.BigInt) -> Int128? {
  if value >= -wide_sign && value < wide_sign {
    Some({ value, })
  } else {
    None
  }
}

///|
fn Int128::wrapping(value : @bigint.BigInt) -> Int128 {
  { value: ((value + wide_sign) & wide_mask) - wide_sign, }
}

///|
pub fn Int128::checked_add(self : Int128, other : Int128) -> Int128? {
  Int128::try_from_bigint(self.value + other.value)
}

///|
pub fn Int128::multiply(self : Int128, other : Int128) -> Int128 {
  Int128::wrapping(self.value * other.value)
}

///|
pub impl Lattice for Int128 with fn less_equal(self, other) {
  self.value <= other.value
}

///|
pub impl Lattice for Int128 with fn join(self, other) {
  if self.value > other.value {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Int128 with fn meet(self, other) {
  if self.value < other.value {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for Int128

///|
pub impl Semigroup for Int128 with fn plus(self, other) {
  Int128::wrapping(self.value + other.value)
}

///|
pub impl Semigroup for Int128 with fn is_zero(self) {
  self.value.is_zero()
}

///|
pub impl Monoid for Int128 with fn zero() {
  Int128(0)
}

///|
pub impl Abelian for Int128 with fn negate(self) {
  Int128::wrapping(-self.value)
}

///|
pub extend Int128 with Eq::{equal, not_equal}

///|
pub extend Int128 with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend Int128 with Debug::{to_repr}

///|
pub extend Int128 with Hash::{hash, hash_combine}

///|
pub extend Int128 with Lattice::{less_equal, join, meet}

///|
pub extend Int128 with Semigroup::{plus, is_zero}

///|
pub extend Int128 with Monoid::{zero}

///|
pub extend Int128 with Abelian::{negate}

///|
pub fn SummaryDomain::int128() -> SummaryDomain[Int128, Int128] {
  SummaryDomain(
    Int128(0),
    apply=fn(a, b) { a.checked_add(b) },
    compose=fn(a, b) { a.checked_add(b) },
    less_equal=fn(a, b) { a.less_equal(b) },
  )
}

///|
/// Fixed-width unsigned 128-bit integer. Difference arithmetic wraps modulo
/// 2^128; timestamp summary arithmetic detects overflow. Storage uses core BigInt.
pub struct UInt128 {
  priv value : @bigint.BigInt
} derive(Eq, Compare, Debug, Hash)

///|
pub fn UInt128::UInt128(value : UInt64) -> UInt128 {
  { value: @bigint.BigInt::from_uint64(value), }
}

///|
pub fn UInt128::from_words(high : UInt64, low : UInt64) -> UInt128 {
  {
    value: (@bigint.BigInt::from_uint64(high) << 64) +
    @bigint.BigInt::from_uint64(low),
  }
}

///|
pub fn UInt128::to_words(self : UInt128) -> (UInt64, UInt64) {
  ((self.value >> 64).to_uint64(), (self.value & word_mask).to_uint64())
}

///|
pub fn UInt128::to_string(self : UInt128) -> String {
  self.value.to_string()
}

///|
pub fn UInt128::try_from_bigint(value : @bigint.BigInt) -> UInt128? {
  if value >= @bigint.BigInt::from_int(0) && value < wide_modulus {
    Some({ value, })
  } else {
    None
  }
}

///|
fn UInt128::wrapping(value : @bigint.BigInt) -> UInt128 {
  { value: value & wide_mask, }
}

///|
pub fn UInt128::checked_add(self : UInt128, other : UInt128) -> UInt128? {
  UInt128::try_from_bigint(self.value + other.value)
}

///|
pub fn UInt128::multiply(self : UInt128, other : UInt128) -> UInt128 {
  UInt128::wrapping(self.value * other.value)
}

///|
pub impl Lattice for UInt128 with fn less_equal(self, other) {
  self.value <= other.value
}

///|
pub impl Lattice for UInt128 with fn join(self, other) {
  if self.value > other.value {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for UInt128 with fn meet(self, other) {
  if self.value < other.value {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for UInt128

///|
pub impl Semigroup for UInt128 with fn plus(self, other) {
  UInt128::wrapping(self.value + other.value)
}

///|
pub impl Semigroup for UInt128 with fn is_zero(self) {
  self.value.is_zero()
}

///|
pub impl Monoid for UInt128 with fn zero() {
  UInt128(0)
}

///|
pub extend UInt128 with Eq::{equal, not_equal}

///|
pub extend UInt128 with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend UInt128 with Debug::{to_repr}

///|
pub extend UInt128 with Hash::{hash, hash_combine}

///|
pub extend UInt128 with Lattice::{less_equal, join, meet}

///|
pub extend UInt128 with Semigroup::{plus, is_zero}

///|
pub extend UInt128 with Monoid::{zero}

///|
pub fn SummaryDomain::uint128() -> SummaryDomain[UInt128, UInt128] {
  SummaryDomain(
    UInt128(0),
    apply=fn(a, b) { a.checked_add(b) },
    compose=fn(a, b) { a.checked_add(b) },
    less_equal=fn(a, b) { a.less_equal(b) },
  )
}
