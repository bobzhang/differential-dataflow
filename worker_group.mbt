///|
/// Cooperative workers sharing memory. Exchange is data parallel; execution is
/// single-threaded. Network transport and cross-process progress are separate work.
pub struct WorkerGroup {
  priv workers : Array[Worker]
  priv mut next : Int32
}

///|
pub fn WorkerGroup::WorkerGroup(
  peers : Int32,
  clock? : () -> Duration,
) -> WorkerGroup {
  guard peers > 0 else { abort("worker group needs at least one peer") }
  let gate = Ref(false)
  let network = ProgressNetwork()
  {
    workers: Array::makei(peers, fn(_) {
      Worker::with_gate(gate, network, clock?)
    }),
    next: 0,
  }
}

///|
pub fn WorkerGroup::peers(self : WorkerGroup) -> Int32 {
  self.workers.length()
}

///|
pub fn WorkerGroup::worker(self : WorkerGroup, index : Int32) -> Worker {
  self.workers[index]
}

///|
pub fn WorkerGroup::step(self : WorkerGroup) -> Bool {
  for ;; {
    for _ in 0..<self.workers.length() {
      let index = self.next
      self.next = (self.next + 1) % self.workers.length()
      if self.workers[index].step() {
        return true
      }
    }
    if !self.workers
      .iter()
      .any(fn(worker) {
        worker.scheduler.head < worker.scheduler.queue.length()
      }) {
      return false
    }
  }
}

///|
pub fn WorkerGroup::run(
  self : WorkerGroup,
  max_steps~ : Int32 = 100000,
) -> RunResult {
  guard max_steps >= 0 else { abort("step limit must be nonnegative") }
  for step in 0..<max_steps {
    if !self.step() {
      return Quiescent(step)
    }
  }
  for worker in self.workers {
    let _ = worker.run(max_steps=0)
  }
  if self.workers
    .iter()
    .any(fn(worker) { worker.scheduler.head < worker.scheduler.queue.length() }) {
    StepLimit(max_steps)
  } else {
    Quiescent(max_steps)
  }
}

///|
pub fn WorkerGroup::dispose(self : WorkerGroup) -> Unit {
  for worker in self.workers {
    worker.dispose()
  }
}

///|
priv struct GroupProgress[T, S] {
  members : Array[ScopeProgress[T, S]]
  schedulers : Array[Scheduler]
  local_counts : Array[ChangeBatch[(Int32, T)]]
  mut tracker : ProgressTracker[T, S]?
}

///|
fn[T : Lattice, S : Compare] GroupProgress::pump(
  self : GroupProgress[T, S],
) -> Unit {
  let first = self.tracker is None
  let tracker = match self.tracker {
    Some(tracker) => tracker
    None => {
      let graph = self.members[0].graph
      for index in 0..<self.members.length() {
        guard self.members[index].graph.edges == graph.edges else {
          abort("worker scopes must have identical operator graphs")
        }
        self.schedulers[index].started = true
      }
      let tracker = ProgressTracker(
        graph
        .compile()
        .unwrap_or_else(fn() { abort("group reachability did not converge") }),
      )
      self.tracker = Some(tracker)
      tracker
    }
  }
  let mut changed = first
  for index, core in self.members {
    let updates = if core.disposed {
      self.local_counts[index].drain().map(fn(change) { (change.0, -change.1) })
    } else {
      let updates = core.pending.drain()
      self.local_counts[index].update_all(updates)
      updates
    }
    if !updates.is_empty() {
      changed = true
    }
    for ((port, time), diff) in updates {
      tracker.update(port, time, diff)
    }
  }
  if !changed {
    return
  }
  for core in self.members {
    if !core.disposed {
      let peer_tracker = match core.tracker {
        Some(peer_tracker) => peer_tracker
        None => {
          let peer_tracker = ProgressTracker(tracker.reachability)
          core.tracker = Some(peer_tracker)
          peer_tracker
        }
      }
      peer_tracker.counts.clear()
      peer_tracker.counts.update_all(tracker.counts.to_array())
      core.dirty = true
    }
  }
}

///|
/// Identical operator graphs with globally counted pointstamps across peer workers.
pub struct ScopeGroup[T, S] {
  priv scopes : Array[Scope[T, S]]
  priv coordinator : GroupProgress[T, S]
}

///|
pub fn[T : Lattice, S : Compare] WorkerGroup::scopes(
  self : WorkerGroup,
  minimum : T,
  domain : SummaryDomain[T, S],
) -> ScopeGroup[T, S] {
  let scopes = self.workers.map(fn(worker) {
    worker.make_scope(minimum, domain, false)
  })
  coordinate_scopes(scopes)
}

///|
fn[T : Lattice, S : Compare] coordinate_scopes(
  scopes : Array[Scope[T, S]],
) -> ScopeGroup[T, S] {
  let progress : GroupProgress[T, S] = {
    members: scopes.map(fn(scope) { scope.progress }),
    schedulers: scopes.map(fn(scope) { scope.worker.scheduler }),
    local_counts: Array::makei(scopes.length(), fn(_) { ChangeBatch() }),
    tracker: None,
  }
  for scope in scopes {
    scope.worker.progress.push(fn() { progress.pump() })
    let core = scope.progress
    scope.worker.cleanup.push(fn() {
      core.disposed = true
      if !progress.members.iter().any(fn(core) { !core.disposed }) {
        progress.tracker = None
        progress.local_counts.clear()
        progress.members.clear()
        progress.schedulers.clear()
      }
    })
  }
  { scopes, coordinator: progress, }
}

///|
pub fn[T, S] ScopeGroup::scope(
  self : ScopeGroup[T, S],
  index : Int32,
) -> Scope[T, S] {
  guard !self.coordinator.members.is_empty() else {
    abort("worker group is disposed")
  }
  self.scopes[index]
}

///|
pub fn[D, T : Lattice, R, S] ScopeGroup::input(
  self : ScopeGroup[T, S],
) -> Array[(InputSession[D, T, R], Collection[D, T, R])] {
  self.scopes.map(fn(scope) { scope.input() })
}

///|
/// Route each record to hash(data) % peers. Connectivity and message counts are
/// shared across peers, so an idle peer cannot report another peer's time complete.
pub fn[D, T : Lattice, R, S] ScopeGroup::exchange(
  self : ScopeGroup[T, S],
  inputs : Array[Collection[D, T, R]],
  hash : (D) -> UInt64,
) -> Array[Collection[D, T, R]] {
  guard inputs.length() == self.scopes.length() else {
    abort("exchange needs one collection per peer")
  }
  for index, source in inputs {
    guard source.channel.context is Some(context) &&
      physical_equal(context, self.scopes[index].context) else {
      abort("exchange input is not in the matching peer scope")
    }
  }
  let outputs : Array[Channel[D, T, R]] = inputs.map(fn(source) {
    source.channel.output()
  })
  let peers = outputs.length().to_uint64()
  for index, source in inputs {
    let input : Mailbox[D, T, R] = Mailbox()
    input.task = source.worker.register(fn() {
      for frame in input.drain() {
        if frame is Data(updates) {
          let buckets = Array::makei(outputs.length(), fn(_) { [] })
          for update in updates {
            let destination = (hash(update.0) % peers).to_int()
            buckets[destination].push(update)
          }
          for peer, bucket in buckets {
            outputs[peer].data(bucket)
          }
        }
      }
    })
    source.channel.subscribe(input)
    outputs[index].depends_on(input)
  }
  Array::makei(inputs.length(), fn(index) {
    { worker: inputs[index].worker, channel: outputs[index], }
  })
}
