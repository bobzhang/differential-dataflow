///|
test "retirement releases task closures and removes only their queued wakeups" {
  let worker = Worker(clock=fn() { Duration(0UL) })
  let scope = worker.scope(0L, SummaryDomain::int64())
  let first = scope.operator()
  let activate = first.activator()
  first.build(fn(_) {
    fn() {
      activate.activate()
      activate.activate_after(Duration(10UL))
    }
  })
  let second = scope.operator()
  let mut calls = 0
  second.build_reschedule(fn(_) {
    fn() {
      calls += 1
      true
    }
  })
  assert_eq(worker.run(), Quiescent(2))
  assert_eq(calls, 1)
  assert_true(worker.tasks.get(0) is None)
  assert_true(worker.tasks.get(1) is Some(_))
  assert_eq(worker.retirement.length(), 1)
  assert_true(worker.scheduler.queue.is_empty())
  assert_true(worker.scheduler.timers.is_empty())
  worker.dispose()
}

///|
test "retired task metadata is removed and stale activators cannot target fresh operators" {
  let worker = Worker(clock=fn() { Duration(0UL) })
  let persistent = worker.scope(0L, SummaryDomain::int64()).operator()
  let wake = persistent.activator()
  let keep = Ref(true)
  let mut persistent_calls = 0
  persistent.build_reschedule(fn(_) {
    fn() {
      persistent_calls += 1
      keep.val
    }
  })
  let old : Array[Activator] = []
  let mut shutdowns = 0
  for _ in 0..<256 {
    let scope = worker.scope(0L, SummaryDomain::int64())
    for _ in 0..<8 {
      let builder = scope.operator()
      let activator = builder.activator()
      old.push(activator)
      builder.build(
        fn(_) { fn() { activator.activate_after(Duration(10UL)) } },
        on_shutdown=fn() { shutdowns += 1 },
      )
    }
    let _ = worker.run()
    assert_eq(worker.tasks.length(), 1)
    assert_eq(worker.scheduler.slots.length(), 1)
    assert_true(worker.scheduler.timers.is_empty())
    assert_false(old[old.length() - 1].try_activate())
    assert_false(old[0].try_activate())
  }
  assert_eq(shutdowns, 2048)
  assert_eq(persistent_calls, 1)
  assert_eq(worker.scheduler.next_task, 2049)
  keep.val = false
  assert_true(wake.try_activate())
  let _ = worker.run()
  assert_eq(persistent_calls, 2)
  assert_true(worker.tasks.is_empty())
  assert_true(worker.scheduler.slots.is_empty())
  for stale in old {
    assert_false(stale.try_activate())
  }
  worker.dispose()
  assert_eq(shutdowns, 2048)
}
