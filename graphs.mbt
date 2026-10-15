///|
/// Shortest unweighted distance from any root, maintained as edges and roots change.
/// This follows upstream's iterative join-and-minimum formulation.
pub fn[N : Compare + Hash, T : Lattice, S : Compare] Scope::bfs(
  self : Scope[T, S],
  edges : Collection[(N, N), T, Int64],
  roots : Collection[N, T, Int64],
) -> Collection[(N, UInt32), T, Int64] {
  same_worker(edges, roots)
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let links = nested.enter(edges)
  let seeds = nested.enter(roots).map(fn(node) { (node, 0U) })
  let (variable, distances) = child.variable(Product(self.domain.identity, 1L))
  let result = distances
    .join_map(links, fn(_, distance, target) { (target, distance + 1U) }, multiply=fn(
      a,
      b,
    ) {
      a * b
    })
    .concat(seeds)
    .reduce(fn(_, values) { [(values[0].0, 1L)] })
  variable.set(result)
  nested.leave(result)
}

///|
/// Forward propagation of the minimum label reachable at each node.
pub fn[N : Compare + Hash, L : Compare, T : Lattice, S : Compare, R : Ring] Scope::propagate(
  self : Scope[T, S],
  edges : Collection[(N, N), T, R],
  nodes : Collection[(N, L), T, R],
) -> Collection[(N, L), T, R] {
  self.propagate_at(edges, nodes, fn(_) { 0UL })
}

///|
/// Stagger label introduction with upstream's 256 * bit_length(priority) schedule.
/// Scheduling affects intermediate work; converged labels retain original times.
pub fn[N : Compare + Hash, L : Compare, T : Lattice, S : Compare, R : Ring] Scope::propagate_at(
  self : Scope[T, S],
  edges : Collection[(N, N), T, R],
  nodes : Collection[(N, L), T, R],
  priority : (L) -> UInt64,
) -> Collection[(N, L), T, R] {
  same_worker(edges, nodes)
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let links = nested.enter(edges)
  let seeds = nested.enter_at(nodes, fn(data, _) {
    let mut value = priority(data.1)
    let mut bits = 0L
    while value != 0UL {
      bits += 1
      value = value >> 1
    }
    bits * 256
  })
  let (variable, proposals) = child.variable(Product(self.domain.identity, 1L))
  let labels = proposals
    .concat(seeds)
    .reduce(fn(_, values) { [(values[0].0, R::one())] })
  variable.set(
    labels.join_map(links, fn(_, label, target) { (target, label) }, multiply=fn(
      a,
      b,
    ) {
      a.multiply(b)
    }),
  )
  nested.leave(labels)
}

///|
/// Keep precisely the original edges whose endpoints are in the same strongly
/// connected component. Edge weights are retained; this is not a component-ID map.
pub fn[N : Compare + Hash, T : Lattice, S : Compare, R : Ring] Scope::strongly_connected(
  self : Scope[T, S],
  graph : Collection[(N, N), T, R],
) -> Collection[(N, N), T, R] {
  self.strongly_connected_at(graph, fn(_) { 0UL })
}

///|
pub fn[N : Compare + Hash, T : Lattice, S : Compare, R : Ring] Scope::strongly_connected_at(
  self : Scope[T, S],
  graph : Collection[(N, N), T, R],
  priority : (N) -> UInt64,
) -> Collection[(N, N), T, R] {
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let edges = nested.enter(graph)
  let reverse = edges.map(fn(edge) { (edge.1, edge.0) })
  let (variable, inner) = child.variable_from(
    edges,
    Product(self.domain.identity, 1L),
  )
  let result = trim_graph_edges(
    child,
    trim_graph_edges(child, inner, edges, priority),
    reverse,
    priority,
  )
  variable.set(result)
  nested.leave(result)
}

///|
fn[N : Compare + Hash, T : Lattice, S : Compare, R : Ring] trim_graph_edges(
  scope : Scope[T, S],
  cycle : Collection[(N, N), T, R],
  edges : Collection[(N, N), T, R],
  priority : (N) -> UInt64,
) -> Collection[(N, N), T, R] {
  let nodes = edges.map(fn(edge) { (edge.1, edge.1) }).consolidate()
  let labels = scope.propagate_at(cycle, nodes, priority)
  edges
  .join_map(labels, fn(source, target, label) { (target, (source, label)) }, multiply=fn(
    a,
    b,
  ) {
    a.multiply(b)
  })
  .join_map(
    labels,
    fn(target, previous, label) { ((previous.0, target), (previous.1, label)) },
    multiply=fn(a, b) { a.multiply(b) },
  )
  .filter(fn(value) { value.1.0 == value.1.1 })
  .map(fn(value) { (value.0.1, value.0.0) })
}
