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

///|
#export_name("evaluate_arrangement")
pub fn evaluate_arrangement(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = values.arrange_by_key()
  let fast = arranged.trace()
  let slow = arranged.trace()
  arranged.release()
  let probe = arranged.as_collection().probe()
  let mut random = seed.reinterpret_as_uint()
  let result = []
  for epoch in 0L..<16L {
    for _ in 0..<6 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 12U).reinterpret_as_int()
      input.update((index / 4, index % 4), (random % 5U).to_int64() - 2)
    }
    input.advance_to(epoch + 1)
    input.flush()
    guard worker.run() is Quiescent(_) && !probe.less_than(epoch + 1) else {
      abort("arrangement progress stalled")
    }
    let past = epoch / 4 * 4
    fast.set_logical_compaction(Antichain([epoch]))
    fast.set_physical_compaction(Antichain([epoch + 1]))
    slow.set_logical_compaction(Antichain([past]))
    slow.set_physical_compaction(Antichain([past]))
    result.push(
      [past, epoch]
      .map(fn(query) {
        slow.snapshot(query).map(fn(x) { "\{x.0.0},\{x.0.1},\{x.1}" }).join(";")
      })
      .join("|"),
    )
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("arrangement failed to close") }
  fast.release()
  slow.release()
  worker.dispose()
  result.join("/")
}

///|
#export_name("evaluate_upsert")
pub fn evaluate_upsert(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, updates) : (
    @differential.InputSession[(Int32, Int32?), Int64, @differential.Present],
    @differential.Collection[(Int32, Int32?), Int64, @differential.Present],
  ) = scope.input()
  let arranged = updates.arrange_from_upsert()
  arranged.release()
  let observed = []
  let probe = arranged
    .as_collection()
    .inspect(fn(d, t, r) { observed.push((d, t, r)) })
  let mut random = seed.reinterpret_as_uint()
  for _ in 0..<64 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 256U).reinterpret_as_int()
    input.update_at(
      (index / 64, if random % 4U == 0U { None } else { Some(index % 8) }),
      (index / 8 % 8).to_int64(),
      Present,
    )
  }
  input.close()
  guard worker.run() is Quiescent(_) && probe.done() else {
    abort("upsert progress stalled")
  }
  worker.dispose()
  @differential.consolidate_updates(observed)
  .map(fn(u) { "\{u.0.0},\{u.0.1},\{u.1},\{u.2}" })
  .join(";")
}

///|
#export_name("evaluate_replay")
pub fn evaluate_replay(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let messages : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  for epoch in 0L..<8L {
    random = random * 1664525U + 1013904223U
    let data = ((random >> 8) % 11U).reinterpret_as_int()
    let diff = (random % 3U + 1U).to_int64()
    messages.push(Updates([(data, epoch, diff), (data + 20, epoch, -diff)]))
    messages.push(
      Progress(
        CaptureProgress(Antichain([epoch]), Antichain([epoch + 1]), [
          (epoch, 2L),
        ]),
      ),
    )
  }
  messages.push(Progress(CaptureProgress(Antichain([8L]), Antichain([]), [])))
  let delivery = messages + messages
  for index in 1..<delivery.length() {
    random = random * 1664525U + 1013904223U
    let other = (random % (index + 1).reinterpret_as_uint()).reinterpret_as_int()
    let temporary = delivery[index]
    delivery[index] = delivery[other]
    delivery[other] = temporary
  }
  let replayer : @differential.Replayer[Int32, Int64, Int64] = Replayer(0)
  let result = []
  for message in delivery {
    if replayer.push(message) is Some((updates, frontier)) {
      let data = updates.map(fn(u) { "\{u.0},\{u.1},\{u.2}" }).join(";")
      let times = frontier.to_array().map(fn(t) { "\{t}" }).join(",")
      result.push("\{data}|\{times}")
    }
  }
  result.join("/")
}
