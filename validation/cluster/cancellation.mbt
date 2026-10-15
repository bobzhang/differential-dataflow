///|
fn cancellation(
  cluster : @differential.ClusterWorker,
  seed : Int32,
) -> String raise {
  let live = cluster.scope(
    0L,
    @differential.SummaryDomain::int64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let (input, data) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = live.input()
  let observed : Map[Int32, Int64] = Map([])
  let probe = live
    .exchange(
      data,
      fn(d) { d.to_uint64() },
      data_codec=@differential.WireCodec::json(),
      time_codec=@differential.WireCodec::json(),
      diff_codec=@differential.WireCodec::json(),
    )
    .inspect(fn(d, _, r) { observed[d] = observed.get(d).unwrap_or(0L) + r })
  let results = []
  for epoch in 0..<16 {
    let doomed = cluster.scope(
      0L,
      @differential.SummaryDomain::int64(),
      time_codec=@differential.WireCodec::json(),
      summary_codec=@differential.WireCodec::json(),
    )
    let (pending, data) : (
      @differential.InputSession[Int32, Int64, Int64],
      @differential.Collection[Int32, Int64, Int64],
    ) = doomed.input()
    let nested = doomed.nested(
      0L,
      @differential.SummaryDomain::int64(),
      time_codec=@differential.WireCodec::json(),
      summary_codec=@differential.WireCodec::json(),
    )
    let incoming = nested.enter(data)
    let routed = nested
      .scope()
      .exchange(
        incoming,
        fn(d) { d.to_uint64() },
        data_codec=@differential.WireCodec::json(),
        time_codec=@differential.WireCodec::product(
          @differential.WireCodec::json(),
          @differential.WireCodec::json(),
        ),
        diff_codec=@differential.WireCodec::json(),
      )
    let cancelled = nested
      .leave(routed)
      .inspect(fn(_, _, _) { abort("cancelled record escaped") })
    pending.insert(seed % 1000 + epoch + cluster.index())
    pending.flush()
    // Only one peer requests cancellation; every peer must observe the decision.
    if cluster.index() == epoch % cluster.peers() {
      cluster.drop_dataflow(doomed.dataflow_index())
    }
    input.insert(seed % 1000 + epoch)
    input.advance_to(epoch.to_int64() + 1L)
    input.flush()
    let _ = drive(cluster)
    guard !probe.less_than(epoch.to_int64() + 1L) &&
      !cancelled.done() &&
      cluster.installed_dataflows() == [live.dataflow_index()] else {
      abort("collective cancellation or sibling progress failed")
    }
    pending.close()
    let rows = observed.to_array()
    rows.sort()
    results.push(rows.map(fn(row) { "\{row.0},\{row.1}" }).join(";"))
  }
  input.close()
  let _ = drive(cluster)
  guard probe.done() && cluster.installed_dataflows().is_empty() else {
    abort("cancellation fixture did not finish")
  }
  results.join("/")
}
