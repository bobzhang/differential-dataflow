///|
test "custom source activations are coalesced and can cooperatively resume" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activate = builder.activator()
  let (output, stream) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  let seen = []
  let probe = stream.inspect(fn(data, time, diff) {
    seen.push((data, time, diff))
  })
  let mut next = 0
  let mut invocations = 0
  builder.build(fn(initial) {
    let cap = initial[0]
    fn() {
      invocations += 1
      if next < 16 {
        output.send(cap, [(next, 1L)])
        next += 1
        if next == 16 {
          cap.release()
        } else {
          cap.downgrade(next.to_int64())
          activate.activate()
          activate.activate()
        }
      }
    }
  })
  activate.activate()
  activate.clone().activate()
  assert_true(worker.run(max_steps=5) is StepLimit(_))
  assert_true(worker.run() is Quiescent(_))
  assert_eq(invocations, 17)
  assert_eq(seen, Array::makei(16, fn(i) { (i, i.to_int64(), 1L) }))
  assert_true(probe.done())
  assert_true(worker.next_activation() is None)
  worker.dispose()
  assert_false(activate.try_activate())
  activate.activate_after(Duration(1UL))
}

///|
test "timed activations expose host wakeup delays and preserve duplicate deadline semantics" {
  let now = Ref(@differential.Duration(0UL))
  let worker = @differential.Worker(clock=fn() { now.val })
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activate = builder.activator()
  let (_, stream) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  let probe = stream.probe()
  let held : Ref[@differential.Capability[Int64, Int64]?] = Ref(None)
  let mut calls = 0
  builder.build(fn(initial) {
    held.val = Some(initial[0])
    fn() { calls += 1 }
  })
  let _ = worker.run()
  assert_eq(calls, 1)
  activate.activate_after(Duration(1UL, nanoseconds=500U))
  activate.activate_after(Duration(1UL, nanoseconds=500U))
  activate.activate_after(Duration(3UL))
  assert_eq(worker.next_activation(), Some(Duration(1UL, nanoseconds=500U)))
  now.val = Duration(1UL, nanoseconds=499U)
  let _ = worker.run()
  assert_eq(calls, 1)
  assert_eq(worker.next_activation(), Some(Duration(0UL, nanoseconds=1U)))
  now.val = Duration(1UL, nanoseconds=500U)
  let _ = worker.run()
  assert_eq(calls, 2)
  assert_eq(
    worker.next_activation(),
    Some(Duration(1UL, nanoseconds=999999500U)),
  )
  activate.activate_after(Duration(0UL))
  activate.activate()
  let _ = worker.run()
  assert_eq(calls, 3)
  now.val = Duration(3UL)
  let _ = worker.run()
  assert_eq(calls, 4)
  assert_true(worker.next_activation() is None)
  held.val.unwrap().release()
  held.val = None
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "panic timed activation without a host clock" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  scope.operator().activator().activate_after(Duration(1UL))
}

///|
test "panic monotonic activation clock moved backward" {
  let now = Ref(@differential.Duration(5UL))
  let worker = @differential.Worker(clock=fn() { now.val })
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activate = builder.activator()
  builder.build(fn(_) { fn() { () } })
  activate.activate_after(Duration(1UL))
  now.val = Duration(4UL)
  let _ = worker.run()
}
