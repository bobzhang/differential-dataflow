///|
fn ps_next(state : Ref[UInt32]) -> UInt32 {
  state.val = state.val * 1664525U + 1013904223U
  state.val
}

///|
fn ps_vector(state : Ref[UInt32]) -> Array[UInt64] {
  let length = (ps_next(state) % 5U).reinterpret_as_int()
  Array::makei(length, fn(_) { ((ps_next(state) >> 8) % 7U).to_uint64() })
}

///|
fn ps_show(values : Array[UInt64]) -> String {
  "[" + values.map(fn(n) { n.to_string() }).join(",") + "]"
}

///|
#export_name("evaluate_pointstamp")
pub fn evaluate_pointstamp(seed : Int32) -> String {
  let state = Ref(seed.reinterpret_as_uint())
  let domain = @differential.SummaryDomain::pointstamp(
    @differential.SummaryDomain::uint64(),
  )
  let rows = []
  for case in 0..<32 {
    let a = @differential.PointStamp(ps_vector(state))
    let b = @differential.PointStamp(ps_vector(state))
    let retain = (ps_next(state) % 6U).reinterpret_as_int()
    let actions = ps_vector(state)
    if case % 8 == 0 {
      actions.push(18446744073709551615UL)
    }
    let s = @differential.PointStampSummary(
      actions,
      retain?=if retain == 0 { None } else { Some(retain - 1) },
    )
    let retain = (ps_next(state) % 6U).reinterpret_as_int()
    let t = @differential.PointStampSummary(
      ps_vector(state),
      retain?=if retain == 0 { None } else { Some(retain - 1) },
    )
    let output = match domain.results_in(s, a) {
      None => "N"
      Some(p) => ps_show(p.to_array())
    }
    let composed = match domain.followed_by(s, t) {
      None => "N"
      Some(s) =>
        (match s.retain() {
          None => "n"
          Some(n) => n.to_string()
        }) +
        ":" +
        ps_show(s.actions())
    }
    rows.push(
      "\{ps_show(a.to_array())}|\{ps_show(b.to_array())}|\{a.less_equal(b)}|\{a.compare(b)}|\{ps_show(a.join(b).to_array())}|\{ps_show(a.meet(b).to_array())}|\{output}|\{composed}",
    )
  }
  rows.join("/")
}

///|
#export_name("evaluate_dynamic_iteration")
pub fn evaluate_dynamic_iteration(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0UL, @differential.SummaryDomain::uint64())
  let (input, source) : (
    @differential.InputSession[Int32, UInt64, Int64],
    @differential.Collection[Int32, UInt64, Int64],
  ) = scope.input()
  let nested = scope.nested(
    @differential.PointStamp([]),
    @differential.SummaryDomain::pointstamp(
      @differential.SummaryDomain::uint64(),
    ),
  )
  let inner = nested.scope()
  let level = seed % 4 + 1
  let (variable, ranks) = inner.variable_from(
    nested.enter(source).enter_dynamic(level),
    Product(
      0UL,
      @differential.SummaryDomain::uint64().feedback_summary(level, 1UL),
    ),
  )
  let result = ranks
    .flat_map(fn(d) { if d < 11 { [d, d + 1] } else { [d] } })
    .distinct()
  variable.set(result)
  let observed : Map[Int32, Int64] = Map([])
  let probe = nested
    .leave(inner.leave_dynamic(result, level))
    .inspect(fn(d, _, r) { observed[d] = observed.get(d).unwrap_or(0L) + r })
  let roots : Set[Int32] = Set([])
  let state = Ref(seed.reinterpret_as_uint())
  let rows = []
  for epoch in 0UL..<8UL {
    for _ in 0..<3 {
      let d = ((ps_next(state) >> 8) % 12U).reinterpret_as_int()
      if roots.contains(d) {
        roots.remove(d)
        input.remove(d)
      } else {
        roots.add(d)
        input.insert(d)
      }
    }
    input.advance_to(epoch + 1UL)
    input.flush()
    let _ = worker.run()
    guard !probe.less_than(epoch + 1UL) else {
      abort("dynamic scope iteration stalled")
    }
    let records = observed.to_array().filter(fn(row) { row.1 != 0L })
    records.sort()
    rows.push(records.map(fn(row) { "\{row.0},\{row.1}" }).join(";"))
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("dynamic scope did not close") }
  worker.dispose()
  rows.join("/")
}
