///|
/// A timestamp lattice with a unique global minimum. SummaryDomain carries the
/// associated path-summary operations separately, rather than as a Rust type.
pub(open) trait Timestamp: Lattice {
  fn minimum() -> Self
}

///|
pub impl Timestamp for Int8 with fn minimum() {
  Int8(-128)
}

///|
pub impl Timestamp for Byte with fn minimum() {
  0
}

///|
pub impl Timestamp for Int16 with fn minimum() {
  -32768
}

///|
pub impl Timestamp for UInt16 with fn minimum() {
  0
}

///|
pub impl Timestamp for Int32 with fn minimum() {
  -2147483648
}

///|
pub impl Timestamp for UInt32 with fn minimum() {
  0U
}

///|
pub impl Timestamp for Int64 with fn minimum() {
  -9223372036854775808L
}

///|
pub impl Timestamp for UInt64 with fn minimum() {
  0UL
}

///|
pub impl Timestamp for Int128 with fn minimum() {
  Int128::from_words(-9223372036854775808L, 0UL)
}

///|
pub impl Timestamp for UInt128 with fn minimum() {
  UInt128(0UL)
}

///|
pub impl Timestamp for Duration with fn minimum() {
  Duration(0UL)
}

///|
pub impl Timestamp for Unit with fn minimum() {
  ()
}

///|
pub impl[A : Timestamp, B : Timestamp] Timestamp for Product[A, B] with fn minimum() {
  Product(A::minimum(), B::minimum())
}

///|
/// A runtime-length product timestamp. Missing coordinates are Timestamp.minimum;
/// construction removes trailing minimum coordinates and copies the input array.
pub struct PointStamp[T] {
  priv vector : Array[T]
} derive(Eq, Debug)

///|
pub fn[T : Timestamp] PointStamp::PointStamp(
  vector : Array[T],
) -> PointStamp[T] {
  let vector = vector.copy()
  while !vector.is_empty() && vector[vector.length() - 1] == T::minimum() {
    let _ = vector.pop()
  }
  { vector, }
}

///|
pub fn[T] PointStamp::to_array(self : PointStamp[T]) -> Array[T] {
  self.vector.copy()
}

///|
pub impl[T : Compare] Compare for PointStamp[T] with fn compare(self, other) {
  for i in 0..<Int32::min(self.vector.length(), other.vector.length()) {
    let c = self.vector[i].compare(other.vector[i])
    if c != 0 {
      return c
    }
  }
  self.vector.length().compare(other.vector.length())
}

///|
pub impl[T : Timestamp] Lattice for PointStamp[T] with fn less_equal(
  self,
  other,
) {
  for i, time in self.vector {
    let next = if i < other.vector.length() {
      other.vector[i]
    } else {
      T::minimum()
    }
    if !Lattice::less_equal(time, next) {
      return false
    }
  }
  true
}

///|
pub impl[T : Timestamp] Lattice for PointStamp[T] with fn join(self, other) {
  let coordinates = Array::makei(
    Int32::max(self.vector.length(), other.vector.length()),
    fn(i) {
      if i >= self.vector.length() {
        other.vector[i]
      } else if i >= other.vector.length() {
        self.vector[i]
      } else {
        Lattice::join(self.vector[i], other.vector[i])
      }
    },
  )
  PointStamp(coordinates)
}

///|
pub impl[T : Timestamp] Lattice for PointStamp[T] with fn meet(self, other) {
  PointStamp(
    Array::makei(Int32::min(self.vector.length(), other.vector.length()), fn(
      i,
    ) {
      Lattice::meet(self.vector[i], other.vector[i])
    }),
  )
}

///|
pub impl[T : Timestamp] Timestamp for PointStamp[T] with fn minimum() {
  PointStamp([])
}

///|
/// Truncate to retain coordinates (None retains all), then apply per-coordinate
/// actions, extending missing coordinates from the timestamp minimum as needed.
pub struct PointStampSummary[S] {
  priv retain : Int32?
  priv actions : Array[S]
} derive(Eq, Debug)

///|
pub fn[S] PointStampSummary::PointStampSummary(
  actions : Array[S],
  retain? : Int32,
) -> PointStampSummary[S] {
  if retain is Some(n) {
    guard n >= 0 else { abort("negative pointstamp retention") }
  }
  { retain, actions: actions.copy(), }
}

///|
pub fn[S] PointStampSummary::retain(self : PointStampSummary[S]) -> Int32? {
  self.retain
}

///|
pub fn[S] PointStampSummary::actions(self : PointStampSummary[S]) -> Array[S] {
  self.actions.copy()
}

///|
pub impl[S : Compare] Compare for PointStampSummary[S] with fn compare(
  self,
  other,
) {
  let retain = self.retain.compare(other.retain)
  if retain != 0 {
    return retain
  }
  for i in 0..<Int32::min(self.actions.length(), other.actions.length()) {
    let c = self.actions[i].compare(other.actions[i])
    if c != 0 {
      return c
    }
  }
  self.actions.length().compare(other.actions.length())
}

///|
pub fn[T : Timestamp, S] SummaryDomain::pointstamp(
  inner : SummaryDomain[T, S],
) -> SummaryDomain[PointStamp[T], PointStampSummary[S]] {
  SummaryDomain(
    PointStampSummary([]),
    apply=fn(summary, time) {
      let length = match summary.retain {
        None => time.vector.length()
        Some(n) => Int32::min(n, time.vector.length())
      }
      let output = []
      for i in 0..<Int32::max(length, summary.actions.length()) {
        let time = if i < length { time.vector[i] } else { T::minimum() }
        if i < summary.actions.length() {
          guard inner.results_in(summary.actions[i], time) is Some(next) else {
            return None
          }
          output.push(next)
        } else {
          output.push(time)
        }
      }
      Some(PointStamp(output))
    },
    compose=fn(first, second) {
      let retain = match (first.retain, second.retain) {
        (Some(a), Some(b)) => Some(Int32::min(a, b))
        (None, b) => b
        (a, None) => a
      }
      let length = match second.retain {
        None => first.actions.length()
        Some(n) => Int32::min(n, first.actions.length())
      }
      let actions = []
      for i in 0..<Int32::max(length, second.actions.length()) {
        if i < length && i < second.actions.length() {
          guard inner.followed_by(first.actions[i], second.actions[i])
            is Some(next) else {
            return None
          }
          actions.push(next)
        } else if i < length {
          actions.push(first.actions[i])
        } else {
          actions.push(second.actions[i])
        }
      }
      Some(PointStampSummary(actions, retain?))
    },
    less_equal=fn(a, b) {
      if a.retain != b.retain || a.actions.length() > b.actions.length() {
        return false
      }
      for i, action in a.actions {
        if !(inner.less_equal)(action, b.actions[i]) {
          return false
        }
      }
      true
    },
  )
}

///|
/// Feedback at a one-based runtime scope level; earlier coordinates are unchanged.
pub fn[T, S] SummaryDomain::feedback_summary(
  self : SummaryDomain[T, S],
  level : Int32,
  action : S,
) -> PointStampSummary[S] {
  guard level > 0 else { abort("dynamic scope levels start at one") }
  let actions = Array::make(level - 1, self.identity)
  actions.push(action)
  PointStampSummary(actions)
}

///|
/// Dynamic entry requires no physical coordinate: absent coordinates are minimum.
pub fn[D, A, B, R] Collection::enter_dynamic(
  self : Collection[D, Product[A, PointStamp[B]], R],
  level : Int32,
) -> Collection[D, Product[A, PointStamp[B]], R] {
  guard level >= 0 else { abort("negative dynamic scope level") }
  self
}

///|
/// Leave the one-based dynamic level, discarding that and deeper coordinates.
pub fn[D, A : Lattice, B : Timestamp, R, S, U] Scope::leave_dynamic(
  self : Scope[Product[A, PointStamp[B]], Product[S, PointStampSummary[U]]],
  source : Collection[D, Product[A, PointStamp[B]], R],
  level : Int32,
) -> Collection[D, Product[A, PointStamp[B]], R] {
  guard level > 0 else { abort("dynamic scope levels start at one") }
  let summary = Product(
    self.domain.identity.outer,
    PointStampSummary([], retain=level - 1),
  )
  let (edge, result) = self.feedback(summary)
  edge.connect(source)
  result
}

///|
pub extend Int8 with Timestamp::{minimum}

///|
pub extend Int128 with Timestamp::{minimum}

///|
pub extend UInt128 with Timestamp::{minimum}

///|
pub extend Duration with Timestamp::{minimum}

///|
pub extend Product with Timestamp::{minimum}

///|
pub extend PointStamp with Timestamp::{minimum}

///|
pub extend PointStamp with Eq::{equal, not_equal}

///|
pub extend PointStamp with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend PointStamp with Debug::{to_repr}

///|
pub extend PointStampSummary with Eq::{equal, not_equal}

///|
pub extend PointStampSummary with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend PointStampSummary with Debug::{to_repr}

///|
pub extend PointStamp with Lattice::{less_equal, join, meet}

///|
/// Encode runtime timestamp coordinates using an explicit scalar codec.
pub fn[T : Timestamp] WireCodec::pointstamp(
  scalar : WireCodec[T],
) -> WireCodec[PointStamp[T]] {
  WireCodec(
    encode=fn(value) { Json(value.to_array().map(fn(x) { scalar.to_json(x) })) },
    decode=fn(value) {
      guard value is Array(values) else { return None }
      let coordinates = []
      for value in values {
        guard scalar.from_json(value) is Some(value) else { return None }
        coordinates.push(value)
      }
      Some(PointStamp(coordinates))
    },
  )
}

///|
/// Encode truncation and coordinate actions for distributed dynamic scopes.
pub fn[S] WireCodec::pointstamp_summary(
  scalar : WireCodec[S],
) -> WireCodec[PointStampSummary[S]] {
  WireCodec(
    encode=fn(value) {
      [
        Json(value.retain()),
        Json(value.actions().map(fn(x) { scalar.to_json(x) })),
      ]
    },
    decode=fn(value) {
      guard value is [retain, Array(values)] else { return None }
      let retain : Int32? = @json.from_json(retain) catch { _ => return None }
      if retain is Some(n) && n < 0 {
        return None
      }
      let actions = []
      for value in values {
        guard scalar.from_json(value) is Some(value) else { return None }
        actions.push(value)
      }
      Some(PointStampSummary(actions, retain?))
    },
  )
}
