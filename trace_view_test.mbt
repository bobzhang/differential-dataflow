///|
test "entered trace views project compaction and exact cuts like upstream" {
  let (writer, root) : (
    @differential.TraceWriter[(Int32, Int32), Int64, Int64],
    @differential.TraceAgent[(Int32, Int32), Int64, Int64],
  ) = @differential.shared_trace(0L)
  let reader = root.reader()
  let entered = reader.enter(0L)
  let pinned = entered.clone()
  reader.release()
  root.release()
  writer.insert(
    Batch([((1, 2), 0L, 1L)], lower=Antichain([0L]), upper=Antichain([1L])),
  )
  assert_eq(entered.snapshot(Product(0L, 7L)), [((1, 2), 1L)])
  entered.set_logical_compaction(Antichain([Product(1L, 5L)]))
  assert_eq(entered.logical_compaction().to_array(), [Product(1L, 0L)])
  assert_eq(pinned.snapshot(Product(0L, 0L)), [((1, 2), 1L)])
  let batches = entered.batches_through(Antichain([Product(1L, 99L)])).unwrap()
  assert_eq(batches.length(), 1)
  assert_eq(batches[0].get(0), Some(((1, 2), Product(0L, 0L), 1L)))
  pinned.release()
  writer.insert(Batch([], lower=Antichain([1L]), upper=Antichain([2L])))
  assert_eq(entered.snapshot(Product(1L, 0L)), [((1, 2), 1L)])
  let cursor = entered.cursor()
  assert_eq(cursor.key(), Some(1))
  assert_eq(cursor.val(), Some(2))
  assert_eq(cursor.times(), [(Product(1L, 0L), 1L)])
  entered.release()
  // A batch view retains its immutable storage after reader release/compaction.
  assert_eq(batches[0].get(0), Some(((1, 2), Product(0L, 0L), 1L)))
}

///|
test "entered arrangements join and reduce shared indexes through retractions" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (a, left) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (b, right) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let left = left.arrange_by_key()
  let right = right.arrange_by_key()
  let nested = scope.nested(0L, @differential.SummaryDomain::int64())
  let lview = left.enter(nested)
  let rview = right.enter(nested)
  let joined : Map[(Int32, (Int32, Int32)), Int64] = Map([])
  let p0 = nested
    .leave(lview.join(rview))
    .inspect(fn(data, _, diff) {
      joined[data] = joined.get(data).unwrap_or(0L) + diff
    })
  let counts : Map[(Int32, Int64), Int64] = Map([])
  let p1 = nested
    .leave(
      lview.reduce(fn(_, values) {
        [(values.iter().fold(init=0L, fn(sum, value) { sum + value.1 }), 1L)]
      }),
    )
    .inspect(fn(data, _, diff) {
      counts[data] = counts.get(data).unwrap_or(0L) + diff
    })
  lview.release()
  rview.release()
  left.release()
  right.release()
  for epoch in 0L..<64L {
    a.update((1, 10), if epoch % 2 == 0 { 1L } else { -1L })
    b.update((1, 20), 1L)
    a.advance_to(epoch + 1)
    b.advance_to(epoch + 1)
    a.flush()
    b.flush()
    assert_true(worker.run() is Quiescent(_))
    assert_true(!p0.less_than(epoch + 1) && !p1.less_than(epoch + 1))
    assert_eq(
      joined.get((1, (10, 20))).unwrap_or(0L),
      if epoch % 2 == 0 {
        epoch + 1
      } else {
        0L
      },
    )
    assert_eq(
      counts.get((1, 1L)).unwrap_or(0L),
      if epoch % 2 == 0 {
        1L
      } else {
        0L
      },
    )
  }
  a.close()
  b.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(p0.done() && p1.done())
  worker.dispose()
}
