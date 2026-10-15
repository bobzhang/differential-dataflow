///|
test "compacted cancellation releases join index keys" {
  let state : Map[Int32, Array[(Int32, Int64, Int64)]] = Map([])
  for key in 0..<1000 {
    state[key] = [(1, 0L, 1L), (1, 1L, -1L)]
  }
  compact_join_state(state, Antichain([2L]))
  assert_true(state.is_empty())
}

///|
test "continuously active scheduler keeps bounded queue storage" {
  let worker = Worker()
  let scheduler = worker.scheduler
  let counters = [0, 0]
  let max_size = Ref(0)
  for index in 0..<2 {
    let _ = worker.register(fn() {
      if counters[index] < 3000 {
        counters[index] += 1
        scheduler.schedule(index)
      }
      if scheduler.queue.length() > max_size.val {
        max_size.val = scheduler.queue.length()
      }
    })
  }
  scheduler.schedule(0)
  scheduler.schedule(1)
  assert_eq(worker.run(), Quiescent(6002))
  assert_true(max_size.val <= 1025)
  assert_true(scheduler.queue.is_empty())
}

///|
test "counted feedback releases pointstamps over two thousand input epochs" {
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let (input, values) : (
    InputSession[Int32, Int64, Int64],
    Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (feedback, looped) = scope.feedback(1L)
  let all = values.concat(looped)
  feedback.connect(
    all.map(fn(x) { x + 1 }).filter(fn(x) { x < 4 }).consolidate(),
  )
  let total = Ref(0L)
  let probe = all.inspect(fn(_, _, r) { total.val += r })
  for epoch in 0L..<2000L {
    input.insert(0)
    input.advance_to((epoch + 1) * 8)
    input.flush()
    guard worker.run(max_steps=200) is Quiescent(_) else {
      fail("feedback stalled")
    }
    assert_eq(total.val, (epoch + 1) * 4)
    assert_true(!probe.less_than(input.time()))
    assert_eq(scope.progress.tracker.unwrap().counts.to_array().length(), 1)
    assert_true(scope.progress.pending.is_empty())
    assert_true(worker.scheduler.queue.is_empty())
  }
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_true(scope.progress.tracker.unwrap().counts.is_empty())
  worker.dispose()
}
