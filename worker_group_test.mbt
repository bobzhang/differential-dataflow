///|
test "exchange routes keys and waits for every peer's input progress" {
  let group = @differential.WorkerGroup(3)
  let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
  let sources : Array[
    (
      @differential.InputSession[Int32, Int64, Int64],
      @differential.Collection[Int32, Int64, Int64],
    ),
  ] = scopes.input()
  let exchanged = scopes.exchange(sources.map(fn(source) { source.1 }), fn(
    key,
  ) {
    key.to_uint64()
  })
  let seen : Array[Array[(Int32, Int64, Int64)]] = Array::makei(3, fn(_) { [] })
  let probes = Array::makei(3, fn(peer) {
    exchanged[peer]
    .consolidate()
    .inspect(fn(d, t, r) { seen[peer].push((d, t, r)) })
  })
  sources[0].0.insert(5)
  sources[0].0.advance_to(1)
  sources[0].0.flush()
  let _ = group.run()
  for probe in probes {
    assert_eq(probe.frontier().to_array(), [0L])
  }
  for peer in 1..<3 {
    sources[peer].0.advance_to(1)
    sources[peer].0.flush()
  }
  guard group.run() is Quiescent(_) else { fail("exchange stalled") }
  assert_eq(seen[2], [(5, 0L, 1L)])
  assert_true(seen[0].is_empty() && seen[1].is_empty())
  for probe in probes {
    assert_eq(probe.frontier().to_array(), [1L])
  }
  for source in sources {
    source.0.close()
  }
  let _ = group.run()
  for probe in probes {
    assert_true(probe.done())
  }
  group.dispose()
}

///|
test "partitioned joins combine records that originated on different workers" {
  let group = @differential.WorkerGroup(2)
  let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
  let left : Array[
    (
      @differential.InputSession[(Int32, Int32), Int64, Int64],
      @differential.Collection[(Int32, Int32), Int64, Int64],
    ),
  ] = scopes.input()
  let right : Array[
    (
      @differential.InputSession[(Int32, Int32), Int64, Int64],
      @differential.Collection[(Int32, Int32), Int64, Int64],
    ),
  ] = scopes.input()
  let a = scopes.exchange(left.map(fn(x) { x.1 }), fn(x) { x.0.to_uint64() })
  let b = scopes.exchange(right.map(fn(x) { x.1 }), fn(x) { x.0.to_uint64() })
  let results = []
  let probes = Array::makei(2, fn(peer) {
    a[peer]
    .join(b[peer])
    .consolidate()
    .inspect(fn(d, t, r) { results.push((d, t, r)) })
  })
  left[0].0.update((7, 3), 2)
  right[1].0.update((7, 4), 3)
  for source in left + right {
    source.0.advance_to(1)
    source.0.flush()
  }
  guard group.run() is Quiescent(_) else { fail("partitioned join stalled") }
  assert_eq(results, [((7, (3, 4)), 0L, 6L)])
  right[0].0.update((7, 4), -1)
  for source in left + right {
    source.0.close()
  }
  let _ = group.run()
  assert_eq(results, [((7, (3, 4)), 0L, 6L), ((7, (3, 4)), 1L, -2L)])
  for probe in probes {
    assert_true(probe.done())
  }
  group.dispose()
}

///|
test "panic a callback cannot step a different peer in the same group" {
  let group = @differential.WorkerGroup(2)
  let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
  let sources : Array[
    (
      @differential.InputSession[Int32, Int64, Int64],
      @differential.Collection[Int32, Int64, Int64],
    ),
  ] = scopes.input()
  for peer in 0..<2 {
    let _ = sources[peer].1.inspect(fn(_, _, _) {
      let _ = group.worker((peer + 1) % 2).step()
    })
  }
  sources[0].0.insert(1)
  sources[0].0.close()
  sources[1].0.close()
  let _ = group.run()
}

///|
test "nested fixed point exchanges updates across peer boundaries" {
  let group = @differential.WorkerGroup(2)
  let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
  let inputs : Array[
    (
      @differential.InputSession[Int32, Int64, Int64],
      @differential.Collection[Int32, Int64, Int64],
    ),
  ] = scopes.input()
  let sources = scopes.exchange(inputs.map(fn(input) { input.1 }), fn(key) {
    key.to_uint64()
  })
  let result = scopes.iterate(sources, fn(child, values) {
    let neighbors = values.map(fn(stream) {
      stream.flat_map(fn(x) { if x < 5 { [x + 1] } else { [] } })
    })
    let exchanged = child.exchange(neighbors, fn(key) { key.to_uint64() })
    Array::makei(2, fn(index) {
      values[index].concat(exchanged[index]).distinct()
    })
  })
  let counts : Map[Int32, Int64] = Map([])
  let probes = result.map(fn(stream) {
    stream.inspect(fn(d, _, r) { counts[d] = counts.get(d).unwrap_or(0) + r })
  })
  inputs[1].0.insert(0)
  for input in inputs {
    input.0.advance_to(1)
    input.0.flush()
  }
  guard group.run(max_steps=10000) is Quiescent(_) else {
    fail("peer fixed point stalled")
  }
  for node in 0..<6 {
    assert_eq(counts.get(node), Some(1L))
  }
  for probe in probes {
    assert_true(!probe.less_than(1))
  }
  inputs[0].0.remove(0)
  inputs[1].0.insert(3)
  for input in inputs {
    input.0.close()
  }
  guard group.run(max_steps=10000) is Quiescent(_) else {
    fail("peer fixed point retraction stalled")
  }
  for node in 0..<3 {
    assert_eq(counts.get(node), Some(0L))
  }
  for node in 3..<6 {
    assert_eq(counts.get(node), Some(1L))
  }
  for probe in probes {
    assert_true(probe.done())
  }
  group.dispose()
}

///|
test "two nested fixed points exchange and retract across peer boundaries" {
  let group = @differential.WorkerGroup(2)
  let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
  let inputs : Array[
    (
      @differential.InputSession[Int32, Int64, Int64],
      @differential.Collection[Int32, Int64, Int64],
    ),
  ] = scopes.input()
  let sources = scopes.exchange(inputs.map(fn(input) { input.1 }), fn(key) {
    key.to_uint64()
  })
  let result = scopes.iterate(sources, fn(child, values) {
    child.iterate(values, fn(grandchild, values) {
      let neighbors = values.map(fn(stream) {
        stream.flat_map(fn(x) { if x < 5 { [x + 1] } else { [] } })
      })
      let exchanged = grandchild.exchange(neighbors, fn(key) { key.to_uint64() })
      Array::makei(2, fn(index) {
        values[index].concat(exchanged[index]).distinct()
      })
    })
  })
  let counts : Map[Int32, Int64] = Map([])
  let probes = result.map(fn(stream) {
    stream.inspect(fn(d, _, r) { counts[d] = counts.get(d).unwrap_or(0) + r })
  })
  inputs[1].0.insert(0)
  for input in inputs {
    input.0.advance_to(1)
    input.0.flush()
  }
  guard group.run(max_steps=10000) is Quiescent(_) else {
    fail("peer fixed point stalled")
  }
  for node in 0..<6 {
    assert_eq(counts.get(node), Some(1L))
  }
  for probe in probes {
    assert_true(!probe.less_than(1))
  }
  inputs[0].0.remove(0)
  inputs[1].0.insert(3)
  for input in inputs {
    input.0.close()
  }
  guard group.run(max_steps=10000) is Quiescent(_) else {
    fail("peer fixed point retraction stalled")
  }
  for node in 0..<3 {
    assert_eq(counts.get(node), Some(0L))
  }
  for node in 3..<6 {
    assert_eq(counts.get(node), Some(1L))
  }
  for probe in probes {
    assert_true(probe.done())
  }
  group.dispose()
}
