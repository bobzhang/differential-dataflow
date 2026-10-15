///|
test "dropping a dataflow cancels nested work and preserves an unrelated sibling" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let nested = scope.nested(0L, @differential.SummaryDomain::int64())
  let region = nested.scope().region()
  assert_eq(scope.dataflow_index(), 0)
  assert_eq(region.scope().dataflow_index(), 0)
  assert_eq(worker.next_dataflow_index(), 1)
  let (output, cap, data) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Capability[Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.source()
  let seen = []
  let result = nested.leave(
    region.leave(region.enter(nested.enter(data))).map(fn(x) { x + 1 }),
  )
  let probe = result.inspect(fn(d, _, _) { seen.push(d) })
  let builder = region.scope().operator()
  let wake = builder.activator()
  let mut closes = 0
  builder.build_reschedule(fn(_) { fn() { true } }, on_shutdown=fn() {
    closes += 1
  })
  let sibling = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, data) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = sibling.input()
  let live = data.inspect(fn(d, _, _) { seen.push(d) })
  output.send(cap, [(3, 1L)])
  let _ = worker.run()
  assert_eq(seen, [4])
  // This queued value must not escape the cancelled dataflow.
  output.send(cap, [(10, 1L)])
  worker.drop_dataflow(scope.dataflow_index())
  assert_eq(worker.installed_dataflows(), [1])
  // As in Timely, cancellation does not report discarded work as complete.
  assert_false(probe.done())
  assert_false(live.done())
  assert_false(cap.is_live())
  assert_false(output.accepts(cap))
  assert_false(wake.try_activate())
  cap.release()
  input.insert(99)
  input.close()
  let _ = worker.run()
  assert_eq(seen, [4, 99])
  assert_eq(closes, 1)
  assert_true(live.done())
  assert_false(worker.has_dataflows())
  worker.drop_dataflow(0)
  worker.drop_dataflow(12345)
  worker.dispose()
  assert_eq(closes, 1)
}

///|
test "dropping a producer closes surviving trace imports and permits new dataflows" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, data) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = data.arrange_by_key()
  let trace = arranged.trace()
  arranged.release()
  let consumer = worker.scope(0L, @differential.SummaryDomain::int64())
  let observed = []
  let probe = trace
    .import_into(consumer)
    .inspect(fn(d, _, r) { observed.push((d, r)) })
  input.insert((1, 7))
  input.advance_to(1L)
  input.flush()
  let _ = worker.run()
  input.insert((2, 8))
  worker.drop_dataflow(scope.dataflow_index())
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(observed, [((1, 7), 1L)])
  assert_eq(trace.snapshot(0L), [((1, 7), 1L)])
  assert_false(worker.has_dataflows())
  let id = worker.next_dataflow_index()
  let replacement = worker.scope(0L, @differential.SummaryDomain::int64())
  assert_eq(replacement.dataflow_index(), id)
  assert_true(id > consumer.dataflow_index())
  worker.drop_dataflow(id)
  assert_false(worker.has_dataflows())
  trace.release()
  worker.dispose()
}
