///|
/// The min-plus semigroup used by upstream monoid-bfs.rs: accumulation keeps the
/// shorter distance and joining paths adds their lengths. There is no zero or
/// subtraction. This example accepts edge additions and decreasing weights.
pub(all) struct MinSum {
  value : UInt32
} derive(Eq, Compare, Debug)

///|
pub fn MinSum::MinSum(value : UInt32) -> MinSum {
  { value, }
}

///|
pub impl @differential.Semigroup for MinSum with fn plus(self, other) {
  if self.value <= other.value {
    self
  } else {
    other
  }
}

///|
pub impl @differential.Semigroup for MinSum with fn is_zero(_self) {
  false
}

///|
/// Adding path lengths wraps at UInt32's maximum, as the release-mode upstream
/// example does. Callers must keep reachable distances within that range.
pub fn MinSum::multiply(self : MinSum, other : MinSum) -> MinSum {
  MinSum(self.value + other.value)
}

///|
pub extend MinSum with Eq::{equal, not_equal}

///|
pub extend MinSum with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend MinSum with Debug::{to_repr}

///|
pub extend MinSum with @differential.Semigroup::{plus, is_zero}

///|
/// Incremental shortest paths with min-plus weights. Insert roots with distance
/// zero. New edges and lower weights propagate improvements until convergence;
/// edge removals and increasing weights require an Abelian formulation instead.
pub fn monoid_bfs(
  scope : @differential.Scope[Int64, Int64],
  edges : @differential.Collection[(Int32, Int32), Int64, MinSum],
  roots : @differential.Collection[Int32, Int64, MinSum],
) -> @differential.Collection[Int32, Int64, MinSum] {
  let nested = scope.nested(0L, @differential.SummaryDomain::int64())
  let inner = nested.scope()
  let (variable, collection) = inner.variable(Product(0L, 1L))
  let entered_edges = nested.enter(edges).arrange_by_key()
  let entered_roots = nested.enter(roots)
  let paths = collection.map(fn(node) { (node, ()) }).arrange_by_key()
  let reduced = paths
    .join_map(entered_edges, fn(_, _, target) { target }, multiply=fn(
      a : MinSum,
      b : MinSum,
    ) {
      a.multiply(b)
    })
    .concat(entered_roots)
    .map(fn(node) { (node, ()) })
    .reduce_core(fn(_, input, previous : Array[(Unit, MinSum)]) {
      if !input.is_empty() &&
        (previous.is_empty() || input[0].1 < previous[0].1) {
        [((), input[0].1)]
      } else {
        []
      }
    })
  let result = reduced.as_collection().map(fn(pair) { pair.0 })
  variable.set(result)
  reduced.release()
  entered_edges.release()
  paths.release()
  nested.leave(result)
}
