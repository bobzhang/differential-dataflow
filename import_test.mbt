///|
test "trace import replays existing state and follows a separate producer worker" {
  let producer = @differential.Worker()
  let scope = producer.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = values.arrange_by_key()
  input.insert((1, 2))
  input.advance_to(1)
  input.flush()
  let _ = producer.run()
  let reader = arranged.trace()
  let consumer = @differential.Worker()
  let target = consumer.scope(0L, @differential.SummaryDomain::int64())
  let seen = []
  let probe = reader
    .import_into(target)
    .consolidate()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  reader.release()
  arranged.release()
  input.remove((1, 2))
  input.insert((3, 4))
  input.advance_to(2)
  input.flush()
  let _ = producer.run()
  let _ = consumer.run()
  assert_eq(seen, [((1, 2), 0L, 1L), ((1, 2), 1L, -1L), ((3, 4), 1L, 1L)])
  assert_eq(probe.frontier().to_array(), [2L])
  input.close()
  let _ = producer.run()
  let _ = consumer.run()
  assert_true(probe.done())
  consumer.dispose()
  producer.dispose()
}

///|
test "late import advances retained state by its logical frontier" {
  let (writer, reader) : (
    @differential.TraceWriter[Int32, Int64, Int64],
    @differential.TraceAgent[Int32, Int64, Int64],
  ) = @differential.shared_trace(0)
  writer.insert(
    Batch(
      [(7, 0L, 2L), (7, 1L, -1L)],
      lower=Antichain([0L]),
      upper=Antichain([3L]),
    ),
  )
  reader.set_logical_compaction(Antichain([2L]))
  reader.set_physical_compaction(Antichain([3L]))
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let seen = []
  let probe = reader
    .import_into(scope)
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let _ = worker.run()
  assert_eq(seen, [(7, 2L, 1L)])
  assert_eq(probe.frontier().to_array(), [3L])
  writer.insert(Batch([], lower=Antichain([3L]), upper=Antichain([])))
  let _ = worker.run()
  assert_true(probe.done())
  reader.release()
  worker.dispose()
}

///|
test "incomparable logical compaction does not become a stream capability frontier" {
  let (writer, reader) : (
    @differential.TraceWriter[Int32, @differential.Product[Int64, Int64], Int64],
    @differential.TraceAgent[Int32, @differential.Product[Int64, Int64], Int64],
  ) = @differential.shared_trace(Product(0, 0))
  writer.insert(
    Batch(
      [(7, Product(0, 0), 1L)],
      lower=Antichain([Product(0, 0)]),
      upper=Antichain([Product(1, 1)]),
    ),
  )
  reader.set_logical_compaction(Antichain([Product(2L, 0L), Product(0L, 2L)]))
  let worker = @differential.Worker()
  let scope = worker.scope(
    @differential.Product(0L, 0L),
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let seen = []
  let probe = reader
    .import_into(scope)
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let _ = worker.run()
  assert_eq(seen, [(7, Product(0, 0), 1L)])
  assert_eq(probe.frontier().to_array(), [Product(1L, 1L)])
  writer.insert(
    Batch(
      [(7, Product(1, 1), 1L)],
      lower=Antichain([Product(1, 1)]),
      upper=Antichain([Product(2, 2)]),
    ),
  )
  let _ = worker.run()
  assert_eq(seen.length(), 2)
  writer.insert(
    Batch([], lower=Antichain([Product(2, 2)]), upper=Antichain([])),
  )
  let _ = worker.run()
  assert_true(probe.done())
  reader.release()
  worker.dispose()
}

///|
test "frontier trace imports retain filters for historical and live batches" {
  let (writer, root) : (
    @differential.TraceWriter[(Int32, Int32), Int64, Int64],
    @differential.TraceAgent[(Int32, Int32), Int64, Int64],
  ) = @differential.shared_trace(0L)
  writer.insert(
    Batch([((1, 2), 0L, 1L)], lower=Antichain([0L]), upper=Antichain([1L])),
  )
  let reader = root.reader()
  let view = reader.frontier(Antichain([1L]), Antichain([3L]))
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let seen = []
  let probe = view
    .import_into(scope)
    .consolidate()
    .inspect(fn(data, time, diff) { seen.push((data, time, diff)) })
  view.release()
  reader.release()
  root.release()
  writer.insert(
    Batch(
      [((1, 2), 1L, -1L), ((2, 3), 2L, 2L), ((3, 4), 3L, 9L)],
      lower=Antichain([1L]),
      upper=Antichain([4L]),
    ),
  )
  assert_true(worker.run() is Quiescent(_))
  assert_eq(seen, [((2, 3), 2L, 2L)])
  assert_eq(probe.frontier().to_array(), [4L])
  writer.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  worker.dispose()
}
