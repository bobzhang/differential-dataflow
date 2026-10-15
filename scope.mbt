///|
priv struct ProgressContext[T] {
  add_port : () -> Int32
  connect : (Int32, Int32) -> Unit
  observe : (Int32, (Antichain[T]) -> Unit) -> Unit
  pending : ChangeBatch[(Int32, T)]
  freeze : () -> Unit
  own_task : (Int32) -> Unit
}

///|
priv struct ScopeProgress[T, S] {
  id : Int32
  tasks : Array[Int32]
  graph : ProgressGraph[T, S]
  transient : Array[Antichain[T]]
  mut frozen : Bool
  mut dirty : Bool
  mut notified : Bool
  pending : ChangeBatch[(Int32, T)]
  observers : Array[Array[(Antichain[T]) -> Unit]]
  mut tracker : ProgressTracker[T, S]?
  mut disposed : Bool
}

///|
fn[T : Lattice, S : Compare] ScopeProgress::prepare(
  self : ScopeProgress[T, S],
  drain_local : Bool,
) -> Bool {
  self.frozen = true
  let mut changed = self.dirty
  self.dirty = false
  if self.disposed {
    return changed
  }
  if self.tracker is None {
    self.tracker = Some(
      ProgressTracker(
        self.graph
        .compile()
        .unwrap_or_else(fn() { abort("scope reachability did not converge") }),
      ),
    )
    changed = true
  }
  if drain_local {
    let updates = self.pending.drain()
    if !updates.is_empty() {
      changed = true
    }
    let tracker = self.tracker.unwrap()
    for ((port, time), diff) in updates {
      tracker.update(port, time, diff)
    }
  }
  changed
}

///|
fn[T : Lattice, S] ScopeProgress::include_frontier(
  self : ScopeProgress[T, S],
  origin : Int32,
  times : Array[T],
) -> Bool {
  let reachability = self.tracker.unwrap().reachability
  let mut changed = false
  for time in times {
    for destination in 0..<self.transient.length() {
      for summary in reachability.paths[origin][destination] {
        if (reachability.domain.apply)(summary, time) is Some(at) {
          let inserted = self.transient[destination].insert(at)
          changed = changed || inserted
        }
      }
    }
  }
  changed
}

///|
fn[T : Lattice, S] ScopeProgress::seed(self : ScopeProgress[T, S]) -> Unit {
  self.transient.clear()
  if self.disposed {
    return
  }
  let tracker = self.tracker.unwrap()
  for _ in tracker.frontiers {
    self.transient.push(Antichain([]))
  }
  for ((port, time), count) in tracker.counts.to_array() {
    if count > 0 {
      let _ = self.include_frontier(port, [time])
    }
  }
}

///|
fn[T : Lattice, S] ScopeProgress::publish(self : ScopeProgress[T, S]) -> Unit {
  if self.disposed {
    return
  }
  let tracker = self.tracker.unwrap()
  let previous = tracker.frontiers
  tracker.frontiers = self.transient.map(fn(frontier) {
    Antichain(frontier.elements)
  })
  for port in 0..<self.observers.length() {
    if !self.notified ||
      previous[port].elements != tracker.frontiers[port].elements {
      for notify in self.observers[port] {
        notify(tracker.frontier(port))
      }
    }
  }
  self.notified = true
}

///|
/// A timestamp domain with counted progress through cyclic operator graphs.
/// Build all operators and feedback edges before sending data or stepping the worker.
pub struct Scope[T, S] {
  priv worker : Worker
  priv minimum : T
  priv domain : SummaryDomain[T, S]
  priv progress : ScopeProgress[T, S]
  priv context : ProgressContext[T]
}

///|
pub fn[T : Lattice, S : Compare] Worker::scope(
  self : Worker,
  minimum : T,
  domain : SummaryDomain[T, S],
) -> Scope[T, S] {
  self.make_scope(minimum, domain, true)
}

///|
fn[T : Lattice, S : Compare] Worker::make_scope(
  self : Worker,
  minimum : T,
  domain : SummaryDomain[T, S],
  local_progress : Bool,
) -> Scope[T, S] {
  guard self.scheduler.active && !self.scheduler.stepping && !self.gate.val else {
    abort("create scopes only on an idle active worker")
  }
  let progress : ScopeProgress[T, S] = {
    id: self.network.domains.length(),
    tasks: [],
    transient: [],
    dirty: true,
    frozen: false,
    notified: false,
    graph: ProgressGraph(domain),
    pending: ChangeBatch(),
    observers: [],
    tracker: None,
    disposed: false,
  }
  let scheduler = self.scheduler
  let context = {
    pending: progress.pending,
    freeze: fn() { progress.frozen = true },
    own_task: fn(task) {
      if !progress.tasks.contains(task) {
        progress.tasks.push(task)
      }
    },
    add_port: fn() {
      guard scheduler.active && !scheduler.stepping && !progress.frozen else {
        abort("build a scope before executing it or flushing its inputs")
      }
      let port = progress.graph.add_port()
      progress.observers.push([])
      port
    },
    connect: fn(source, target) {
      guard !progress.frozen else { abort("scope graph is frozen") }
      progress.graph.connect(source, target, domain.identity)
    },
    observe: fn(port, notify) { progress.observers[port].push(notify) },
  }
  self.network.domains.push({
    prepare: fn() { progress.prepare(local_progress) },
    seed: fn() { progress.seed() },
    publish: fn() { progress.publish() },
    reclaim: fn() {
      if progress.disposed {
        return true
      }
      if local_progress && progress.ready_to_reclaim(scheduler) {
        progress.dispose()
        true
      } else {
        false
      }
    },
  })
  self.cleanup.push(fn() { progress.dispose() })
  { worker: self, minimum, domain, progress, context, }
}

///|
pub fn[D, T : Lattice, R, S] Scope::input(
  self : Scope[T, S],
) -> (InputSession[D, T, R], Collection[D, T, R]) {
  let channel : Channel[D, T, R] = Channel(
    self.worker.scheduler,
    Antichain([self.minimum]),
    context=self.context,
  )
  let pending = self.context.pending
  let port = channel.port
  let held = Ref(Antichain([self.minimum]))
  pending.update((port, self.minimum), 1)
  let input = InputSession(self.minimum, deliver=fn(data, frontier) {
    channel.data(data)
    if held.val.elements != frontier.elements {
      channel.scheduler.started = true
      if channel.context is Some(context) {
        (context.freeze)()
      }
    }
    for time in held.val.elements {
      pending.update((port, time), -1)
    }
    for time in frontier.elements {
      pending.update((port, time), 1)
    }
    held.val = Antichain(frontier.elements)
  })
  (input, { worker: self.worker, channel, })
}

///|
fn[T, S] ScopeProgress::dispose(self : ScopeProgress[T, S]) -> Unit {
  self.disposed = true
  self.dirty = true
  self.transient.clear()
  self.observers.clear()
  self.graph.edges.clear()
  self.pending.clear()
  self.tasks.clear()
  self.tracker = None
}

///|
fn[T : Compare, S] ScopeProgress::ready_to_reclaim(
  self : ScopeProgress[T, S],
  scheduler : Scheduler,
) -> Bool {
  if self.disposed {
    return true
  }
  if !self.notified ||
    !self.pending.is_empty() ||
    self.tasks.iter().any(fn(task) { scheduler.slots.contains(task) }) {
    return false
  }
  guard self.tracker is Some(tracker) else { return false }
  tracker.counts.is_empty() &&
  tracker.frontiers.iter().all(fn(frontier) { frontier.is_empty() })
}
