///|
test "bidirectional search retracts paths and preserves repeated goal weights" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (goals, queries) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let observed : Map[((Int32, Int32), UInt32), Int64] = Map([])
  let probe = scope
    .bidijkstra(graph, queries)
    .inspect(fn(data, _, diff) {
      observed[data] = observed.get(data).unwrap_or(0L) + diff
    })
  for edge in [(0, 1), (1, 2), (2, 3), (0, 3)] {
    edges.insert(edge)
  }
  goals.update((0, 3), 2L)
  goals.insert((3, 0))
  goals.insert((2, 2))
  edges.advance_to(1)
  goals.advance_to(1)
  edges.flush()
  goals.flush()
  assert_true(worker.run() is Quiescent(_))
  assert_true(!probe.less_than(1))
  assert_eq(observed.get(((0, 3), 1U)), Some(2L))
  assert_eq(observed.get(((2, 2), 0U)), Some(1L))
  edges.remove((0, 3))
  edges.close()
  goals.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  assert_eq(observed.get(((0, 3), 1U)), Some(0L))
  assert_eq(observed.get(((0, 3), 3U)), Some(2L))
  assert_true(
    observed
    .to_array()
    .filter(fn(x) { x.1 != 0L && x.0.0 == (3, 0) })
    .is_empty(),
  )
  worker.dispose()
}

///|
test "sequential graph updates combine new lower and old higher neighbors" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, states) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (edges, graph) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let observed : Map[(Int32, Int32?), Int64] = Map([])
  let probe = scope
    .sequence(states, graph, fn(_, values) {
      values
      .iter()
      .fold(init=1, fn(sum, value) { sum + value.0 * value.1.to_int() })
    })
    .inspect(fn(data, _, diff) {
      observed[data] = observed.get(data).unwrap_or(0L) + diff
    })
  for state in [(0, 10), (1, 20), (2, 30)] {
    input.insert(state)
  }
  for edge in [(0, 1), (1, 0), (1, 2), (2, 1)] {
    edges.insert(edge)
  }
  input.close()
  edges.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  let rows = observed.to_array().filter(fn(x) { x.1 != 0L })
  rows.sort()
  assert_eq(rows, [
    ((0, Some(21)), 1L),
    ((1, Some(52)), 1L),
    ((2, Some(53)), 1L),
  ])
  worker.dispose()
}
