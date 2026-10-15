///|
test "shared readers pin independent logical and physical compaction" {
  let (writer, slow) : (
    @differential.TraceWriter[(Int32, Int32), Int64, Int64],
    @differential.TraceAgent[(Int32, Int32), Int64, Int64],
  ) = @differential.shared_trace(0)
  let fast = slow.clone()
  for time in 0L..<3L {
    writer.insert(
      Batch(
        [((1, 2), time, 1L)],
        lower=Antichain([time]),
        upper=Antichain([time + 1]),
      ),
    )
  }
  fast.set_logical_compaction(Antichain([2L]))
  fast.set_physical_compaction(Antichain([3L]))
  assert_eq(slow.snapshot(0), [((1, 2), 1L)])
  assert_eq(fast.snapshot(2), [((1, 2), 3L)])
  assert_true(slow.batches_through(Antichain([1L])) is Some(_))
  slow.release()
  assert_eq(fast.snapshot(2), [((1, 2), 3L)])
  assert_eq(fast.batches_through(Antichain([3L])).unwrap().length(), 1)
  fast.release()
  fast.release()
  writer.insert(Batch([], lower=Antichain([3L]), upper=Antichain([])))
  assert_true(writer.upper().is_empty())
}

///|
test "arrangement shares sealed snapshots and one consolidated stream" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, String), Int64, Int64],
    @differential.Collection[(Int32, String), Int64, Int64],
  ) = scope.input()
  let arranged = values.arrange_by_key()
  let a = arranged.trace()
  let b = arranged.trace()
  arranged.release()
  let seen = []
  let probe = arranged
    .as_collection()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.insert((1, "x"))
  input.insert((1, "x"))
  input.advance_to(1)
  input.flush()
  let _ = worker.run()
  assert_eq(a.snapshot(0), [((1, "x"), 2L)])
  assert_eq(b.snapshot(0), a.snapshot(0))
  input.remove((1, "x"))
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(b.snapshot(1), [((1, "x"), 1L)])
  assert_eq(seen, [((1, "x"), 0L, 2L), ((1, "x"), 1L, -1L)])
  a.release()
  b.release()
  worker.dispose()
}
