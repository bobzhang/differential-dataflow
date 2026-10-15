///|
test "new scopes import a running trace and coexist with old input" {
  let worker = @differential.Worker()
  let first = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = first.input()
  let index = values.arrange_by_key(fueled=true, columnar=true)
  input.insert((1, 7))
  input.advance_to(1L)
  input.flush()
  let _ = worker.run()
  let second = worker.scope(0L, @differential.SummaryDomain::int64())
  let trace = index.trace()
  let seen = []
  let probe = trace
    .import_into(second)
    .inspect(fn(data, time, diff) { seen.push((data, time, diff)) })
  trace.release()
  index.release()
  let _ = worker.run()
  assert_eq(seen, [((1, 7), 0L, 1L)])
  assert_false(probe.less_than(1L))
  input.remove((1, 7))
  input.insert((2, 9))
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(seen, [((1, 7), 0L, 1L), ((1, 7), 1L, -1L), ((2, 9), 1L, 1L)])
  worker.dispose()
}

///|
test "new coordinated scopes can exchange after previous scopes complete" {
  let group = @differential.WorkerGroup(3)
  for epoch in 0..<8 {
    let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
    let sources : Array[
      (
        @differential.InputSession[Int32, Int64, Int64],
        @differential.Collection[Int32, Int64, Int64],
      ),
    ] = scopes.input()
    let exchanged = scopes.exchange(sources.map(fn(s) { s.1 }), fn(key) {
      key.to_uint64()
    })
    let seen : Array[Array[Int32]] = Array::makei(3, fn(_) { [] })
    let probes = Array::makei(3, fn(peer) {
      exchanged[peer].inspect(fn(key, _, _) { seen[peer].push(key) })
    })
    sources[0].0.insert(epoch)
    for (input, _) in sources {
      input.close()
    }
    let _ = group.run()
    assert_eq(seen[epoch % 3], [epoch])
    assert_true(probes.iter().all(fn(probe) { probe.done() }))
  }
  group.dispose()
}

///|
test "panic existing counted scope is frozen after input flush" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  input.insert(1)
  input.flush()
  let _ = values.map(fn(x) { x })
}

///|
test "panic existing scope cannot gain a nested scope after execution" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let _ = worker.run()
  let _ = scope.nested(0L, @differential.SummaryDomain::int64())
}

///|
test "panic replay progress freezes the scope before worker execution" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, _) : (
    @differential.ReplayInput[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.replay()
  input.push(Progress(CaptureProgress(Antichain([0L]), Antichain([1L]), [])))
  let _ = scope.operator()
}
