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
  assert_true(worker.tasks[0] is None)
  assert_true(worker.tasks[1] is Some(_))
  assert_eq(worker.retirement.length(), 1)
  assert_true(worker.scheduler.queue.is_empty())
  assert_true(worker.scheduler.timers.is_empty())
  worker.dispose()
}
