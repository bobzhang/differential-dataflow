///|
/// One sequential update of node states in Compare order. Lower neighbors supply
/// their new state; higher neighbors supply their input state. As upstream, nodes
/// with no incoming messages are absent from the result, and self-edges are ignored.
pub fn[N : Compare + Hash, V : Compare, T : Lattice, S : Compare] Scope::sequence(
  self : Scope[T, S],
  state : Collection[(N, V), T, Int64],
  edges : Collection[(N, N), T, Int64],
  logic : (N, Array[(V, Int64)]) -> V,
) -> Collection[(N, V?), T, Int64] {
  let initial = state.map(fn(value) { (value.0, (None : V?)) })
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let old_state = nested.enter(state)
  let edges = nested.enter(edges)
  let forward = edges.filter(fn(edge) { Compare::compare(edge.0, edge.1) < 0 })
  let reverse = edges.filter(fn(edge) { Compare::compare(edge.0, edge.1) > 0 })
  let (variable, new_state) = child.variable_from(
    nested.enter(initial),
    Product(self.domain.identity, 1L),
  )
  let messages = new_state.join_map(
    forward,
    fn(_, value, target) { (target, value) },
    multiply=fn(a, b) { a * b },
  )
  let incomplete = messages
    .filter(fn(value) { value.1 is None })
    .map(fn(value) { value.0 })
    .distinct()
  let new_messages = messages.flat_map(fn(value) {
    match value.1 {
      None => []
      Some(state) => [(value.0, state)]
    }
  })
  let old_messages = old_state.join_map(
    reverse,
    fn(_, value, target) { (target, value) },
    multiply=fn(a, b) { a * b },
  )
  let result = new_messages
    .concat(old_messages)
    .antijoin(incomplete)
    .reduce(fn(key, values) { [(Some(logic(key, values)), 1L)] })
    .concat(incomplete.map(fn(key) { (key, None) }))
  variable.set(result)
  nested.leave(result)
}
