///|
test "min-plus feedback propagates shorter routes and zero-weight cycles" {
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
    weight,
  ) {
    distances[node] = match distances.get(node) {
      None => weight.value
      Some(old) => if old < weight.value { old } else { weight.value }
    }
  })
  roots.update(0, MinSum(0U))
  roots.close()
  for (a, b, w) in [(0, 1, 5U), (1, 2, 5U), (0, 2, 15U)] {
    edges.update((a, b), MinSum(w))
  }
  edges.advance_to(1L)
  edges.flush()
  let _ = worker.run()
  assert_false(probe.less_than(1L))
  assert_eq(distances.get(2), Some(10U))
  for (a, b, w) in [(0, 2, 3U), (2, 3, 0U), (3, 2, 0U), (3, 1, 1U)] {
    edges.update((a, b), MinSum(w))
  }
  edges.close()
  let _ = worker.run()
  assert_true(probe.done())
  let snapshot = distances.to_array()
  snapshot.sort()
  assert_eq(snapshot, [(0, 0U), (1, 4U), (2, 3U), (3, 3U)])
  worker.dispose()
}
