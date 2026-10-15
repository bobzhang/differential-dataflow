///|
priv struct ClusterScopeCore {
  manifest : () -> Json
  ready : () -> Bool
  reclaim : () -> Unit
  drain : () -> Json
  apply : (Array[Json]) -> Unit raise ClusterError
}

///|
priv struct ClusterState {
  scopes : Array[ClusterScopeCore]
  receivers : Array[(Json) -> Unit raise ClusterError]
  outgoing : Array[Json]
  mut graph_shape : (Int32, Int32, Int32, Int32)?
  mut round : Int64
  mut closed : Bool
}

///|
/// A worker in a synchronous distributed cluster. `exchange` is an ordered
/// all-gather: every peer calls it once per round and receives one payload per
/// peer, in peer-index order. Processes may run operators concurrently between
/// barriers. Transport errors terminate this worker; replay is never implicit.
pub struct ClusterWorker {
  priv worker : Worker
  priv index : Int32
  priv peers : Int32
  priv exchange : (String) -> Array[String] raise
  priv state : ClusterState
}

///|
pub fn ClusterWorker::ClusterWorker(
  index : Int32,
  peers : Int32,
  exchange~ : (String) -> Array[String] raise,
) -> ClusterWorker {
  guard peers > 0 && index >= 0 && index < peers else {
    abort("invalid cluster peer")
  }
  {
    worker: Worker(),
    index,
    peers,
    exchange,
    state: {
      scopes: [],
      receivers: [],
      outgoing: [],
      round: 0,
      graph_shape: None,
      closed: false,
    },
  }
}

///|
pub fn ClusterWorker::index(self : ClusterWorker) -> Int32 {
  self.index
}

///|
pub fn ClusterWorker::peers(self : ClusterWorker) -> Int32 {
  self.peers
}

///|
/// Build the same scopes, ports, summaries and exchanges in the same order on
/// every peer. Data, input capabilities and input progress may differ by peer.
pub struct DistributedScope[T, S] {
  priv scope : Scope[T, S]
  priv cluster : ClusterWorker
  priv time_codec : WireCodec[T]
  priv summary_codec : WireCodec[S]
}

///|
pub fn[T : Lattice, S : Compare] ClusterWorker::scope(
  self : ClusterWorker,
  minimum : T,
  domain : SummaryDomain[T, S],
  time_codec~ : WireCodec[T],
  summary_codec~ : WireCodec[S],
) -> DistributedScope[T, S] {
  let scope = self.worker.make_scope(minimum, domain, false)
  let progress = scope.progress
  let manifest_cache : Ref[Json?] = Ref(None)
  let scheduler = self.worker.scheduler
  let core : ClusterScopeCore = {
    manifest: fn() {
      if manifest_cache.val is Some(value) {
        return value
      }
      let value : Json = [
        (time_codec.encode)(minimum),
        Json(
          progress.graph.edges.map(fn(edges) {
            Json(
              edges.map(fn(edge) {
                ([Json(edge.0), (summary_codec.encode)(edge.1)] : Json)
              }),
            )
          }),
        ),
      ]
      manifest_cache.val = Some(value)
      value
    },
    ready: fn() { progress.ready_to_reclaim(scheduler) },
    reclaim: fn() {
      progress.dispose()
      // Every peer makes the same decision. Future graph manifests retain a
      // small completed-scope slot, not the old graph's edges.
      manifest_cache.val = Some(Json::null())
    },
    drain: fn() {
      Json(
        progress.pending
        .drain()
        .map(fn(change) {
          (
            [Json(change.0.0), (time_codec.encode)(change.0.1), Json(change.1)] :
            Json)
        }),
      )
    },
    apply: fn(changes) raise ClusterError {
      if progress.disposed {
        guard changes.is_empty() else {
          raise ClusterError("progress arrived for a completed scope")
        }
        return
      }
      progress.frozen = true
      if !changes.is_empty() {
        progress.dirty = true
      }
      let tracker = match progress.tracker {
        Some(tracker) => tracker
        None => {
          guard progress.graph.compile() is Some(reachability) else {
            raise ClusterError(
              "distributed scope reachability did not converge",
            )
          }
          let tracker = ProgressTracker(reachability)
          progress.tracker = Some(tracker)
          tracker
        }
      }
      for change in changes {
        guard change is [port, time, count] &&
          (time_codec.decode)(time) is Some(time) else {
          raise ClusterError("invalid distributed pointstamp")
        }
        let port : Int32 = wire_read(port)
        let count : Int64 = wire_read(count)
        guard port >= 0 && port < progress.observers.length() else {
          raise ClusterError("unknown distributed progress port")
        }
        tracker.update(port, time, count)
      }
    },
  }
  self.state.scopes.push(core)
  { scope, cluster: self, time_codec, summary_codec, }
}

///|
pub fn[T, S] DistributedScope::scope(
  self : DistributedScope[T, S],
) -> Scope[T, S] {
  self.scope
}

///|
pub fn[D, T : Lattice, R, S] DistributedScope::input(
  self : DistributedScope[T, S],
) -> (InputSession[D, T, R], Collection[D, T, R]) {
  self.scope.input()
}

///|
/// Keyed exchange. Outgoing records first acquire transit pointstamps. On receipt
/// those pointstamps are replaced by downstream mailbox counts in the next round.
/// Consequently neither network latency nor uneven execution can advance a
/// frontier past an undelivered record.
pub fn[D, T : Lattice, R, S] DistributedScope::exchange(
  self : DistributedScope[T, S],
  source : Collection[D, T, R],
  hash : (D) -> UInt64,
  data_codec~ : WireCodec[D],
  time_codec~ : WireCodec[T],
  diff_codec~ : WireCodec[R],
) -> Collection[D, T, R] {
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.scope.context) else {
    abort("exchange input belongs to another scope")
  }
  let output : Channel[D, T, R] = source.channel.output()
  let route = self.cluster.state.receivers.length()
  self.cluster.state.receivers.push(fn(payload) raise ClusterError {
    guard payload is Array(updates) else {
      raise ClusterError("invalid exchange batch")
    }
    let decoded = []
    for update in updates {
      guard update is [data, time, diff] &&
        (data_codec.decode)(data) is Some(data) &&
        (time_codec.decode)(time) is Some(time) &&
        (diff_codec.decode)(diff) is Some(diff) else {
        raise ClusterError("invalid exchange record")
      }
      decoded.push((data, time, diff))
    }
    for (_, time, _) in decoded {
      output.hold(time, -1)
    }
    output.data(decoded)
  })
  let outgoing = self.cluster.state.outgoing
  let peers = self.cluster.peers
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.cluster.worker.register(fn() {
    let buckets : Array[Array[Json]] = Array::makei(peers, fn(_) { [] })
    for frame in input.drain() {
      if frame is Data(updates) {
        for (data, time, diff) in updates {
          let peer = (hash(data) % peers.to_uint64()).to_int()
          buckets[peer].push([
            (data_codec.encode)(data),
            (time_codec.encode)(time),
            (diff_codec.encode)(diff),
          ])
          output.hold(time, 1)
        }
      }
    }
    for peer, bucket in buckets {
      if !bucket.is_empty() {
        outgoing.push([Json(peer), Json(route), Json(bucket)])
      }
    }
  })
  source.channel.subscribe(input)
  output.depends_on(input)
  { worker: source.worker, channel: output, }
}

///|
fn ClusterWorker::round(self : ClusterWorker) -> Bool raise {
  let state = self.state
  let ready_to_reclaim = state.scopes.map(fn(core) { (core.ready)() })
  let changes = state.scopes.map(fn(core) { (core.drain)() })
  let busy = self.worker.scheduler.head < self.worker.scheduler.queue.length()
  let shape = (
    state.scopes.length(),
    state.receivers.length(),
    self.worker.network.domains.length(),
    self.worker.network.topology.length(),
  )
  let graph_changed = state.graph_shape != Some(shape)
  let manifest : Json = if graph_changed {
    [
      Json(state.scopes.map(fn(core) { (core.manifest)() })),
      Json(state.receivers.length()),
      Json(self.worker.network.topology),
    ]
  } else {
    Json::null()
  }
  let payload : Json = [
    "moon-differential/2",
    Json(state.round),
    Json(self.index),
    Json(self.peers),
    manifest,
    Json(changes),
    Json(state.outgoing),
    Json(busy),
    Json(ready_to_reclaim),
  ]
  let gathered = (self.exchange)(payload.stringify())
  guard gathered.length() == self.peers else {
    raise ClusterError("all-gather peer count mismatch")
  }
  state.outgoing.clear()
  let totals : Array[Array[Json]] = Array::makei(state.scopes.length(), fn(_) {
    []
  })
  let retire = Array::make(state.scopes.length(), true)
  let deliveries = []
  let mut active = graph_changed
  for peer, message in gathered {
    let message = @json.parse(message) catch {
      _ => raise ClusterError("malformed cluster envelope")
    }
    guard message
      is [
        String("moon-differential/2"),
        round,
        sender,
        peers,
        other_manifest,
        Array(changes),
        Array(messages),
        ready,
        Array(completed),
      ] else {
      raise ClusterError("invalid cluster protocol envelope")
    }
    let ready : Bool = wire_read(ready)
    let round : Int64 = wire_read(round)
    let sender : Int32 = wire_read(sender)
    let peers : Int32 = wire_read(peers)
    guard round == state.round &&
      sender == peer &&
      peers == self.peers &&
      other_manifest == manifest &&
      changes.length() == totals.length() &&
      completed.length() == retire.length() else {
      raise ClusterError("cluster round, peer identity or graph mismatch")
    }
    for index, completed in completed {
      let completed : Bool = wire_read(completed)
      retire[index] = retire[index] && completed
    }
    active = active || ready || !messages.is_empty()
    for index, changes in changes {
      guard changes is Array(changes) else {
        raise ClusterError("invalid scope pointstamps")
      }
      if !changes.is_empty() {
        active = true
      }
      for change in changes {
        totals[index].push(change)
      }
    }
    for message in messages {
      guard message is [destination, route, payload] else {
        raise ClusterError("invalid routed message")
      }
      let destination : Int32 = wire_read(destination)
      let route : Int32 = wire_read(route)
      guard destination >= 0 &&
        destination < self.peers &&
        route >= 0 &&
        route < state.receivers.length() else {
        raise ClusterError("unknown destination or route")
      }
      if destination == self.index {
        deliveries.push((route, payload))
      }
    }
  }
  // All peer transactions are incorporated before any frontier is announced.
  for index, core in state.scopes {
    (core.apply)(totals[index])
  }
  for (route, payload) in deliveries {
    state.receivers[route](payload)
  }
  self.worker.network.pump()
  state.graph_shape = Some(shape)
  state.round += 1
  let ran = self.worker.step()
  for index, completed in retire {
    if completed {
      (state.scopes[index].reclaim)()
    }
  }
  self.worker.network.reclaim_completed()
  active || ran
}

///|
/// All peers must call with the same bound. Quiescent means no scheduled or
/// in-flight work anywhere; open input capabilities may still hold frontiers.
pub fn ClusterWorker::run(
  self : ClusterWorker,
  max_rounds~ : Int32 = 100000,
) -> RunResult raise {
  guard !self.state.closed else {
    raise ClusterError("cluster worker is closed")
  }
  guard max_rounds > 0 else {
    raise ClusterError("round limit must be positive")
  }
  errdefer self.dispose()
  for round in 0..<max_rounds {
    if !self.round() {
      return Quiescent(round + 1)
    }
  }
  StepLimit(max_rounds)
}

///|
/// Release local state. The caller owns and closes the transport separately.
pub fn ClusterWorker::dispose(self : ClusterWorker) -> Unit {
  if !self.state.closed {
    self.state.closed = true
    self.worker.dispose()
    self.state.scopes.clear()
    self.state.receivers.clear()
    self.state.outgoing.clear()
  }
}
