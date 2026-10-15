///|
test "clones hold progress until every earlier capability is released" {
  let graph = @differential.ProgressGraph(@differential.SummaryDomain::int64())
  let port = graph.add_port()
  let tracker = @differential.ProgressTracker(graph.compile().unwrap())
  let cap = tracker.capability(port, 0)
  let copy = cap.clone()
  cap.downgrade(2)
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(port).to_array(), [0L])
  copy.release()
  copy.release()
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(port).to_array(), [2L])
  assert_false(cap.try_downgrade(1))
  assert_eq(cap.time(), 2L)
  let later = cap.delayed(3)
  cap.release()
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(port).to_array(), [3L])
  assert_true(later.valid_for(tracker, port))
  later.release()
  let _ = tracker.propagate()
  assert_true(tracker.frontier(port).is_empty())
}

///|
test "capability sets transfer handles and preserve incomparable capabilities" {
  let scalar = @differential.SummaryDomain::int64()
  let graph = @differential.ProgressGraph(
    @differential.SummaryDomain::product(scalar, scalar),
  )
  let port = graph.add_port()
  let tracker = @differential.ProgressTracker(graph.compile().unwrap())
  let first = tracker.capability(port, Product(1, 0))
  let caps = @differential.CapabilitySet(first)
  assert_false(first.is_live())
  caps.insert(tracker.capability(port, Product(0, 1)))
  caps.insert(tracker.capability(port, Product(3, 3)))
  assert_eq(caps.times(), [Product(0L, 1L), Product(1L, 0L)])
  assert_false(caps.try_downgrade([Product(0, 0)]))
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(port).to_array(), caps.times())
  assert_true(caps.try_downgrade([Product(1, 1)]))
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(port).to_array(), [Product(1L, 1L)])
  let future = caps.try_delayed(Product(2, 2)).unwrap()
  caps.release()
  let _ = tracker.propagate()
  assert_eq(tracker.frontier(port).to_array(), [Product(2L, 2L)])
  future.release()
  let _ = tracker.propagate()
  assert_true(tracker.frontier(port).is_empty())
}

///|
test "panic capability set rejects a different output port" {
  let graph = @differential.ProgressGraph(@differential.SummaryDomain::int64())
  let a = graph.add_port()
  let b = graph.add_port()
  let tracker = @differential.ProgressTracker(graph.compile().unwrap())
  let caps = @differential.CapabilitySet(tracker.capability(a, 0))
  caps.insert(tracker.capability(b, 0))
}
