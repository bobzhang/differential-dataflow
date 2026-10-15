///|
/// Bidirectional shortest-path search for dynamic (source, target) goals.
/// Results retain goal multiplicities; unreachable goals produce no record.
/// Searches expand only while a goal involving their root is still unresolved.
pub fn[N : Compare + Hash, T : Lattice, S : Compare] Scope::bidijkstra(
  self : Scope[T, S],
  graph : Collection[(N, N), T, Int64],
  goals : Collection[(N, N), T, Int64],
) -> Collection[((N, N), UInt32), T, Int64] {
  let forward = graph.arrange_by_key()
  defer forward.release()
  let reverse = graph.map(fn(edge) { (edge.1, edge.0) }).arrange_by_key()
  defer reverse.release()
  let forward_view = forward.view()
  defer forward_view.release()
  let reverse_view = reverse.view()
  defer reverse_view.release()
  self.bidijkstra_arranged(forward_view, reverse_view, goals)
}

///|
/// Reuse forward and reversed edge indexes for bidirectional search. The reverse
/// index must describe the same weighted graph with its endpoints exchanged.
pub fn[N : Compare + Hash, T : Lattice, S : Compare] Scope::bidijkstra_arranged(
  self : Scope[T, S],
  forward : ArrangementView[N, N, T, Int64],
  reverse : ArrangementView[N, N, T, Int64],
  goals : Collection[(N, N), T, Int64],
) -> Collection[((N, N), UInt32), T, Int64] {
  same_worker(forward.collection, reverse.collection)
  same_worker(forward.collection, goals)
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let forward_edges = forward.enter(nested)
  defer forward_edges.release()
  let reverse_edges = reverse.enter(nested)
  defer reverse_edges.release()
  let goals = nested.enter(goals)
  let (forward_bind, forward) = child.variable_from(
    goals.map(fn(goal) { (goal.0, (goal.0, 0U)) }),
    Product(self.domain.identity, 1L),
  )
  let (reverse_bind, reverse) = child.variable_from(
    goals.map(fn(goal) { (goal.1, (goal.1, 0U)) }),
    Product(self.domain.identity, 1L),
  )
  let reached = forward
    .join_map(reverse, fn(_, a, b) { ((a.0, b.0), a.1 + b.1) }, multiply=fn(
      a,
      b,
    ) {
      a * b
    })
    .reduce(fn(_, values) { [(values[0].0, 1L)] })
    .semijoin(goals)
  let active = reached
    .negate()
    .map(fn(value) { value.0 })
    .concat(goals)
    .consolidate()
  forward_bind.set(
    expand_search(
      forward,
      forward_edges,
      active.map(fn(goal) { goal.0 }).distinct(),
    ),
  )
  reverse_bind.set(
    expand_search(
      reverse,
      reverse_edges,
      active.map(fn(goal) { goal.1 }).distinct(),
    ),
  )
  nested.leave(reached)
}

///|
fn[N : Compare + Hash, T : Lattice] expand_search(
  states : Collection[(N, (N, UInt32)), T, Int64],
  edges : ArrangementView[N, N, T, Int64],
  active : Collection[N, T, Int64],
) -> Collection[(N, (N, UInt32)), T, Int64] {
  let candidates = states
    .map(fn(state) { (state.1.0, (state.0, state.1.1)) })
    .semijoin(active)
    .map(fn(state) { (state.1.0, (state.0, state.1.1)) })
    .arrange_by_key()
  defer candidates.release()
  let view = candidates.view()
  defer view.release()
  view
  .join_map(edges, fn(_, state, next) { (next, (state.0, state.1 + 1U)) }, multiply=fn(
    a,
    b,
  ) {
    a * b
  })
  .concat(states)
  .map(fn(state) { ((state.0, state.1.0), state.1.1) })
  .reduce(fn(_, values) { [(values[0].0, 1L)] })
  .map(fn(state) { (state.0.0, (state.0.1, state.1)) })
}
