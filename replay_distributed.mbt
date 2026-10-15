///|
/// Replay one captured collection from sources scattered across peers. Unique
/// data/time pairs are emitted immediately on hash(data) % peers; conflicting
/// differences are rejected. Timestamp counts are sharded by time_hash (default
/// peer zero). Progress is global, so a paused source cannot imply completion.
pub fn[D : Compare, T : Lattice, R : Compare, S] ScopeGroup::replay_from(
  self : ScopeGroup[T, S],
  build_source : (Int32, Activator) -> () -> CaptureMessage[D, T, R]?,
  hash~ : (D) -> UInt64,
  time_hash~ : (T) -> UInt64 = fn(_) { 0UL },
  messages_per_turn~ : Int32 = 1024,
) -> Array[(CaptureHandle, Collection[D, T, R])] {
  let peers = self.scopes.length()
  let queues : Array[ReplayQueue[D, T, R]] = Array::makei(peers, fn(_) {
    ReplayQueue()
  })
  let handles : Array[CaptureHandle] = []
  let outputs = []
  for peer, scope in self.scopes {
    let result = scope.partitioned_replay(
      queues[peer],
      fn(a) { build_source(peer, a) },
      fn(destination, packet) {
        let handle = handles[destination]
        if !handle.is_cancelled() && !handle.is_complete() {
          queues[destination].push(packet)
          handle.activate()
        }
      },
      hash,
      time_hash,
      peer,
      peers,
      messages_per_turn,
    )
    handles.push(result.0)
    outputs.push(result)
  }
  outputs
}

///|
/// Reconstruct a captured collection with partitioned deduplication and timestamp
/// accounting. Only compact progress frontiers are broadcast. Build matching
/// codecs and hashes on every peer. The default count partition hashes the time
/// codec's JSON representation; time_hash can override this for interoperability.
pub fn[D : Compare, T : Lattice, R : Compare, S] DistributedScope::replay_from(
  self : DistributedScope[T, S],
  build_source : (Activator) -> () -> CaptureMessage[D, T, R]?,
  codec~ : WireCodec[CaptureMessage[D, T, R]],
  hash~ : (D) -> UInt64,
  time_hash? : (T) -> UInt64,
  messages_per_turn~ : Int32 = 1024,
) -> (CaptureHandle, Collection[D, T, R]) {
  let queue = ReplayQueue()
  let slot : Ref[CaptureHandle?] = Ref(None)
  let route = self.cluster.state.receivers.length()
  let peers = self.cluster.peers
  let time_codec = self.time_codec
  let context = self.scope.context
  self.cluster.state.receivers.push(fn(payload) raise ClusterError {
    if !(context.active)() {
      return
    }
    let packet : ReplayPacket[D, T, R] = match payload {
      [String("records"), message] => {
        guard codec.from_json(message) is Some(Updates(rows)) else {
          raise ClusterError("invalid capture records")
        }
        Records(rows)
      }
      [String("statement"), message] => {
        guard codec.from_json(message) is Some(Progress(progress)) else {
          raise ClusterError("invalid capture statement")
        }
        Statement(progress)
      }
      [String("counts"), Array(rows)] => {
        let counts = []
        for row in rows {
          guard row is [time, count] && time_codec.from_json(time) is Some(time) else {
            raise ClusterError("invalid capture count time")
          }
          let count : Int64 = wire_read(count)
          guard count < 0 else {
            raise ClusterError("invalid capture received count")
          }
          counts.push((time, count))
        }
        Counts(counts)
      }
      [String("frontier"), source, Array(times)] => {
        let source : Int32 = wire_read(source)
        guard source >= 0 && source < peers else {
          raise ClusterError("invalid capture frontier source")
        }
        let frontier = Antichain([])
        for time in times {
          guard time_codec.from_json(time) is Some(time) else {
            raise ClusterError("invalid capture frontier time")
          }
          let _ = frontier.insert(time)
        }
        Frontier(source, frontier)
      }
      _ => raise ClusterError("invalid distributed capture packet")
    }
    let handle = slot.val.unwrap()
    if !handle.is_complete() && !handle.is_cancelled() {
      queue.push(packet)
      handle.activate()
    }
  })
  let outgoing = self.cluster.state.outgoing
  let time_hash = time_hash.unwrap_or_else(fn() {
    fn(time) {
      let hasher = FnvHasher()
      hasher.write(
        @utf8.encode(time_codec.to_json(time).stringify()).exact_view(),
      )
      hasher.finish()
    }
  })
  let result = self.scope.partitioned_replay(
    queue,
    build_source,
    fn(destination, packet) {
      let payload : Json = match packet {
        Records(rows) => ["records", codec.to_json(Updates(rows))]
        Statement(progress) => ["statement", codec.to_json(Progress(progress))]
        Counts(counts) =>
          [
            "counts",
            Json(
              counts.map(fn(c) { ([time_codec.to_json(c.0), Json(c.1)] : Json) }),
            ),
          ]
        Frontier(source, frontier) =>
          [
            "frontier",
            Json(source),
            Json(frontier.elements.map(fn(t) { time_codec.to_json(t) })),
          ]
      }
      outgoing.push([Json(destination), Json(route), payload])
    },
    hash,
    time_hash,
    self.cluster.index,
    peers,
    messages_per_turn,
  )
  slot.val = Some(result.0)
  result
}
