///|
#export_name("evaluate")
pub fn evaluate(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let frontier : @differential.MutableAntichain[
    @differential.Product[Int64, Int64],
  ] = MutableAntichain()
  let result = []
  for _ in 0..<40 {
    let updates = []
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 25U).to_int64()
      let delta = if random % 3U == 0U { -1L } else { 1L }
      updates.push((@differential.Product(index / 5, index % 5), delta))
    }
    let changes = frontier
      .update_all(updates)
      .map(fn(u) { "\{u.0.outer},\{u.0.inner},\{u.1}" })
      .join(";")
    let minimal = frontier
      .frontier()
      .to_array()
      .map(fn(t) { "\{t.outer},\{t.inner}" })
      .join(";")
    let time = @differential.advance_by(
      @differential.Product((seed % 5).to_int64(), (seed / 5 % 5).to_int64()),
      frontier.frontier(),
    )
    result.push("\{changes}|\{minimal}|\{time.outer},\{time.inner}")
  }
  result.join("/")
}

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

///|
#export_name("evaluate_reduce")
pub fn evaluate_reduce(seed : Int32) -> String {
  reduce_case(seed, false)
}

///|
#export_name("evaluate_scope_reduce")
pub fn evaluate_scope_reduce(seed : Int32) -> String {
  reduce_case(seed, true)
}

///|
fn reduce_case(seed : Int32, counted : Bool) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(
    @differential.Product(0L, 0L),
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let (input, collection) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = if counted { scope.input() } else { worker.input(Product(0, 0)) }
  let observed : Array[
    ((Int32, Int32, Int64), @differential.Product[Int64, Int64], Int64),
  ] = []
  let p0 = collection
    .map(fn(x) { x.0 })
    .distinct()
    .inspect(fn(k, t, d) { observed.push(((0, k, 0L), t, d)) })
  let p1 = collection
    .map(fn(x) { x.0 })
    .count()
    .inspect(fn(x, t, d) { observed.push(((1, x.0, x.1), t, d)) })
  let p2 = collection
    .reduce(fn(_, values) { [(values[0].0, 1L)] })
    .inspect(fn(x, t, d) { observed.push(((2, x.0, x.1.to_int64()), t, d)) })
  let mut random = seed.reinterpret_as_uint()
  for _ in 0..<32 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 375U).reinterpret_as_int()
    input.update_at(
      (index / 125, index % 5),
      Product((index / 25 % 5).to_int64(), (index / 5 % 5).to_int64()),
      (random % 5U).to_int64() - 2L,
    )
  }
  input.close()
  guard worker.run() is Quiescent(_) && p0.done() && p1.done() && p2.done() else {
    abort("reduction progress stalled")
  }
  worker.dispose()
  @differential.consolidate_updates(observed)
  .map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1.outer},\{x.1.inner},\{x.2}" })
  .join(";")
}

///|
#export_name("evaluate_feedback")
pub fn evaluate_feedback(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (feedback, looped) = scope.feedback((seed % 3 + 1).to_int64())
  let all = values.concat(looped)
  feedback.connect(
    all.map(fn(x) { x + 1 }).filter(fn(x) { x < 12 }).consolidate(),
  )
  let observed : Array[(Int32, Int64, Int64)] = []
  let probe = all
    .consolidate()
    .inspect(fn(d, t, r) { observed.push((d, t, r)) })
  let mut random = seed.reinterpret_as_uint()
  let result = []
  for epoch in 0L..<4L {
    for _ in 0..<8 {
      random = random * 1664525U + 1013904223U
      input.update(
        ((random >> 8) % 8U).reinterpret_as_int(),
        (random % 5U).to_int64() - 2,
      )
    }
    input.advance_to((epoch + 1) * 64)
    input.flush()
    guard worker.run(max_steps=10000) is Quiescent(_) &&
      !probe.less_than(input.time()) else {
      abort("feedback progress stalled")
    }
    result.push(
      @differential.consolidate_updates(observed)
      .map(fn(u) { "\{u.0},\{u.1},\{u.2}" })
      .join(";"),
    )
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("feedback failed to close") }
  worker.dispose()
  result.join("/")
}
