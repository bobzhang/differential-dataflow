///|
test "replay deduplicates across peers with progress arriving before scattered data" {
  for peers in [1, 2, 3] {
    let group = @differential.WorkerGroup(peers)
    let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
    let inboxes : Array[
      Array[@differential.CaptureMessage[Int32, Int64, Int64]],
    ] = Array::makei(peers, fn(_) { [] })
    let streams = scopes.replay_from(
      fn(peer, _) { fn() { inboxes[peer].pop() } },
      hash=fn(data) { data.to_uint64() },
      messages_per_turn=1,
    )
    let seen = Array::makei(peers, fn(_) { [] })
    let probes = streams.mapi(fn(peer, pair) {
      pair.1.inspect(fn(d, t, r) { seen[peer].push((d, t, r)) })
    })
    for epoch in 0L..<24L {
      // A duplicate progress statement from every source must count once.
      for inbox in inboxes {
        inbox.push(
          Progress(
            CaptureProgress(Antichain([epoch]), Antichain([epoch + 1]), [
              (epoch, 8L),
            ]),
          ),
        )
      }
      for pair in streams {
        pair.0.activate()
      }
      let _ = group.run()
      for probe in probes {
        assert_true(probe.less_than(epoch + 1))
      }
      for data in 0..<8 {
        inboxes[data % peers].push(Updates([(data, epoch, -3L)]))
        inboxes[(data + 1) % peers].push(Updates([(data, epoch, -3L)]))
      }
      for pair in streams {
        pair.0.activate()
      }
      let _ = group.run()
      for probe in probes {
        assert_false(probe.less_than(epoch + 1))
      }
    }
    inboxes[peers - 1].push(
      Progress(CaptureProgress(Antichain([24L]), Antichain([]), [])),
    )
    streams[peers - 1].0.activate()
    let _ = group.run()
    for peer in 0..<peers {
      assert_true(streams[peer].0.is_complete())
      assert_true(probes[peer].done())
      let expected = []
      for epoch in 0L..<24L {
        for data in 0..<8 {
          if data % peers == peer {
            expected.push((data, epoch, -3L))
          }
        }
      }
      seen[peer].sort()
      expected.sort()
      assert_eq(seen[peer], expected)
    }
    group.dispose()
  }
}

///|
test "distributed replay cancellation releases local capabilities only" {
  let group = @differential.WorkerGroup(3)
  let scopes = group.scopes(0L, @differential.SummaryDomain::int64())
  let streams : Array[
    (@differential.CaptureHandle, @differential.Collection[Int32, Int64, Int64]),
  ] = scopes.replay_from(fn(_, _) { fn() { None } }, hash=fn(d) {
    d.to_uint64()
  })
  let probes = streams.map(fn(pair) { pair.1.probe() })
  let _ = group.run()
  streams[0].0.cancel()
  let _ = group.run()
  for probe in probes {
    assert_false(probe.done())
  }
  for pair in streams {
    pair.0.cancel()
  }
  let _ = group.run()
  for probe in probes {
    assert_true(probe.done())
  }
  group.dispose()
}
