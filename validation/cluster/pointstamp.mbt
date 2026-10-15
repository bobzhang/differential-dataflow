///|
fn pointstamp_iteration(
  cluster : @differential.ClusterWorker,
  seed : Int32,
) -> String raise {
  let scope = cluster.scope(
    0UL,
    @differential.SummaryDomain::uint64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let (input, source) : (
    @differential.InputSession[Int32, UInt64, Int64],
    @differential.Collection[Int32, UInt64, Int64],
  ) = scope.input()
  let nested = scope.nested(
    @differential.PointStamp([]),
    @differential.SummaryDomain::pointstamp(
      @differential.SummaryDomain::uint64(),
    ),
    time_codec=@differential.WireCodec::pointstamp(
      @differential.WireCodec::json(),
    ),
    summary_codec=@differential.WireCodec::pointstamp_summary(
      @differential.WireCodec::json(),
    ),
  )
  let inner = nested.scope()
  let level = seed % 4 + 1
  let (variable, ranks) = inner
    .scope()
    .variable_from(
      nested.enter(source).enter_dynamic(level),
      Product(
        0UL,
        @differential.SummaryDomain::uint64().feedback_summary(level, 1UL),
      ),
    )
  let result = ranks.flat_map(fn(d) { if d < 11 { [d, d + 1] } else { [d] } })
  let result = inner
    .exchange(
      result,
      fn(key) { key.to_uint64() },
      data_codec=@differential.WireCodec::json(),
      time_codec=@differential.WireCodec::product(
        @differential.WireCodec::json(),
        @differential.WireCodec::pointstamp(@differential.WireCodec::json()),
      ),
      diff_codec=@differential.WireCodec::json(),
    )
    .distinct()
  variable.set(result)
  let observed : Map[Int32, Int64] = Map([])
  let probe = nested
    .leave(inner.scope().leave_dynamic(result, level))
    .inspect(fn(d, _, r) { observed[d] = observed.get(d).unwrap_or(0L) + r })
  let roots : Set[Int32] = Set([])
  let mut state = seed.reinterpret_as_uint()
  let rows = []
  for epoch in 0UL..<8UL {
    for _ in 0..<3 {
      state = state * 1664525U + 1013904223U
      let d = ((state >> 8) % 12U).reinterpret_as_int()
      if roots.contains(d) {
        roots.remove(d)
        if d % cluster.peers() == cluster.index() {
          input.remove(d)
        }
      } else {
        roots.add(d)
        if d % cluster.peers() == cluster.index() {
          input.insert(d)
        }
      }
    }
    input.advance_to(epoch + 1UL)
    input.flush()
    let _ = drive(cluster)
    guard !probe.less_than(epoch + 1UL) else {
      abort("dynamic scope iteration stalled")
    }
    let records = observed.to_array().filter(fn(row) { row.1 != 0L })
    records.sort()
    rows.push(records.map(fn(row) { "\{row.0},\{row.1}" }).join(";"))
  }
  input.close()
  let _ = drive(cluster)
  guard probe.done() else { abort("dynamic scope did not close") }
  rows.join("/")
}
