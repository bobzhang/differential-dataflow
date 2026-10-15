///|
test "integer summaries check overflow and compose product paths" {
  let scalar = @differential.SummaryDomain::int64()
  assert_eq(scalar.results_in(5, 3), Some(8L))
  assert_eq(scalar.results_in(1, 9223372036854775807L), None)
  assert_eq(scalar.followed_by(-1, -9223372036854775808L), None)
  let product = @differential.SummaryDomain::product(scalar, scalar)
  assert_eq(
    product.results_in(Product(1, 3), Product(4, 7)),
    Some(Product(5L, 10L)),
  )
}

///|
test "upstream three operator feedback reachability example" {
  let graph = @differential.ProgressGraph(@differential.SummaryDomain::int64())
  for _ in 0..<6 {
    let _ = graph.add_port()
  }
  graph.connect(0, 1, 0)
  graph.connect(1, 2, 0)
  graph.connect(2, 3, 0)
  graph.connect(3, 4, 1)
  graph.connect(4, 5, 0)
  graph.connect(5, 0, 0)
  let tracker = @differential.ProgressTracker(graph.compile().unwrap())
  tracker.update(0, 17, 1)
  assert_true(tracker.frontier(1).is_empty())
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(1).to_array(), [17L])
  assert_eq(tracker.frontier(3).to_array(), [17L])
  assert_eq(tracker.frontier(5).to_array(), [18L])
  tracker.update(0, 17, -1)
  assert_eq(tracker.propagate().length(), 6)
  for port in 0..<6 {
    assert_true(tracker.frontier(port).is_empty())
  }
}

///|
test "incomparable path summaries preserve both ways to reach a port" {
  let scalar = @differential.SummaryDomain::int64()
  let graph = @differential.ProgressGraph(
    @differential.SummaryDomain::product(scalar, scalar),
  )
  let source = graph.add_port()
  let target = graph.add_port()
  graph.connect(source, target, Product(1, 0))
  graph.connect(source, target, Product(0, 1))
  graph.connect(source, target, Product(2, 2))
  let reachable = graph.compile().unwrap()
  assert_eq(reachable.summaries(source, target), [
    Product(0L, 1L),
    Product(1L, 0L),
  ])
  let tracker = @differential.ProgressTracker(reachable)
  tracker.update(source, Product(2, 2), 1)
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(target).to_array(), [
    Product(2L, 3L),
    Product(3L, 2L),
  ])
  tracker.update(source, Product(2, 2), -1)
  tracker.update(source, Product(3, 3), 1)
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(target).to_array(), [
    Product(3L, 4L),
    Product(4L, 3L),
  ])
}

///|
test "nonconverging negative summary cycle reports incomplete compilation" {
  let graph = @differential.ProgressGraph(@differential.SummaryDomain::int64())
  let port = graph.add_port()
  graph.connect(port, port, -1)
  assert_true(graph.compile(max_steps=100) is None)
}

///|
test "random cyclic scalar reachability agrees with Floyd Warshall" {
  for seed in 1..<41 {
    let graph = @differential.ProgressGraph(
      @differential.SummaryDomain::int64(),
    )
    let n = 8
    let distances = Array::makei(n, fn(a) {
      Array::makei(n, fn(b) { if a == b { 0L } else { 1000000L } })
    })
    for _ in 0..<n {
      let _ = graph.add_port()
    }
    let mut random = seed.reinterpret_as_uint()
    for _ in 0..<24 {
      random = random * 1664525U + 1013904223U
      let a = ((random >> 8) % 8U).reinterpret_as_int()
      let b = ((random >> 16) % 8U).reinterpret_as_int()
      let weight = (random % 5U).to_int64()
      graph.connect(a, b, weight)
      if weight < distances[a][b] {
        distances[a][b] = weight
      }
    }
    for k in 0..<n {
      for a in 0..<n {
        for b in 0..<n {
          if distances[a][k] + distances[k][b] < distances[a][b] {
            distances[a][b] = distances[a][k] + distances[k][b]
          }
        }
      }
    }
    let reachable = graph.compile().unwrap()
    for a in 0..<n {
      for b in 0..<n {
        assert_eq(
          reachable.summaries(a, b),
          if distances[a][b] == 1000000L {
            []
          } else {
            [distances[a][b]]
          },
        )
      }
    }
    let tracker = @differential.ProgressTracker(reachable)
    tracker.update(0, 10, 1)
    tracker.update(3, 2, 1)
    let _ = tracker.propagate()
    for b in 0..<n {
      let expected = []
      if distances[0][b] != 1000000L {
        expected.push(distances[0][b] + 10)
      }
      if distances[3][b] != 1000000L {
        expected.push(distances[3][b] + 2)
      }
      expected.sort()
      assert_eq(
        tracker.frontier(b).to_array(),
        if expected.is_empty() {
          []
        } else {
          [expected[0]]
        },
      )
    }
  }
}
