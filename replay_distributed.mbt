///|
// Each peer reconstructs the same capture protocol frontier, then emits only
// its data partition. Replicated protocol state is a correctness-first backend
// adaptation; upstream partitions its deduplication/count state across workers.
fn[D : Compare, T : Lattice, R : Compare, S] Scope::replicated_replay(
  self : Scope[T, S],
  inbox : Array[CaptureMessage[D, T, R]],
  build_source : (Activator) -> () -> CaptureMessage[D, T, R]?,
  send : (CaptureMessage[D, T, R]) -> Unit,
  hash : (D) -> UInt64,
  peer : Int32,
  peers : Int32,
  budget : Int32,
) -> (CaptureHandle, Collection[D, T, R]) {
  guard budget > 0 else { abort("replay turn budget must be positive") }
  let wake : Ref[Activator?] = Ref(None)
  let (reader, stream) = self.replay_from(
    fn(_) {
      fn() {
        let message = inbox.pop()
        if message is Some(_) {
          wake.val.unwrap().activate()
        }
        message
      }
    },
    messages_per_turn=budget,
  )
  let builder = self.operator()
  let activator = builder.activator()
  wake.val = Some(activator)
  let complete = Ref(false)
  let cancelled = Ref(false)
  let handle = { activator, complete, cancelled, }
  let poll = build_source(activator)
  builder.build_reschedule(
    fn(_) {
      fn() {
        if cancelled.val {
          inbox.clear()
          reader.cancel()
          return false
        }
        if reader.is_complete() {
          complete.val = true
          inbox.clear()
          return false
        }
        reader.activate()
        for _ in 0..<budget {
          guard poll() is Some(message) else { return true }
          send(message)
        }
        activator.activate()
        true
      }
    },
    on_shutdown=fn() {
      inbox.clear()
      if !complete.val {
        cancelled.val = true
        reader.cancel()
      }
    },
  )
  (
    handle,
    stream.filter(fn(data) { (hash(data) % peers.to_uint64()).to_int() == peer }),
  )
}

///|
/// Replay one captured collection from sources distributed across peers. A
/// message may appear on any number of peers. Supply identical deterministic
/// partition hashes. None pauses a source; activate its handle when input arrives.
/// Protocol state is replicated on every peer, output records are partitioned.
pub fn[D : Compare, T : Lattice, R : Compare, S] ScopeGroup::replay_from(
  self : ScopeGroup[T, S],
  build_source : (Int32, Activator) -> () -> CaptureMessage[D, T, R]?,
  hash~ : (D) -> UInt64,
  messages_per_turn~ : Int32 = 1024,
) -> Array[(CaptureHandle, Collection[D, T, R])] {
  let peers = self.scopes.length()
  let queues : Array[Array[CaptureMessage[D, T, R]]] = Array::makei(peers, fn(
    _,
  ) {
    []
  })
  let handles : Array[CaptureHandle] = []
  let outputs = []
  for peer, scope in self.scopes {
    let (handle, stream) = scope.replicated_replay(
      queues[peer],
      fn(activator) { build_source(peer, activator) },
      fn(message) {
        for destination in 0..<peers {
          let handle = handles[destination]
          if !handle.is_cancelled() && !handle.is_complete() {
            queues[destination].push(
              match message {
                Updates(rows) => Updates(rows.copy())
                Progress(progress) => Progress(progress)
              },
            )
            handle.activate()
          }
        }
      },
      hash,
      peer,
      peers,
      messages_per_turn,
    )
    handles.push(handle)
    outputs.push((handle, stream))
  }
  outputs
}

///|
/// Replay a captured collection whose messages are scattered or duplicated
/// across processes. All peers build this route in the same order, with the same
/// codec and partition hash. Messages and deduplication state are replicated;
/// records are emitted once globally on hash(data) % peers. This uses the
/// cluster's versioned wire protocol rather than Timely wire interoperability.
pub fn[D : Compare, T : Lattice, R : Compare, S] DistributedScope::replay_from(
  self : DistributedScope[T, S],
  build_source : (Activator) -> () -> CaptureMessage[D, T, R]?,
  codec~ : WireCodec[CaptureMessage[D, T, R]],
  hash~ : (D) -> UInt64,
  messages_per_turn~ : Int32 = 1024,
) -> (CaptureHandle, Collection[D, T, R]) {
  let queue = []
  let handle_slot : Ref[CaptureHandle?] = Ref(None)
  let route = self.cluster.state.receivers.length()
  self.cluster.state.receivers.push(fn(payload) raise ClusterError {
    guard codec.from_json(payload) is Some(message) else {
      raise ClusterError("invalid distributed capture message")
    }
    let handle = handle_slot.val.unwrap()
    if !handle.is_cancelled() && !handle.is_complete() {
      queue.push(message)
      handle.activate()
    }
  })
  let outgoing = self.cluster.state.outgoing
  let peers = self.cluster.peers
  let result = self.scope.replicated_replay(
    queue,
    build_source,
    fn(message) {
      let payload = codec.to_json(message)
      for peer in 0..<peers {
        outgoing.push([Json(peer), Json(route), payload])
      }
    },
    hash,
    self.cluster.index,
    peers,
    messages_per_turn,
  )
  handle_slot.val = Some(result.0)
  result
}
