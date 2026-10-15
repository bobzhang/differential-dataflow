///|
test "graph algorithms retract distances labels and SCC edges after a cycle breaks" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (roots, root_stream) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let index = graph.arrange_by_key(fueled=true)
  let view = index.view()
  let distance : Map[(Int32, UInt32), Int64] = Map([])
  let scc : Map[(Int32, Int32), Int64] = Map([])
  let labels : Map[(Int32, Int32), Int64] = Map([])
  let p0 = scope
    .bfs_arranged(view, root_stream)
    .inspect(fn(d, _, r) { distance[d] = distance.get(d).unwrap_or(0L) + r })
  let p1 = scope
    .strongly_connected(graph)
    .inspect(fn(d, _, r) { scc[d] = scc.get(d).unwrap_or(0L) + r })
  let p2 = scope
    .propagate_core(view, root_stream.map(fn(x) { (x, x) }), fn(label) {
      label.to_uint64()
    })
    .inspect(fn(d, _, r) { labels[d] = labels.get(d).unwrap_or(0L) + r })
  view.release()
  index.release()
  for edge in [(0, 1), (1, 2), (2, 1), (2, 3)] {
    edges.insert(edge)
  }
  roots.insert(0)
  edges.advance_to(1)
  roots.advance_to(1)
  edges.flush()
  roots.flush()
  let run = worker.run(max_steps=10000)
  assert_true(run is Quiescent(_))
  let distances = distance.to_array().filter(fn(x) { x.1 != 0L })
  distances.sort()
  assert_eq(distances, [
    ((0, 0U), 1L),
    ((1, 1U), 1L),
    ((2, 2U), 1L),
    ((3, 3U), 1L),
  ])
  let components = scc.to_array().filter(fn(x) { x.1 != 0L })
  components.sort()
  assert_eq(components, [((1, 2), 1L), ((2, 1), 1L)])
  edges.remove((1, 2))
  edges.close()
  roots.close()
  assert_true(worker.run(max_steps=10000) is Quiescent(_))
  assert_true(p0.done() && p1.done() && p2.done())
  let distances = distance.to_array().filter(fn(x) { x.1 != 0L })
  distances.sort()
  assert_eq(distances, [((0, 0U), 1L), ((1, 1U), 1L)])
  assert_true(scc.to_array().filter(fn(x) { x.1 != 0L }).is_empty())
  let labels = labels.to_array().filter(fn(x) { x.1 != 0L })
  labels.sort()
  assert_eq(labels, [((0, 0), 1L), ((1, 0), 1L)])
  worker.dispose()
}

///|
test "SCC and propagation accept wrapping ring weights" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, graph) : (
    @differential.InputSession[
      (Int32, Int32),
      Int64,
      @differential.Wrapping[Int32],
    ],
    @differential.Collection[
      (Int32, Int32),
      Int64,
      @differential.Wrapping[Int32],
    ],
  ) = scope.input()
  let observed : Map[(Int32, Int32), Int32] = Map([])
  let probe = scope
    .strongly_connected(graph)
    .inspect(fn(data, _, diff) {
      observed[data] = observed.get(data).unwrap_or(0) + diff.value()
    })
  for edge in [(0, 1), (1, 2), (2, 1)] {
    input.update(edge, Wrapping(2))
  }
  input.advance_to(1)
  input.flush()
  assert_true(worker.run() is Quiescent(_))
  assert_true(!probe.less_than(1))
  assert_eq(observed.get((1, 2)), Some(2))
  assert_eq(observed.get((2, 1)), Some(2))
  assert_eq(observed.get((0, 1)).unwrap_or(0), 0)
  input.update((1, 2), Wrapping(-2))
  input.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  assert_true(observed.to_array().iter().all(fn(x) { x.1 == 0 }))
  worker.dispose()
}
