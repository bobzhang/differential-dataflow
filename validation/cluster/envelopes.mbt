///|
fn envelopes(
  cluster : @differential.ClusterWorker,
  seed : Int32,
) -> String raise {
  let scope = cluster.scope(
    0L,
    @differential.SummaryDomain::int64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let seen : Map[(Int64, Int32, Int64), Int64] = Map([])
  let probe = scope
    .exchange(
      source.results_in(3L, @differential.SummaryDomain::int64()),
      fn(d) { d.to_uint64() },
      data_codec=@differential.WireCodec::json(),
      time_codec=@differential.WireCodec::json(),
      diff_codec=@differential.WireCodec::json(),
    )
    .delay(fn(t) { t + 2L })
    .inspect_batch(fn(envelope, rows) {
      for (d, t, r) in rows {
        let key = (envelope, d, t)
        seen[key] = seen.get(key).unwrap_or(0L) + r
      }
    })
    .probe()
  let snapshot = fn() {
    let rows = seen.to_array().filter(fn(row) { row.1 != 0L })
    rows.sort()
    rows.map(fn(row) { "\{row.0.0},\{row.0.1},\{row.0.2},\{row.1}" }).join(";")
  }
  let mut state = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0L..<12L {
    for _ in 0..<6 {
      state = state * 1664525U + 1013904223U
      let d = ((state >> 8) % 8U).reinterpret_as_int()
      if ((state >> 16) % cluster.peers().reinterpret_as_uint()).reinterpret_as_int() ==
        cluster.index() {
        input.update_at(
          d,
          epoch + 10L + (d % 3).to_int64(),
          (state % 5U).to_int64() - 2L,
        )
      }
    }
    input.advance_to(epoch + 1L)
    input.flush()
    guard drive(cluster) is Quiescent(_) && !probe.less_than(epoch + 1L) else {
      abort("distributed delayed message stalled")
    }
    results.push(snapshot())
  }
  input.close()
  let _ = drive(cluster)
  guard probe.done() else { abort("distributed delayed message did not close") }
  results.push(snapshot())
  results.join("/")
}
