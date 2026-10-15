///|
priv struct ProgressContext[T] {
  add_port : () -> Int32
  connect : (Int32, Int32) -> Unit
  observe : (Int32, (Antichain[T]) -> Unit) -> Unit
  pending : ChangeBatch[(Int32, T)]
}

///|
priv struct ScopeProgress[T, S] {
  graph : ProgressGraph[T, S]
  pending : ChangeBatch[(Int32, T)]
  observers : Array[Array[(Antichain[T]) -> Unit]]
  mut tracker : ProgressTracker[T, S]?
  mut disposed : Bool
}

///|
fn[T : Lattice, S : Compare] ScopeProgress::pump(
  self : ScopeProgress[T, S],
) -> Unit {
  let first = self.tracker is None
  let tracker = match self.tracker {
    Some(tracker) => tracker
    None => {
      let reachability = self.graph
        .compile()
        .unwrap_or_else(fn() { abort("scope reachability did not converge") })
      let tracker = ProgressTracker(reachability)
      self.tracker = Some(tracker)
      tracker
    }
  }
  let updates = self.pending.drain()
  if !first && updates.is_empty() {
    return
  }
  for ((port, time), diff) in updates {
    tracker.update(port, time, diff)
  }
  let changes = tracker.propagate()
  for port in 0..<self.observers.length() {
    if first || changes.iter().any(fn(change) { change.0 == port }) {
      let frontier = tracker.frontier(port)
      for notify in self.observers[port] {
        notify(Antichain(frontier.elements))
      }
    }
  }
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
  guard self.scheduler.active && !self.scheduler.started else {
    abort("build scope before execution")
  }
  let progress : ScopeProgress[T, S] = {
    graph: ProgressGraph(domain),
    pending: ChangeBatch(),
    observers: [],
    tracker: None,
    disposed: false,
  }
  let scheduler = self.scheduler
  let context = {
    pending: progress.pending,
    add_port: fn() {
      guard scheduler.active && !scheduler.started else {
        abort("build scope before execution")
      }
      let port = progress.graph.add_port()
      progress.observers.push([])
      port
    },
    connect: fn(source, target) {
      progress.graph.connect(source, target, domain.identity)
    },
    observe: fn(port, notify) { progress.observers[port].push(notify) },
  }
  if local_progress {
    self.progress.push(fn() { progress.pump() })
  }
  self.cleanup.push(fn() {
    progress.disposed = true
    progress.observers.clear()
    progress.graph.edges.clear()
    progress.pending.clear()
    progress.tracker = None
  })
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
