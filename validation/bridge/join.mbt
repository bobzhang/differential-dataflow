///|
#export_name("evaluate_join")
pub fn evaluate_join(seed : Int32) -> String {
  join_case(seed, false, false)
}

///|
#export_name("evaluate_scope_join")
pub fn evaluate_scope_join(seed : Int32) -> String {
  join_case(seed, true, false)
}

///|
fn join_case(
  seed : Int32,
  counted : Bool,
  arranged : Bool,
  entered~ : Bool = false,
  assigned~ : Bool = false,
  fueled~ : Bool = false,
  columnar~ : Bool = false,
  spilled~ : Bool = false,
) -> String {
  let spill : @differential.SpillPolicy[(Int32, Int32), Int64, Int64]? = if spilled {
    Some(
      SpillPolicy(
        0L,
        store=BytesStore(fn(bytes) { BytesSource(fn() { bytes }) }),
        codec=@differential.WireCodec::json(),
        chunk_size=3,
      ),
    )
  } else {
    None
  }
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
  let joined = if arranged {
    let l = left.arrange_by_key(fueled~, columnar~, spill?)
    let r = right.arrange_by_key(fueled~, columnar~, spill?)
    let joined = if entered {
      let first = scope.nested(0L, @differential.SummaryDomain::int64())
      let second = first
        .scope()
        .nested(0L, @differential.SummaryDomain::int64())
      let l1 = if assigned {
        l.enter_at(first, fn(data, _) { data.1.to_int64() }, fn(time) {
          time.outer
        })
      } else {
        l.enter(first)
      }
      let r1 = r.enter(first)
      let l2 = l1.enter(second)
      let r2 = if assigned {
        r1.enter_at(second, fn(data, _) { data.1.to_int64() + 1 }, fn(time) {
          time.outer
        })
      } else {
        r1.enter(second)
      }
      let result = first.leave(second.leave(l2.join(r2)))
      l1.release()
      r1.release()
      l2.release()
      r2.release()
      result
    } else {
      l.join(r)
    }
    l.release()
    r.release()
    joined
  } else {
    left.join(right)
  }
  let probe = joined
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
#export_name("evaluate_arranged_join")
pub fn evaluate_arranged_join(seed : Int32) -> String {
  join_case(seed, true, true)
}

///|
#export_name("evaluate_entered_join")
pub fn evaluate_entered_join(seed : Int32) -> String {
  join_case(seed, true, true, entered=true)
}

///|
#export_name("evaluate_assigned_join")
pub fn evaluate_assigned_join(seed : Int32) -> String {
  join_case(seed, true, true, entered=true, assigned=true)
}

///|
#export_name("evaluate_fueled_join")
pub fn evaluate_fueled_join(seed : Int32) -> String {
  join_case(seed, true, true, entered=true, assigned=true, fueled=true)
}

///|
#export_name("evaluate_columnar_join")
pub fn evaluate_columnar_join(seed : Int32) -> String {
  join_case(
    seed,
    true,
    true,
    entered=true,
    assigned=true,
    fueled=true,
    columnar=true,
  )
}

///|
#export_name("evaluate_spilled_join")
pub fn evaluate_spilled_join(seed : Int32) -> String {
  join_case(
    seed,
    true,
    true,
    entered=true,
    assigned=true,
    fueled=true,
    columnar=true,
    spilled=true,
  )
}
