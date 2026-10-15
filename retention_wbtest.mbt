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

///|
test "reduction compacts twenty thousand completed epochs to current state" {
  let state : Reduction[Int32, Int64, Int64, Int64, Int64] = Reduction()
  let visible : Map[Int64, Int64] = Map([])
  for epoch in 0L..<20000L {
    if epoch > 0 {
      state.update(0, epoch, -1)
    }
    state.update(0, epoch, 1)
    state.update(1, epoch, 1)
    let (ready, pending) = state.advance(Antichain([epoch + 1]), fn(values) {
      [(values.iter().fold(init=0L, fn(sum, entry) { sum + entry.1 }), 1L)]
    })
    for (value, _, diff) in ready {
      visible[value] = visible.get(value).unwrap_or(0) + diff
    }
    assert_true(pending.is_empty())
    assert_true(state.history.length() <= 2)
    assert_eq(state.emitted.length(), 1)
    assert_eq(visible.get(epoch + 2), Some(1L))
    if epoch > 0 {
      assert_eq(visible.get(epoch + 1), Some(0L))
    }
  }
}

///|
test "compacted reduction holds only unemitted corrections" {
  let state : Reduction[Int32, Int32, Product[Int64, Int64], Int64, Int64] = Reduction()
  state.update(0, Product(0, 1), 1)
  state.update(0, Product(1, 0), 1)
  let logic = fn(_ : Array[(Int32, Int64)]) { [(0, 1L)] }
  let (initial, _) = state.advance(Antichain([Product(1, 1)]), logic)
  assert_eq(initial.length(), 2)
  let (ready, _) = state.advance(Antichain([Product(2, 1)]), logic)
  assert_eq(ready, [(0, Product(1, 1), -1L)])
  let (unchanged, pending) = state.advance(Antichain([Product(2, 1)]), logic)
  assert_true(unchanged.is_empty())
  assert_true(pending.is_empty())
}
