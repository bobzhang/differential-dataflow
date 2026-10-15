///|
#export_name("evaluate_group_join")
pub fn evaluate_group_join(seed : Int32) -> String {
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
  let observed : Map[(Int32, Int32, Int32), Int64] = Map([])
  let probes = Array::makei(2, fn(peer) {
    a[peer]
    .join(b[peer])
    .consolidate()
    .inspect(fn(d, _, r) {
      let key = (d.0, d.1.0, d.1.1)
      observed[key] = observed.get(key).unwrap_or(0) + r
    })
  })
  let mut random = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0L..<16L {
    for side in 0..<2 {
      for _ in 0..<4 {
        random = random * 1664525U + 1013904223U
        let index = ((random >> 8) % 20U).reinterpret_as_int()
        let peer = ((random >> 16) % 2U).reinterpret_as_int()
        let diff = (random % 5U).to_int64() - 2
        if side == 0 {
          left[peer].0.update((index / 5, index % 5), diff)
        } else {
          right[peer].0.update((index / 5, index % 5), diff)
        }
      }
    }
    for source in left + right {
      source.0.advance_to(epoch + 1)
      source.0.flush()
    }
    guard group.run() is Quiescent(_) else {
      abort("peer join step bound exceeded")
    }
    for probe in probes {
      guard !probe.less_than(epoch + 1) else { abort("peer progress stalled") }
    }
    let current = observed.to_array().filter(fn(x) { x.1 != 0 })
    current.sort()
    results.push(
      current.map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1}" }).join(";"),
    )
  }
  for source in left + right {
    source.0.close()
  }
  let _ = group.run()
  for probe in probes {
    guard probe.done() else { abort("peer join failed to close") }
  }
  group.dispose()
  results.join("/")
}
