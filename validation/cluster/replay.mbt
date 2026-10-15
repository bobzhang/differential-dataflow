///|
fn replay(cluster : @differential.ClusterWorker, seed : Int32) -> String raise {
  let scope = cluster.scope(
    0L,
    @differential.SummaryDomain::int64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let inbox : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  let (handle, stream) = scope.replay_from(
    fn(_) { fn() { inbox.pop() } },
    codec=@differential.CaptureMessage::codec(
      @differential.WireCodec::json(),
      @differential.WireCodec::json(),
      @differential.WireCodec::json(),
    ),
    hash=fn(d) { d.to_uint64() },
    messages_per_turn=2,
  )
  let seen : Map[Int32, Int64] = Map([])
  let probe = stream.inspect(fn(d, _, r) {
    seen[d] = seen.get(d).unwrap_or(0L) + r
  })
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for epoch in 0L..<16L {
    inbox.push(
      Progress(
        CaptureProgress(Antichain([epoch]), Antichain([epoch + 1]), [
          (epoch, 8L),
        ]),
      ),
    )
    handle.activate()
    let _ = cluster.run()
    guard probe.less_than(epoch + 1) else {
      abort("distributed replay advanced before its records")
    }
    for slot in 0..<8 {
      random = random * 1664525U + 1013904223U
      let data = ((
        seed.reinterpret_as_uint() % 16U + slot.reinterpret_as_uint()
      ) %
      16U).reinterpret_as_int()
      let diff = (random % 3U + 1U).to_int64() *
        (if random % 2U == 0U { 1L } else { -1L })
      let owner = (slot + epoch.to_int()) % cluster.peers()
      if cluster.index() == owner ||
        cluster.index() == (owner + 1) % cluster.peers() {
        inbox.push(Updates([(data, epoch, diff)]))
        inbox.push(Updates([(data, epoch, diff)]))
      }
    }
    handle.activate()
    let _ = cluster.run()
    guard !probe.less_than(epoch + 1) else {
      abort("distributed replay did not seal its records")
    }
    let rows = seen.to_array().filter(fn(row) { row.1 != 0L })
    rows.sort()
    output.push(rows.map(fn(row) { "\{row.0},\{row.1}" }).join(";"))
  }
  if cluster.index() == cluster.peers() - 1 {
    inbox.push(Progress(CaptureProgress(Antichain([16L]), Antichain([]), [])))
    handle.activate()
  }
  let _ = cluster.run()
  guard handle.is_complete() && probe.done() else {
    abort("distributed replay failed to close")
  }
  output.join("/")
}
