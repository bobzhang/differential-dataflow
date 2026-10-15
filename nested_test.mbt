///|
test "nested feedback completes before the parent frontier passes its epoch" {
  let worker = @differential.Worker()
  let outer = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = outer.input()
  let nested = outer.nested(0L, @differential.SummaryDomain::int64())
  let child = nested.scope()
  let (feedback, looped) = child.feedback(Product(0L, 1L))
  let all = nested.enter(source).concat(looped)
  feedback.connect(
    all.map(fn(x) { x + 1 }).filter(fn(x) { x < 6 }).consolidate(),
  )
  let seen = []
  let probe = nested
    .leave(all)
    .consolidate()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  for epoch in 0L..<5L {
    input.insert(0)
    input.advance_to(epoch + 1)
    input.flush()
    guard worker.run(max_steps=2000) is Quiescent(_) else {
      fail("nested feedback stalled")
    }
    assert_true(!probe.less_than(epoch + 1))
    assert_eq(seen.filter(fn(x) { x.1 == epoch }).length(), 6)
  }
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "fixed-point iteration retracts and inserts reachability after source updates" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let result = scope.iterate(source, fn(_, values) {
    values
    .concat(values.flat_map(fn(x) { if x < 5 { [x + 1] } else { [] } }))
    .distinct()
  })
  let snapshot : Map[Int32, Int64] = Map([])
  let probe = result
    .consolidate()
    .inspect(fn(d, _, r) { snapshot[d] = snapshot.get(d).unwrap_or(0) + r })
  input.insert(2)
  input.advance_to(1)
  input.flush()
  guard worker.run(max_steps=5000) is Quiescent(_) else {
    fail("initial fixed point stalled")
  }
  assert_true(!probe.less_than(1))
  assert_eq(snapshot.to_array().filter(fn(x) { x.1 != 0 }).length(), 4)
  for i in 2..<6 {
    assert_eq(snapshot.get(i), Some(1L))
  }
  input.remove(2)
  input.insert(4)
  input.advance_to(2)
  input.flush()
  guard worker.run(max_steps=5000) is Quiescent(_) else {
    fail("updated fixed point stalled")
  }
  assert_true(!probe.less_than(2))
  assert_eq(snapshot.to_array().filter(fn(x) { x.1 != 0 }).length(), 2)
  assert_eq(snapshot.get(4), Some(1L))
  assert_eq(snapshot.get(5), Some(1L))
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "nested fixed points release progress across enclosing feedback cycles" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let result = scope.iterate(source, fn(child, values) {
    child
    .iterate(values, fn(_, inner) {
      inner
      .concat(inner.flat_map(fn(x) { if x < 4 { [x + 1] } else { [] } }))
      .distinct()
    })
    .distinct()
  })
  let snapshot : Map[Int32, Int64] = Map([])
  let probe = result.inspect(fn(data, _, diff) {
    snapshot[data] = snapshot.get(data).unwrap_or(0L) + diff
  })
  for epoch in 0L..<128L {
    let inserting = epoch % 2 == 0
    input.update(0, if inserting { 1L } else { -1L })
    input.advance_to(epoch + 1)
    input.flush()
    assert_true(worker.run(max_steps=2000) is Quiescent(_))
    assert_true(!probe.less_than(epoch + 1))
    for data in 0..<5 {
      assert_eq(
        snapshot.get(data).unwrap_or(0L),
        if inserting {
          1L
        } else {
          0L
        },
      )
    }
  }
  input.close()
  assert_true(worker.run(max_steps=2000) is Quiescent(_))
  assert_true(probe.done())
  worker.dispose()
}
