///|
test "live trace lookup waits for sealing and preserves query timestamps and weights" {
  let (writer, reader) : (
    @differential.TraceWriter[(Int32, String), Int64, Int64],
    @differential.TraceAgent[(Int32, String), Int64, Int64],
  ) = @differential.shared_trace(0)
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, queries) : (
    @differential.InputSession[(Int32, Int64), Int64, Int64],
    @differential.Collection[(Int32, Int64), Int64, Int64],
  ) = scope.input()
  let seen = []
  let probe = reader
    .lookup(queries, multiply=fn(a, b) { a * b })
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update((1, 3L), 2)
  input.close()
  let _ = worker.run()
  assert_true(seen.is_empty())
  assert_eq(probe.frontier().to_array(), [0L])
  writer.insert(
    Batch([((1, "x"), 1L, 3L)], lower=Antichain([0L]), upper=Antichain([3L])),
  )
  let _ = worker.run()
  assert_true(seen.is_empty())
  writer.insert(
    Batch(
      [((1, "x"), 3L, -1L), ((1, "y"), 3L, 1L)],
      lower=Antichain([3L]),
      upper=Antichain([4L]),
    ),
  )
  let _ = worker.run()
  assert_eq(seen, [((1, "x"), 0L, 4L), ((1, "y"), 0L, 2L)])
  assert_true(probe.done())
  assert_eq(reader.lookup_at(2, 3), [])
  reader.release()
  worker.dispose()
}

///|
test "lookup completion also works with acyclic forwarding progress" {
  let (writer, reader) : (
    @differential.TraceWriter[(Int32, Int32), Int64, Int64],
    @differential.TraceAgent[(Int32, Int32), Int64, Int64],
  ) = @differential.shared_trace(0)
  let worker = @differential.Worker()
  let (input, queries) : (
    @differential.InputSession[(Int32, Int64), Int64, Int64],
    @differential.Collection[(Int32, Int64), Int64, Int64],
  ) = worker.input(0)
  let seen = []
  let probe = reader
    .lookup(queries, multiply=fn(a, b) { a * b })
    .inspect(fn(d, _, r) { seen.push((d, r)) })
  input.insert((1, 1L))
  input.close()
  let _ = worker.run()
  assert_true(!probe.done())
  writer.insert(
    Batch([((1, 7), 0L, 1L)], lower=Antichain([0L]), upper=Antichain([])),
  )
  let _ = worker.run()
  assert_eq(seen, [((1, 7), 1L)])
  assert_true(probe.done())
  reader.release()
  worker.dispose()
}
