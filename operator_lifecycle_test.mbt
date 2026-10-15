///|
test "incomplete operators await external wakeups and shut down exactly once" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activator = builder.activator()
  let mut calls = 0
  let mut closed = 0
  let finished = Ref(false)
  builder.build_reschedule(
    fn(_) {
      fn() {
        calls += 1
        !finished.val
      }
    },
    on_shutdown=fn() { closed += 1 },
  )
  assert_true(worker.run() is Quiescent(_))
  assert_eq(calls, 1)
  assert_eq(closed, 0)
  assert_true(worker.next_activation() is None)
  assert_true(activator.try_activate())
  let _ = worker.run()
  assert_eq(calls, 2)
  finished.val = true
  activator.activate()
  let _ = worker.run()
  assert_eq(calls, 3)
  assert_eq(closed, 1)
  assert_false(activator.try_activate())
  activator.activate_after(Duration(9UL))
  assert_true(worker.next_activation() is None)
  let _ = worker.run()
  assert_eq(calls, 3)
  worker.dispose()
  worker.dispose()
  assert_eq(closed, 1)
}

///|
test "external capabilities keep operators alive and schedule final shutdown" {
  let worker = @differential.Worker(clock=fn() { Duration(0UL) })
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let activator = builder.activator()
  let (_, stream) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  let held : Ref[@differential.Capability[Int64, Int64]?] = Ref(None)
  let mut calls = 0
  let mut closed = 0
  builder.build(
    fn(caps) {
      held.val = Some(caps[0])
      fn() { calls += 1 }
    },
    on_shutdown=fn() { closed += 1 },
  )
  let probe = stream.probe()
  let _ = worker.run()
  assert_eq(closed, 0)
  assert_eq(calls, 1)
  activator.activate_after(Duration(5UL))
  held.val.unwrap().release()
  held.val = None
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(calls, 2)
  assert_eq(closed, 1)
  assert_true(worker.next_activation() is None)
  assert_false(activator.try_activate())
  worker.dispose()
  assert_eq(closed, 1)
}

///|
test "operator sees final input frontier before retirement and retains pending data" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (source, stream) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let builder = scope.operator()
  let input = builder.new_input(stream)
  let mut seen = 0
  let mut final_frontiers = 0
  let mut closed = 0
  builder.build(
    fn(_) {
      fn() {
        input.for_each(fn(_, records) { seen += records.length() })
        if input.frontier().is_empty() {
          final_frontiers += 1
        }
      }
    },
    on_shutdown=fn() { closed += 1 },
  )
  source.insert(1)
  source.insert(2)
  source.close()
  let _ = worker.run()
  assert_eq(seen, 2)
  assert_eq(final_frontiers, 1)
  assert_eq(closed, 1)
  worker.dispose()
  assert_eq(closed, 1)
}

///|
test "worker disposal shuts down incomplete operators once" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let builder = scope.operator()
  let mut closed = 0
  builder.build_reschedule(fn(_) { fn() { true } }, on_shutdown=fn() {
    closed += 1
  })
  let _ = worker.run()
  worker.dispose()
  worker.dispose()
  assert_eq(closed, 1)
}
