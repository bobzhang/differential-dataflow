///|
test "shared probe tracks incomparable frontiers across attached streams" {
  let worker = @differential.Worker()
  let minimum = @differential.Product(0L, 0L)
  let domain = @differential.SummaryDomain::product(
    @differential.SummaryDomain::int64(),
    @differential.SummaryDomain::int64(),
  )
  let scope = worker.scope(minimum, domain)
  let (left, a) : (
    @differential.InputSession[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = scope.input()
  let (right, b) : (
    @differential.InputSession[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = scope.input()
  let shared = @differential.Probe()
  assert_true(shared.done())
  let seen = []
  let _ = a
    .probe_with(shared)
    .concat(b.probe_with(shared))
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  assert_false(shared.done())
  left.insert(1)
  left.advance_to(Product(1L, 0L))
  left.flush()
  right.insert(2)
  right.advance_to(Product(0L, 1L))
  right.flush()
  let _ = worker.run()
  let frontier = shared.frontier().to_array()
  frontier.sort()
  assert_eq(frontier, [Product(0L, 1L), Product(1L, 0L)])
  assert_false(shared.less_equal(Product(0L, 0L)))
  assert_true(shared.less_equal(Product(1L, 1L)))
  left.close()
  let _ = worker.run()
  assert_eq(shared.frontier().to_array(), [Product(0L, 1L)])
  right.close()
  let _ = worker.run()
  assert_true(shared.done())
  assert_eq(@differential.consolidate_updates(seen), [
    (1, minimum, 1L),
    (2, minimum, 1L),
  ])
  // A shared handle may be reused for a fresh dataflow after its old inputs close.
  let next = worker.scope(minimum, domain)
  let (input, source) : (
    @differential.InputSession[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = next.input()
  let _ = source.probe_with(shared)
  assert_false(shared.done())
  input.close()
  let _ = worker.run()
  assert_true(shared.done())
  worker.dispose()
}

///|
test "collection composition and in-place mapping preserve weighted timestamp equality" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let mapped = source.map_in_place(fn(value) { value.val *= 3 })
  let combined = scope.concatenate([mapped, mapped.negate(), mapped])
  let checked = combined.assert_eq(source.map(fn(d) { d * 3 }))
  let empty : @differential.Collection[Int32, Int64, Int64] = scope.concatenate([],
  )
  let empty_probe = empty.assert_empty()
  input.update_at(3, 5L, 7L)
  input.update_at(3, 5L, -2L)
  input.update_at(4, 8L, -3L)
  input.close()
  let _ = worker.run()
  assert_true(checked.done() && empty_probe.done())
  worker.dispose()
}

///|
test "panic collection assert_empty detects nonzero consolidated updates" {
  let worker = @differential.Worker()
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0L)
  let _ = source.assert_empty()
  input.insert(1)
  input.close()
  ignore(worker.run())
}
