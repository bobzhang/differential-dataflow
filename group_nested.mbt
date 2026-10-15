///|
pub struct NestedScopeGroup[A, B, S, U] {
  priv nested : Array[NestedScope[A, B, S, U]]
  priv child : ScopeGroup[Product[A, B], Product[S, U]]
}

///|
pub fn[A : Lattice, B : Lattice, S : Compare, U : Compare] ScopeGroup::nested(
  self : ScopeGroup[A, S],
  minimum : B,
  domain : SummaryDomain[B, U],
) -> NestedScopeGroup[A, B, S, U] {
  let nested = self.scopes.map(fn(outer) {
    let inner = outer.worker.make_scope(
      Product(outer.minimum, minimum),
      SummaryDomain::product(outer.domain, domain),
      false,
    )
    { outer, inner, minimum, }
  })
  let child = coordinate_scopes(nested.map(fn(nested) { nested.inner }))
  { nested, child, }
}

///|
pub fn[A, B, S, U] NestedScopeGroup::scope(
  self : NestedScopeGroup[A, B, S, U],
) -> ScopeGroup[Product[A, B], Product[S, U]] {
  self.child
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] NestedScopeGroup::enter(
  self : NestedScopeGroup[A, B, S, U],
  sources : Array[Collection[D, A, R]],
) -> Array[Collection[D, Product[A, B], R]] {
  guard sources.length() == self.nested.length() else {
    abort("enter needs one collection per peer")
  }
  Array::makei(sources.length(), fn(index) {
    self.nested[index].enter(sources[index])
  })
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] NestedScopeGroup::leave(
  self : NestedScopeGroup[A, B, S, U],
  sources : Array[Collection[D, Product[A, B], R]],
) -> Array[Collection[D, A, R]] {
  guard sources.length() == self.nested.length() else {
    abort("leave needs one collection per peer")
  }
  Array::makei(sources.length(), fn(index) {
    self.nested[index].leave(sources[index])
  })
}

///|
/// Build a fixed point over all peers. Use the child group's exchange method to
/// colocate equal keys before keyed operators inside the iterative computation.
pub fn[D, T : Lattice, R : Abelian, S : Compare] ScopeGroup::iterate(
  self : ScopeGroup[T, S],
  sources : Array[Collection[D, T, R]],
  logic : (
    ScopeGroup[Product[T, Int64], Product[S, Int64]],
    Array[Collection[D, Product[T, Int64], R]],
  ) -> Array[Collection[D, Product[T, Int64], R]],
) -> Array[Collection[D, T, R]] {
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let entered = nested.enter(sources)
  let variables = Array::makei(entered.length(), fn(index) {
    child
    .scope(index)
    .variable_from(
      entered[index],
      Product(self.scopes[index].domain.identity, 1L),
    )
  })
  let result = logic(child, variables.map(fn(variable) { variable.1 }))
  guard result.length() == variables.length() else {
    abort("iteration needs one result per peer")
  }
  for index, variable in variables {
    variable.0.set(result[index])
  }
  nested.leave(result)
}
