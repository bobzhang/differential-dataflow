///|
/// A nested timestamp domain coordinated by the same distributed cluster.
pub struct DistributedNestedScope[A, B, S, U] {
  priv nested : NestedScope[A, B, S, U]
  priv child : DistributedScope[Product[A, B], Product[S, U]]
}

///|
pub fn[A : Lattice, B : Lattice, S : Compare, U : Compare] DistributedScope::nested(
  self : DistributedScope[A, S],
  minimum : B,
  domain : SummaryDomain[B, U],
  time_codec~ : WireCodec[B],
  summary_codec~ : WireCodec[U],
) -> DistributedNestedScope[A, B, S, U] {
  let child = self.cluster.scope(
    Product(self.scope.minimum, minimum),
    SummaryDomain::product(self.scope.domain, domain),
    time_codec=WireCodec::product(self.time_codec, time_codec),
    summary_codec=WireCodec::product(self.summary_codec, summary_codec),
  )
  { nested: { outer: self.scope, inner: child.scope, minimum, }, child, }
}

///|
pub fn[A, B, S, U] DistributedNestedScope::scope(
  self : DistributedNestedScope[A, B, S, U],
) -> DistributedScope[Product[A, B], Product[S, U]] {
  self.child
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] DistributedNestedScope::enter(
  self : DistributedNestedScope[A, B, S, U],
  source : Collection[D, A, R],
) -> Collection[D, Product[A, B], R] {
  self.nested.enter(source)
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] DistributedNestedScope::leave(
  self : DistributedNestedScope[A, B, S, U],
  source : Collection[D, Product[A, B], R],
) -> Collection[D, A, R] {
  self.nested.leave(source)
}

///|
/// Exchange within the child scope before applying keyed fixed-point operators.
pub fn[D, T : Lattice, R : Abelian, S : Compare] DistributedScope::iterate(
  self : DistributedScope[T, S],
  source : Collection[D, T, R],
  logic : (
    DistributedScope[Product[T, Int64], Product[S, Int64]],
    Collection[D, Product[T, Int64], R],
  ) -> Collection[D, Product[T, Int64], R],
) -> Collection[D, T, R] {
  let nested = self.nested(
    0L,
    SummaryDomain::int64(),
    time_codec=WireCodec::json(),
    summary_codec=WireCodec::json(),
  )
  let child = nested.scope()
  let (variable, values) = child.scope.variable_from(
    nested.enter(source),
    Product(self.scope.domain.identity, 1L),
  )
  let result = logic(child, values)
  variable.set(result)
  nested.leave(result)
}
