///|
test "upserts order times and resolve equal-time ties by greatest optional value" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, upserts) : (
    @differential.InputSession[(Int32, Int32?), Int64, @differential.Present],
    @differential.Collection[(Int32, Int32?), Int64, @differential.Present],
  ) = scope.input()
  let arranged = upserts.arrange_from_upsert()
  let trace = arranged.trace()
  arranged.release()
  let seen = []
  let probe = arranged
    .as_collection()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update_at((1, None), 2, Present)
  input.update_at((1, Some(5)), 0, Present)
  input.update_at((1, Some(3)), 0, Present)
  input.update_at((1, None), 0, Present)
  input.update_at((1, Some(5)), 1, Present)
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(@differential.consolidate_updates(seen), [
    ((1, 5), 0L, 1L),
    ((1, 5), 2L, -1L),
  ])
  assert_eq(trace.snapshot(0), [((1, 5), 1L)])
  assert_eq(trace.snapshot(1), [((1, 5), 1L)])
  assert_true(trace.snapshot(2).is_empty())
  trace.release()
  worker.dispose()
}
