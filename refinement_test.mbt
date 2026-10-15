///|
test "custom refinement projects reversed product coordinates through feedback" {
  let worker = @differential.Worker()
  let outer = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = outer.input()
  let refinement : @differential.Refinement[
    Int64,
    @differential.Product[Int64, Int64],
    Int64,
    @differential.Product[Int64, Int64],
  ] = Refinement(
    lift=fn(time) { Product(0L, time) },
    project=fn(time) { time.inner },
    summarize=fn(summary) { summary.inner },
  )
  assert_eq(refinement.to_outer(refinement.to_inner(9L)), 9L)
  assert_eq(refinement.summary_to_outer(Product(100L, 2L)), 2L)
  let nested = outer.refine(
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
    refinement,
  )
  let entered = nested.enter_at(values, fn(value, time) {
    Product(value.to_int64(), time)
  })
  let (feedback, looped) = nested.scope().feedback(Product(1L, 0L))
  let all = entered.concat(looped)
  feedback.connect(
    all.filter(fn(value) { value > 0 }).map(fn(value) { value - 1 }),
  )
  let seen = []
  let probe = nested.leave(all).inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.advance_to(2)
  input.insert(7)
  input.advance_to(3)
  input.flush()
  let _ = worker.run()
  seen.sort()
  assert_eq(seen, [ for value in 0..<8 => (value, 2L, 1L) ])
  assert_eq(probe.frontier().to_array(), [3L])
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "identity region preserves data timestamps and closure" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let region = scope.region()
  let seen = []
  let probe = region
    .leave(region.enter(source).map(fn(x) { x * 2 }))
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update_at(3, 4, -2)
  input.close()
  let _ = worker.run()
  assert_eq(seen, [(6, 4L, -2L)])
  assert_true(probe.done())
  worker.dispose()
}

///|
test "panic data-dependent refinement cannot precede the lifted input capability" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let nested = scope.nested(0L, @differential.SummaryDomain::int64())
  let _ = nested.enter_at(source, fn(_, _) { -1L }).probe()
  input.insert(0)
  input.close()
  let _ = worker.run()
}
