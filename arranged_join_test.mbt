///|
test "arranged self join counts each delta pair once across queued batches" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = values.arrange_by_key()
  let seen = []
  let probe = arranged
    .join(arranged)
    .consolidate()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  arranged.release()
  input.insert((1, 2))
  input.advance_to(1)
  input.flush()
  input.insert((1, 3))
  input.advance_to(2)
  input.flush()
  input.remove((1, 2))
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  seen.sort()
  assert_eq(seen, [
    ((1, (2, 2)), 0L, 1L),
    ((1, (2, 2)), 2L, -1L),
    ((1, (2, 3)), 1L, 1L),
    ((1, (2, 3)), 2L, -1L),
    ((1, (3, 2)), 1L, 1L),
    ((1, (3, 2)), 2L, -1L),
    ((1, (3, 3)), 1L, 1L),
  ])
  worker.dispose()
}

///|
test "arranged joins preserve incomparable timestamp joins and weights" {
  let worker = @differential.Worker()
  let domain = @differential.SummaryDomain::product(
    @differential.SummaryDomain::int64(),
    @differential.SummaryDomain::int64(),
  )
  let scope = worker.scope(@differential.Product(0L, 0L), domain)
  let (a, left) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = scope.input()
  let (b, right) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = scope.input()
  let l = left.arrange_by_key()
  let r = right.arrange_by_key()
  let seen = []
  let probe = l
    .join(r)
    .consolidate()
    .inspect(fn(d, t, w) { seen.push((d, t, w)) })
  l.release()
  r.release()
  a.update_at((1, 10), Product(1L, 0L), 2L)
  a.update_at((1, 10), Product(3L, 0L), -1L)
  b.update_at((1, 20), Product(0L, 2L), 3L)
  a.close()
  b.close()
  let _ = worker.run()
  assert_true(probe.done())
  seen.sort()
  assert_eq(seen, [
    ((1, (10, 20)), Product(1L, 2L), 6L),
    ((1, (10, 20)), Product(3L, 2L), -3L),
  ])
  worker.dispose()
}
