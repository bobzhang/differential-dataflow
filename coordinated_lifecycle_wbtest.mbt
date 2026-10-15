///|
test "group scopes reclaim shared progress only after every peer finishes" {
  let group = WorkerGroup(3)
  for _ in 0..<24 {
    let scopes = group.scopes(0L, SummaryDomain::int64())
    let sources : Array[
      (InputSession[Int32, Int64, Int64], Collection[Int32, Int64, Int64]),
    ] = scopes.input()
    let streams = scopes.exchange(sources.map(fn(source) { source.1 }), fn(d) {
      d.to_uint64()
    })
    let probes = streams.map(fn(stream) { stream.consolidate().probe() })
    sources[0].0.insert(7)
    sources[0].0.close()
    sources[1].0.close()
    let _ = group.run()
    for peer in 0..<3 {
      assert_false(scopes.scope(peer).progress.disposed)
      assert_false(probes[peer].done())
    }
    sources[2].0.close()
    let _ = group.run()
    assert_true(scopes.coordinator.tracker is None)
    assert_true(scopes.coordinator.members.is_empty())
    for peer in 0..<3 {
      assert_true(scopes.scope(peer).progress.disposed)
      assert_true(scopes.scope(peer).progress.graph.edges.is_empty())
      assert_true(probes[peer].done())
    }
  }
  group.dispose()
}

///|
test "cluster completed scopes have tombstone manifests and fresh scopes remain compatible" {
  let cluster = ClusterWorker(0, 1, exchange=fn(message) { [message] })
  for _ in 0..<24 {
    let scope = cluster.scope(
      0L,
      SummaryDomain::int64(),
      time_codec=WireCodec::json(),
      summary_codec=WireCodec::json(),
    )
    let (input, source) : (
      InputSession[Int32, Int64, Int64],
      Collection[Int32, Int64, Int64],
    ) = scope.input()
    let result = scope.exchange(
      source,
      fn(d) { d.to_uint64() },
      data_codec=WireCodec::json(),
      time_codec=WireCodec::json(),
      diff_codec=WireCodec::json(),
    )
    let probe = result.probe()
    input.insert(9)
    input.close()
    let _ = cluster.run()
    assert_true(probe.done())
    assert_true(scope.scope.progress.disposed)
    assert_true(scope.scope.progress.tracker is None)
    for core in cluster.state.scopes {
      assert_eq((core.manifest)(), Json::null())
    }
  }
  cluster.dispose()
}

///|
test "collective cancellation discards already routed records before delivery" {
  let cluster = ClusterWorker(0, 1, exchange=fn(message) { [message] })
  let scope = cluster.scope(
    0L,
    SummaryDomain::int64(),
    time_codec=WireCodec::json(),
    summary_codec=WireCodec::json(),
  )
  let (input, data) : (
    InputSession[Int32, Int64, Int64],
    Collection[Int32, Int64, Int64],
  ) = scope.input()
  let seen = []
  let probe = scope
    .exchange(
      data,
      fn(d) { d.to_uint64() },
      data_codec=WireCodec::json(),
      time_codec=WireCodec::json(),
      diff_codec=WireCodec::json(),
    )
    .inspect(fn(d, _, _) { seen.push(d) })
  // A valid record has already acquired a route and entered the transport queue.
  cluster.state.outgoing.push([
    Json(0),
    Json(0),
    [[Json(9), Json(0L), Json(1L)]],
  ])
  cluster.drop_dataflow(scope.dataflow_index())
  let _ = cluster.run()
  assert_eq(seen, [])
  assert_false(probe.done())
  assert_true(cluster.installed_dataflows().is_empty())
  assert_true(cluster.state.outgoing.is_empty())
  input.close()
  cluster.dispose()
}
