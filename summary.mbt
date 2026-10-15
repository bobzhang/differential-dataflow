///|
/// Explicit timestamp/summary association, replacing Rust's associated Summary type.
/// Functions must obey Timely's monotonicity, identity and composition laws.
pub struct SummaryDomain[T, S] {
  priv identity : S
  priv apply : (S, T) -> T?
  priv compose : (S, S) -> S?
  priv less_equal : (S, S) -> Bool
}

///|
pub fn[T, S] SummaryDomain::SummaryDomain(
  identity : S,
  apply~ : (S, T) -> T?,
  compose~ : (S, S) -> S?,
  less_equal~ : (S, S) -> Bool,
) -> SummaryDomain[T, S] {
  { identity, apply, compose, less_equal, }
}

///|
fn checked_add(a : Int64, b : Int64) -> Int64? {
  let sum = a + b
  if (b > 0 && sum < a) || (b < 0 && sum > a) {
    None
  } else {
    Some(sum)
  }
}

///|
pub fn SummaryDomain::int64() -> SummaryDomain[Int64, Int64] {
  SummaryDomain(0, apply=checked_add, compose=checked_add, less_equal=fn(a, b) {
    a <= b
  })
}

///|
pub fn[A, B, S, U] SummaryDomain::product(
  outer : SummaryDomain[A, S],
  inner : SummaryDomain[B, U],
) -> SummaryDomain[Product[A, B], Product[S, U]] {
  SummaryDomain(
    Product(outer.identity, inner.identity),
    apply=fn(summary, time) {
      guard (outer.apply)(summary.outer, time.outer) is Some(a) else {
        return None
      }
      guard (inner.apply)(summary.inner, time.inner) is Some(b) else {
        return None
      }
      Some(Product(a, b))
    },
    compose=fn(first, second) {
      guard (outer.compose)(first.outer, second.outer) is Some(a) else {
        return None
      }
      guard (inner.compose)(first.inner, second.inner) is Some(b) else {
        return None
      }
      Some(Product(a, b))
    },
    less_equal=fn(a, b) {
      (outer.less_equal)(a.outer, b.outer) &&
      (inner.less_equal)(a.inner, b.inner)
    },
  )
}

///|
pub fn[T, S] SummaryDomain::results_in(
  self : SummaryDomain[T, S],
  summary : S,
  time : T,
) -> T? {
  (self.apply)(summary, time)
}

///|
pub fn[T, S] SummaryDomain::followed_by(
  self : SummaryDomain[T, S],
  first : S,
  second : S,
) -> S? {
  (self.compose)(first, second)
}

///|
pub fn[T, S] SummaryDomain::identity(self : SummaryDomain[T, S]) -> S {
  self.identity
}
