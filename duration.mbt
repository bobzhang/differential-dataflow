///|
/// Rust Duration-compatible timestamp: unsigned seconds and subsecond nanoseconds.
pub struct Duration {
  priv seconds : UInt64
  priv nanos : UInt32
} derive(Eq, Compare, Debug, Hash)

///|
/// Normalize nanoseconds; overflow beyond the largest duration is rejected.
pub fn Duration::Duration(
  seconds : UInt64,
  nanoseconds~ : UInt32 = 0,
) -> Duration {
  let carry = (nanoseconds / 1000000000U).to_uint64()
  guard checked_add_uint64(seconds, carry) is Some(seconds) else {
    abort("duration overflow")
  }
  { seconds, nanos: nanoseconds % 1000000000U, }
}

///|
pub fn Duration::seconds(self : Duration) -> UInt64 {
  self.seconds
}

///|
pub fn Duration::nanoseconds(self : Duration) -> UInt32 {
  self.nanos
}

///|
pub fn Duration::checked_add(self : Duration, other : Duration) -> Duration? {
  guard checked_add_uint64(self.seconds, other.seconds) is Some(seconds) else {
    return None
  }
  let nanos = self.nanos + other.nanos
  guard checked_add_uint64(seconds, (nanos / 1000000000U).to_uint64())
    is Some(seconds) else {
    return None
  }
  Some({ seconds, nanos: nanos % 1000000000U, })
}

///|
pub impl Lattice for Duration with fn less_equal(self, other) {
  self <= other
}

///|
pub impl Lattice for Duration with fn join(self, other) {
  if self > other {
    self
  } else {
    other
  }
}

///|
pub impl Lattice for Duration with fn meet(self, other) {
  if self < other {
    self
  } else {
    other
  }
}

///|
pub impl TotalOrder for Duration

///|
pub extend Duration with Eq::{equal, not_equal}

///|
pub extend Duration with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend Duration with Debug::{to_repr}

///|
pub extend Duration with Hash::{hash, hash_combine}

///|
pub extend Duration with Lattice::{less_equal, join, meet}

///|
pub fn SummaryDomain::duration() -> SummaryDomain[Duration, Duration] {
  SummaryDomain(
    Duration(0),
    apply=fn(a, b) { a.checked_add(b) },
    compose=fn(a, b) { a.checked_add(b) },
    less_equal=fn(a, b) { a <= b },
  )
}
