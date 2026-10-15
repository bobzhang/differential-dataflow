///|
test "counted scope tracks data in flight and buffered consolidation" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let seen = []
  let probe = values
    .map(fn(x) { x + 1 })
    .consolidate()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.insert(3)
  input.insert(3)
  input.advance_to(1)
  input.flush()
  assert_true(!probe.done())
  guard worker.run() is Quiescent(_) else { fail("scope stalled") }
  assert_eq(seen, [(4, 0L, 2L)])
  assert_eq(probe.frontier().to_array(), [1L])
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "counted feedback terminates after input closes with work still in flight" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (feedback, looped) = scope.feedback(1L)
  let all = values.concat(looped)
  feedback.connect(
    all.map(fn(x) { x + 1 }).filter(fn(x) { x < 8 }).consolidate(),
  )
  let seen = []
  let probe = all.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.insert(0)
  input.close()
  guard worker.run(max_steps=1000) is Quiescent(_) else {
    fail("feedback failed to terminate")
  }
  assert_eq(seen, Array::makei(8, fn(i) { (i, i.to_int64(), 1L) }))
  assert_true(probe.done())
  worker.dispose()
}

///|
test "scope reductions preserve synthetic future corrections" {
  let worker = @differential.Worker()
  let domain = @differential.SummaryDomain::product(
    @differential.SummaryDomain::int64(),
    @differential.SummaryDomain::int64(),
  )
  let scope = worker.scope(@differential.Product(0L, 0L), domain)
  let (input, values) : (
    @differential.InputSession[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = scope.input()
  let seen = []
  let probe = values.distinct().inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update_at(7, Product(0, 1), 1)
  input.update_at(7, Product(1, 0), 1)
  input.close()
  guard worker.run() is Quiescent(_) else { fail("reduction stalled") }
  let actual = @differential.consolidate_updates(seen)
  assert_eq(actual, [
    (7, Product(0, 1), 1L),
    (7, Product(1, 0), 1L),
    (7, Product(1, 1), -1L),
  ])
  assert_true(probe.done())
  worker.dispose()
}

///|
test "binary output starts at the union of unequal input frontiers" {
  let worker = @differential.Worker()
  let (a, left) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(5)
  let (b, right) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let seen = []
  let probe = left.concat(right).inspect(fn(d, t, r) { seen.push((d, t, r)) })
  b.insert(1)
  a.close()
  b.close()
  let _ = worker.run()
  assert_eq(seen, [(1, 0L, 1L)])
  assert_true(probe.done())
  worker.dispose()
}

///|
test "zero step budget accounts for pending progress notifications" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let probe = values.probe()
  input.close()
  assert_eq(worker.run(max_steps=0), StepLimit(0))
  assert_true(!probe.done())
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(worker.run(max_steps=0), Quiescent(0))
  worker.dispose()
}

///|
test "negative summary edges compose into an advancing feedback cycle" {
  let worker = @differential.Worker()
  let scope = worker.scope(-100L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (backward, lowered) = scope.feedback(-3L)
  let (forward, looped) = scope.feedback(4L)
  let all = source.concat(looped)
  backward.connect(
    all.map(fn(value) { value + 1 }).filter(fn(value) { value < 4 }),
  )
  forward.connect(lowered)
  let observed = []
  let probe = all.inspect(fn(data, time, diff) {
    observed.push((data, time, diff))
  })
  input.advance_to(10)
  input.insert(0)
  input.advance_to(20)
  input.flush()
  assert_true(worker.run(max_steps=1000) is Quiescent(_))
  assert_true(!probe.less_than(20))
  observed.sort()
  assert_eq(observed, [(0, 10L, 1L), (1, 11L, 1L), (2, 12L, 1L), (3, 13L, 1L)])
  input.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  worker.dispose()
}
