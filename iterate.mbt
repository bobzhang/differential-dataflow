///|
/// A differential fixed-point variable. Set its definition once before execution.
pub struct Variable[D, T, R, S] {
  priv feedback : Feedback[D, T, R, S]
  priv source : Collection[D, T, R]?
}

///|
pub fn[D, T : Lattice, R, S] Scope::variable(
  self : Scope[T, S],
  step : S,
) -> (Variable[D, T, R, S], Collection[D, T, R]) {
  let (feedback, collection) = self.feedback(step)
  ({ feedback, source: None, }, collection)
}

///|
pub fn[D, T : Lattice, R : Abelian, S] Scope::variable_from(
  self : Scope[T, S],
  source : Collection[D, T, R],
  step : S,
) -> (Variable[D, T, R, S], Collection[D, T, R]) {
  let (feedback, collection) = self.feedback(step)
  ({ feedback, source: Some(source.negate()), }, source.concat(collection))
}

///|
/// Feed the definition back once. Variables created with variable_from carry
/// a pre-negated initial source, so those records are not reinjected. Empty
/// variables require no subtraction and support semigroup-only differences.
pub fn[D, T : Lattice, R, S] Variable::set(
  self : Variable[D, T, R, S],
  definition : Collection[D, T, R],
) -> Unit {
  let updates = match self.source {
    None => definition
    Some(source) => definition.concat(source)
  }
  self.feedback.connect(updates)
}

///|
/// Iteration uses a nested Int64 coordinate starting at zero and advancing by one.
/// The returned collection contains changes to the fixed point at each outer time.
pub fn[D, T : Lattice, R : Abelian, S : Compare] Scope::iterate(
  self : Scope[T, S],
  source : Collection[D, T, R],
  logic : (
    Scope[Product[T, Int64], Product[S, Int64]],
    Collection[D, Product[T, Int64], R],
  ) -> Collection[D, Product[T, Int64], R],
) -> Collection[D, T, R] {
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let (variable, collection) = child.variable_from(
    nested.enter(source),
    Product(self.domain.identity, 1L),
  )
  let result = logic(child, collection)
  variable.set(result)
  nested.leave(result)
}
