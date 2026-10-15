///|
fn iteration(
  cluster : @differential.ClusterWorker,
  seed : Int32,
  deep~ : Bool = false,
) -> String raise {
  let mut random = seed.reinterpret_as_uint()
  let edges : Array[Array[Int32]] = Array::makei(6, fn(_) { [] })
  for _ in 0..<12 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 36U).reinterpret_as_int()
    edges[index / 6].push(index % 6)
  }
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
  let result = scope.iterate(source, fn(child, values) {
    let expanded = if deep {
      child.iterate(values, fn(grandchild, inner) {
        grandchild
        .exchange(
          inner.concat(inner.flat_map(fn(x) { edges[x].copy() })),
          fn(key) { key.to_uint64() },
          data_codec=@differential.WireCodec::json(),
          time_codec=@differential.WireCodec::product(
            @differential.WireCodec::product(
              @differential.WireCodec::json(),
              @differential.WireCodec::json(),
            ),
            @differential.WireCodec::json(),
          ),
          diff_codec=@differential.WireCodec::json(),
        )
        .distinct()
      })
    } else {
      values.concat(values.flat_map(fn(x) { edges[x].copy() }))
    }
    child
    .exchange(
      expanded,
      fn(key) { key.to_uint64() },
      data_codec=@differential.WireCodec::json(),
      time_codec=@differential.WireCodec::product(
        @differential.WireCodec::json(),
        @differential.WireCodec::json(),
      ),
      diff_codec=@differential.WireCodec::json(),
    )
    .distinct()
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
      if key % cluster.peers() == cluster.index() {
        input.update(key, if roots[key] { 1L } else { -1L })
      }
    }
    input.advance_to(epoch + 1)
    input.flush()
    guard drive(cluster, max_rounds=10000) is Quiescent(_) &&
      !probe.less_than(epoch + 1) else {
      abort("iteration failed to converge")
    }
    let snapshot = observed.to_array().filter(fn(x) { x.1 != 0 })
    snapshot.sort()
    results.push(snapshot.map(fn(x) { "\{x.0},\{x.1}" }).join(";"))
  }
  input.close()
  let _ = drive(cluster)
  guard probe.done() else { abort("iteration failed to close") }
  results.join("/")
}
