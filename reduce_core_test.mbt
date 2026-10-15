///|
test "reduce_core sees empty input when retracting the last value" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let empty_calls = Ref(0)
  let result = source.reduce_core(fn(
    _,
    values,
    previous : Array[(Int32, Int64)],
  ) {
    let changes = []
    if values.is_empty() {
      guard !previous.is_empty() else { abort("both snapshots are empty") }
      empty_calls.val += 1
    } else {
      changes.push((values[0].0, 1L))
    }
    for (value, diff) in previous {
      changes.push((value, -diff))
    }
    // The arrays are owned snapshots; mutation must not corrupt retained history.
    values.clear()
    previous.clear()
    changes
  })
  let seen = []
  let probe = result
    .as_collection()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  result.release()
  input.insert((1, 5))
  input.advance_to(1L)
  input.flush()
  let _ = worker.run()
  input.remove((1, 5))
  input.advance_to(2L)
  input.flush()
  let _ = worker.run()
  input.insert((1, 3))
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_true(empty_calls.val > 0)
  assert_eq(@differential.consolidate_updates(seen), [
    ((1, 3), 2L, 1L),
    ((1, 5), 0L, 1L),
    ((1, 5), 1L, -1L),
  ])
  worker.dispose()
}

///|
test "reduce_core can emit presence-only differences with no negation or zero" {
  let worker = @differential.Worker()
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = worker.input(0L)
  let index = source.arrange_by_key()
  let result = index.reduce_core(fn(
    _,
    values,
    previous : Array[(Int32, @differential.Present)],
  ) {
    values
    .filter(fn(x) { !previous.iter().any(fn(y) { x.0 == y.0 }) })
    .map(fn(x) { (x.0, Present) })
  })
  index.release()
  let seen = []
  let probe = result.as_collection().inspect(fn(d, t, _) { seen.push((d, t)) })
  result.release()
  input.insert((1, 5))
  input.advance_to(1L)
  input.flush()
  let _ = worker.run()
  input.insert((1, 5))
  input.insert((1, 7))
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(seen, [((1, 5), 0L), ((1, 7), 1L)])
  worker.dispose()
}
