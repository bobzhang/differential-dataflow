///|
#export_name("evaluate_graphs")
pub fn evaluate_graphs(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (roots, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let edges_index = graph.arrange_by_key()
  let view = edges_index.view()
  let streams = [
    scope
    .bfs_arranged(view, source)
    .map(fn(x) { (x.0, x.1.reinterpret_as_int()) }),
    scope.propagate_core(view, source.map(fn(x) { (x, x) }), fn(_) { 0UL }),
    scope.strongly_connected(graph),
    scope.propagate_core(view, source.map(fn(x) { (x, x) }), fn(x) {
      1UL << (x * 15)
    }),
    scope.strongly_connected_at(graph, fn(x) { 1UL << (x * 15) }),
  ]
  view.release()
  edges_index.release()
  let observed : Map[(Int32, Int32, Int32), Int64] = Map([])
  let probes = Array::makei(streams.length(), fn(op) {
    streams[op].inspect(fn(data, _, diff) {
      let key = (op, data.0, data.1)
      observed[key] = observed.get(key).unwrap_or(0L) + diff
    })
  })
  let mut random = seed.reinterpret_as_uint()
  let weights = Array::make(25, 0L)
  let active = Array::make(5, false)
  let results = []
  for epoch in 0L..<12L {
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 25U).reinterpret_as_int()
      let next = if weights[index] == 0L {
        (random % 2U).to_int64() + 1L
      } else {
        0L
      }
      edges.update((index / 5, index % 5), next - weights[index])
      weights[index] = next
    }
    random = random * 1664525U + 1013904223U
    let node = ((random >> 8) % 5U).reinterpret_as_int()
    active[node] = !active[node]
    roots.update(node, if active[node] { 1L } else { -1L })
    edges.advance_to(epoch + 1)
    roots.advance_to(epoch + 1)
    edges.flush()
    roots.flush()
    guard worker.run(max_steps=100000) is Quiescent(_) &&
      probes.iter().all(fn(probe) { !probe.less_than(epoch + 1) }) else {
      abort("graph algorithms failed to converge")
    }
    let current = observed.to_array().filter(fn(x) { x.1 != 0L })
    current.sort()
    results.push(
      current.map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1}" }).join(";"),
    )
  }
  edges.close()
  roots.close()
  guard worker.run(max_steps=100000) is Quiescent(_) &&
    probes.iter().all(fn(probe) { probe.done() }) else {
    abort("graph algorithms failed to close")
  }
  worker.dispose()
  results.join("/")
}
