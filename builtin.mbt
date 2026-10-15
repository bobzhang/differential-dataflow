///|
pub impl Lattice for Int32 with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for Int32 with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Int32 with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for Int32

///|
fn checked_add_int32(a : Int32, b : Int32) -> Int32? {
  let sum = a + b
  if (b > 0 && sum < a) || (b < 0 && sum > a) {
    None
  } else {
    Some(sum)
  }
}

///|
pub fn SummaryDomain::int32() -> SummaryDomain[Int32, Int32] {
  SummaryDomain(0, apply=checked_add_int32, compose=checked_add_int32, less_equal=fn(
    a,
    b,
  ) {
    a <= b
  })
}

///|
pub impl Lattice for UInt32 with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for UInt32 with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for UInt32 with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for UInt32

///|
fn checked_add_uint32(a : UInt32, b : UInt32) -> UInt32? {
  let sum = a + b
  if sum < a {
    None
  } else {
    Some(sum)
  }
}

///|
pub fn SummaryDomain::uint32() -> SummaryDomain[UInt32, UInt32] {
  SummaryDomain(0, apply=checked_add_uint32, compose=checked_add_uint32, less_equal=fn(
    a,
    b,
  ) {
    a <= b
  })
}

///|
pub impl Semigroup for UInt32 with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for UInt32 with fn is_zero(self) {
  self == 0
}

///|
pub impl Monoid for UInt32 with fn zero() {
  0
}

///|
pub impl Lattice for UInt64 with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for UInt64 with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for UInt64 with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for UInt64

///|
fn checked_add_uint64(a : UInt64, b : UInt64) -> UInt64? {
  let sum = a + b
  if sum < a {
    None
  } else {
    Some(sum)
  }
}

///|
pub fn SummaryDomain::uint64() -> SummaryDomain[UInt64, UInt64] {
  SummaryDomain(0, apply=checked_add_uint64, compose=checked_add_uint64, less_equal=fn(
    a,
    b,
  ) {
    a <= b
  })
}

///|
pub impl Semigroup for UInt64 with fn plus(self, other) {
  self + other
}

///|
pub impl Semigroup for UInt64 with fn is_zero(self) {
  self == 0
}

///|
pub impl Monoid for UInt64 with fn zero() {
  0
}

///|
pub impl Lattice for Unit with fn less_equal(_, _) {
  true
}

///|
pub impl Lattice for Unit with fn join(_, _) {
  ()
}

///|
pub impl Lattice for Unit with fn meet(_, _) {
  ()
}

///|
pub impl TotalOrder for Unit

///|
pub fn SummaryDomain::unit() -> SummaryDomain[Unit, Unit] {
  SummaryDomain(
    (),
    apply=fn(_, _) { Some(()) },
    compose=fn(_, _) { Some(()) },
    less_equal=fn(_, _) { true },
  )
}
