///|
/// Shortest unweighted distance from any root, maintained as edges and roots change.
/// This follows upstream's iterative join-and-minimum formulation.
pub fn[N : Compare + Hash, T : Lattice, S : Compare] Scope::bfs(
  self : Scope[T, S],
  edges : Collection[(N, N), T, Int64],
  roots : Collection[N, T, Int64],
) -> Collection[(N, UInt32), T, Int64] {
  let arranged = edges.arrange_by_key()
  defer arranged.release()
  let view = arranged.view()
  defer view.release()
  self.bfs_arranged(view, roots)
}

///|
/// Reuse an existing edge index for breadth-first distance labeling.
/// The caller retains ownership of the supplied view.
pub fn[N : Compare + Hash, T : Lattice, S : Compare] Scope::bfs_arranged(
  self : Scope[T, S],
  edges : ArrangementView[N, N, T, Int64],
  roots : Collection[N, T, Int64],
) -> Collection[(N, UInt32), T, Int64] {
  same_worker(edges.collection, roots)
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let links = edges.enter(nested)
  defer links.release()
  let seeds = nested.enter(roots).map(fn(node) { (node, 0U) })
  let (variable, distances) = child.variable(Product(self.domain.identity, 1L))
  let index = distances.arrange_by_key()
  defer index.release()
  let view = index.view()
  defer view.release()
  let result = view
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
  let arranged = edges.arrange_by_key()
  defer arranged.release()
  let view = arranged.view()
  defer view.release()
  self.propagate_core(view, nodes, priority)
}

///|
/// Propagate labels using a shared edge index and reuse the reduced label index
/// in the feedback join. Priority controls label introduction as in propagate_at.
pub fn[N : Compare + Hash, L : Compare, T : Lattice, S : Compare, R : Ring] Scope::propagate_core(
  self : Scope[T, S],
  edges : ArrangementView[N, N, T, R],
  nodes : Collection[(N, L), T, R],
  priority : (L) -> UInt64,
) -> Collection[(N, L), T, R] {
  same_worker(edges.collection, nodes)
  let nested = self.nested(0L, SummaryDomain::int64())
  let child = nested.scope()
  let links = edges.enter(nested)
  defer links.release()
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
  let proposals_index = proposals.concat(seeds).arrange_by_key()
  defer proposals_index.release()
  let labels = proposals_index.reduce_arranged(fn(_, values) {
    [(values[0].0, R::one())]
  })
  defer labels.release()
  let label_view = labels.view()
  defer label_view.release()
  variable.set(
    label_view.join_map(links, fn(_, label, target) { (target, label) }, multiply=fn(
      a,
      b,
    ) {
      a.multiply(b)
    }),
  )
  nested.leave(labels.as_collection())
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
