///|
test "disposing a producer closes its trace and releases surviving import frontiers" {
  let producer = @differential.Worker()
  let scope = producer.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = values.arrange_by_key(fueled=true, columnar=true)
  input.insert((1, 2))
  input.advance_to(1L)
  input.flush()
  let _ = producer.run()
  let reader = arranged.trace()
  let consumer = @differential.Worker()
  let target = consumer.scope(0L, @differential.SummaryDomain::int64())
  let seen = []
  let probe = reader
    .import_into(target)
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let _ = consumer.run()
  assert_eq(seen, [((1, 2), 0L, 1L)])
  assert_false(probe.done())
  // Unsealed future data is canceled along with the producer's graph.
  input.insert((3, 4))
  input.flush()
  producer.dispose()
  let _ = consumer.run()
  assert_true(probe.done())
  assert_true(reader.upper().is_empty())
  assert_eq(reader.snapshot(2L), [((1, 2), 1L)])
  reader.release()
  arranged.release()
  consumer.dispose()
}
