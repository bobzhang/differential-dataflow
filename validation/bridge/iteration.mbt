///|
#export_name("evaluate_iteration")
pub fn evaluate_iteration(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let edges : Array[Array[Int32]] = Array::makei(6, fn(_) { [] })
  for _ in 0..<12 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 36U).reinterpret_as_int()
    edges[index / 6].push(index % 6)
  }
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let result = scope.iterate(source, fn(_, values) {
    values.concat(values.flat_map(fn(x) { edges[x].copy() })).distinct()
  })
  let observed : Map[Int32, Int64] = Map([])
  let probe = result
    .consolidate()
    .inspect(fn(d, _, r) { observed[d] = observed.get(d).unwrap_or(0) + r })
  let roots = Array::make(6, false)
  let results = []
  for epoch in 0L..<8L {
    for _ in 0..<2 {
      random = random * 1664525U + 1013904223U
      let key = ((random >> 8) % 6U).reinterpret_as_int()
      roots[key] = !roots[key]
      input.update(key, if roots[key] { 1L } else { -1L })
    }
    input.advance_to(epoch + 1)
    input.flush()
    guard worker.run(max_steps=10000) is Quiescent(_) &&
      !probe.less_than(epoch + 1) else {
      abort("iteration failed to converge")
    }
    let snapshot = observed.to_array().filter(fn(x) { x.1 != 0 })
    snapshot.sort()
    results.push(snapshot.map(fn(x) { "\{x.0},\{x.1}" }).join(";"))
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("iteration failed to close") }
  worker.dispose()
  results.join("/")
}
