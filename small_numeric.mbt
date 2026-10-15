///|
pub impl Lattice for Int16 with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for Int16 with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Int16 with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for Int16

///|
pub impl Semigroup for Int16 with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for Int16 with fn is_zero(self) {
  self.to_int() == 0
}

///|
pub impl Monoid for Int16 with fn zero() {
  0
}

///|
pub impl Abelian for Int16 with fn negate(self) {
  -self
}

///|
fn checked_add_int16(a : Int16, b : Int16) -> Int16? {
  let sum = a.to_int() + b.to_int()
  if sum < -32768 || sum > 32767 {
    None
  } else {
    Some(Int16::from_int(sum))
  }
}

///|
pub fn SummaryDomain::int16() -> SummaryDomain[Int16, Int16] {
  SummaryDomain(0, apply=checked_add_int16, compose=checked_add_int16, less_equal=fn(
    a,
    b,
  ) {
    a <= b
  })
}

///|
pub impl Lattice for UInt16 with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for UInt16 with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for UInt16 with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for UInt16

///|
pub impl Semigroup for UInt16 with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for UInt16 with fn is_zero(self) {
  self.to_int() == 0
}

///|
pub impl Monoid for UInt16 with fn zero() {
  0
}

///|
fn checked_add_uint16(a : UInt16, b : UInt16) -> UInt16? {
  let sum = a.to_int() + b.to_int()
  if sum < 0 || sum > 65535 {
    None
  } else {
    Some(sum.to_uint16())
  }
}

///|
pub fn SummaryDomain::uint16() -> SummaryDomain[UInt16, UInt16] {
  SummaryDomain(0, apply=checked_add_uint16, compose=checked_add_uint16, less_equal=fn(
    a,
    b,
  ) {
    a <= b
  })
}

///|
pub impl Lattice for Byte with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for Byte with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Byte with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for Byte

///|
pub impl Semigroup for Byte with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for Byte with fn is_zero(self) {
  self.to_int() == 0
}

///|
pub impl Monoid for Byte with fn zero() {
  0
}

///|
fn checked_add_byte(a : Byte, b : Byte) -> Byte? {
  let sum = a.to_int() + b.to_int()
  if sum < 0 || sum > 255 {
    None
  } else {
    Some(Int32::to_byte(sum))
  }
}

///|
pub fn SummaryDomain::byte() -> SummaryDomain[Byte, Byte] {
  SummaryDomain(0, apply=checked_add_byte, compose=checked_add_byte, less_equal=fn(
    a,
    b,
  ) {
    a <= b
  })
}
