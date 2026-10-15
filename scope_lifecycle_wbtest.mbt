///|
test "finished local scopes reclaim progress tables while sibling scopes keep running" {
  let worker = Worker()
  let sibling = worker.scope(0L, SummaryDomain::int64())
  let (held, data) : (
    InputSession[Int32, Int64, Int64],
    Collection[Int32, Int64, Int64],
  ) = sibling.input()
  let probe = data.map(fn(x) { x + 1 }).probe()
  let mut total = 0L
  for epoch in 0..<64 {
    let scope = worker.scope(0L, SummaryDomain::int64())
    let (input, data) : (
      InputSession[Int32, Int64, Int64],
      Collection[Int32, Int64, Int64],
    ) = scope.input()
    let child = scope.nested(0L, SummaryDomain::int64())
    let done = child
      .leave(child.enter(data).map(fn(x) { x * 2 }))
      .inspect(fn(_, _, r) { total += r })
    input.insert(epoch)
    input.close()
    let _ = worker.run()
    assert_true(done.done())
    assert_true(scope.progress.disposed)
    assert_true(child.inner.progress.disposed)
    assert_true(scope.progress.graph.edges.is_empty())
    assert_true(scope.progress.observers.is_empty())
    assert_true(scope.progress.tracker is None)
    assert_false(sibling.progress.disposed)
    assert_false(probe.done())
  }
  assert_eq(total, 64L)
  held.close()
  let _ = worker.run()
  assert_true(sibling.progress.disposed)
  worker.dispose()
}

///|
test "empty progress does not reclaim a scope with unfinished external work" {
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let builder = scope.operator()
  let activator = builder.activator()
  let pending = Ref(true)
  builder.build_reschedule(fn(_) { fn() { pending.val } })
  let _ = worker.run()
  assert_false(scope.progress.disposed)
  pending.val = false
  activator.activate()
  let _ = worker.run()
  assert_true(scope.progress.disposed)
  assert_false(activator.try_activate())
  worker.dispose()
}
