///|
#export_name("evaluate_join")
pub fn evaluate_join(seed : Int32) -> String {
  join_case(seed, false)
}

///|
#export_name("evaluate_scope_join")
pub fn evaluate_scope_join(seed : Int32) -> String {
  join_case(seed, true)
}

///|
fn join_case(seed : Int32, counted : Bool) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (a, left) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = if counted { scope.input() } else { worker.input(0) }
  let (b, right) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = if counted { scope.input() } else { worker.input(0) }
  let observed : Map[(Int32, Int32, Int32), Int64] = Map([])
  let probe = left
    .join(right)
    .consolidate()
    .inspect(fn(d, _, diff) {
      let key = (d.0, d.1.0, d.1.1)
      observed[key] = observed.get(key).unwrap_or(0) + diff
    })
  let mut random = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0L..<16L {
    for side in 0..<2 {
      for _ in 0..<4 {
        random = random * 1664525U + 1013904223U
        let index = ((random >> 8) % 20U).reinterpret_as_int()
        let diff = (random % 5U).to_int64() - 2L
        let data = (index / 5, index % 5)
        if side == 0 {
          a.update(data, diff)
        } else {
          b.update(data, diff)
        }
      }
    }
    a.advance_to(epoch + 1)
    b.advance_to(epoch + 1)
    a.flush()
    b.flush()
    guard worker.run() is Quiescent(_) else {
      abort("worker exceeded step bound")
    }
    guard !probe.less_than(epoch + 1) else { abort("progress stalled") }
    let current = observed.to_array().filter(fn(x) { x.1 != 0L })
    current.sort()
    results.push(
      current.map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1}" }).join(";"),
    )
  }
  a.close()
  b.close()
  let _ = worker.run()
  guard probe.done() else { abort("input close did not complete") }
  worker.dispose()
  results.join("/")
}
