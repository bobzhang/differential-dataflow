///|
test "completed builtin pipelines release task closures while the worker remains active" {
  let worker = Worker()
  for epoch in 0..<32 {
    let scope = worker.scope(0L, SummaryDomain::int64())
    let (input, data) : (
      InputSession[(Int32, Int32), Int64, Int64],
      Collection[(Int32, Int32), Int64, Int64],
    ) = scope.input()
    let arranged = data.map(fn(x) { x }).filter(fn(_) { true }).arrange_by_key()
    let result = arranged.join(arranged, fuel=2).map(fn(x) { x.0 }).distinct()
    let mut total = 0L
    let probe = result.inspect(fn(_, _, r) { total += r })
    arranged.release()
    for key in 0..<8 {
      input.insert((key, epoch))
    }
    input.close()
    let _ = worker.run()
    assert_true(probe.done())
    assert_eq(total, 8L)
    assert_true(worker.tasks.iter().all(fn(task) { task is None }))
    assert_true(worker.retirement.is_empty())
    assert_true(
      worker.scheduler.finalizers.iter().all(fn(items) { items.is_empty() }),
    )
  }
  worker.dispose()
}

///|
test "builtin retirement waits for deferred lookup answers and does not release an open sibling" {
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let (input, data) : (
    InputSession[(Int32, Int32), Int64, Int64],
    Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = data.arrange_by_key()
  let trace = arranged.trace()
  let (query, queries) : (
    InputSession[(Int32, Int64), Int64, Int64],
    Collection[(Int32, Int64), Int64, Int64],
  ) = scope.input()
  let seen = []
  let probe = trace
    .lookup(queries, multiply=fn(a, b) { a * b })
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  trace.release()
  arranged.release()
  query.insert((1, 0L))
  query.close()
  let _ = worker.run()
  assert_false(probe.done())
  assert_true(worker.tasks.iter().all(fn(task) { task is Some(_) }))
  input.insert((1, 7))
  input.advance_to(1L)
  input.flush()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(seen, [((1, 7), 0L, 1L)])
  assert_true(worker.tasks[0] is Some(_))
  assert_true(worker.tasks[1] is None)
  assert_true(worker.tasks[2] is None)
  input.close()
  let _ = worker.run()
  assert_true(worker.tasks.iter().all(fn(task) { task is None }))
  worker.dispose()
}

///|
test "closed live trace imports release their task without disposing the consumer" {
  let producer = Worker()
  let scope = producer.scope(0L, SummaryDomain::int64())
  let (input, data) : (
    InputSession[(Int32, Int32), Int64, Int64],
    Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = data.arrange_by_key()
  let trace = arranged.trace()
  let consumer = Worker()
  let imported = trace.import_into(consumer.scope(0L, SummaryDomain::int64()))
  let probe = imported.probe()
  arranged.release()
  input.insert((1, 2))
  input.close()
  let _ = producer.run()
  let _ = consumer.run()
  assert_true(probe.done())
  assert_true(consumer.tasks.iter().all(fn(task) { task is None }))
  assert_eq(trace.snapshot(0L), [((1, 2), 1L)])
  trace.release()
  producer.dispose()
  consumer.dispose()
}
