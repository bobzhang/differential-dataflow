///|
#export_name("evaluate_monoid_bfs")
pub fn evaluate_monoid_bfs(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, @algorithms.MinSum],
    @differential.Collection[(Int32, Int32), Int64, @algorithms.MinSum],
  ) = scope.input()
  let (roots, starts) : (
    @differential.InputSession[Int32, Int64, @algorithms.MinSum],
    @differential.Collection[Int32, Int64, @algorithms.MinSum],
  ) = scope.input()
  let distances : Map[Int32, UInt32] = Map([])
  let probe = @algorithms.monoid_bfs(scope, graph, starts).inspect(fn(
    node,
    _,
    distance,
  ) {
    distances[node] = match distances.get(node) {
      None => distance.value
      Some(old) => if old < distance.value { old } else { distance.value }
    }
  })
  let mut random = seed.reinterpret_as_uint()
  let rows = []
  for epoch in 0L..<16L {
    if epoch == 0 || epoch == 8 {
      random = random * 1664525U + 1013904223U
      roots.update(((random >> 8) % 12U).reinterpret_as_int(), MinSum(0U))
    }
    for _ in 0..<4 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 144U).reinterpret_as_int()
      edges.update((index / 12, index % 12), MinSum(random % 10U))
    }
    roots.advance_to(epoch + 1)
    roots.flush()
    edges.advance_to(epoch + 1)
    edges.flush()
    guard worker.run() is Quiescent(_) && !probe.less_than(epoch + 1) else {
      abort("min-plus graph did not converge")
    }
    let values = distances.to_array()
    values.sort()
    rows.push(values.map(fn(row) { "\{row.0},\{row.1}" }).join(";"))
  }
  roots.close()
  edges.close()
  let _ = worker.run()
  guard probe.done() else { abort("min-plus graph did not close") }
  worker.dispose()
  rows.join("/")
}
