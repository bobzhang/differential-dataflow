///|
priv struct OperatorPorts[T, S] {
  owner : CapabilityOwner[T, S]
  domain : SummaryDomain[T, S]
  connections : Map[(Int32, Int32), Array[S]]
  inputs : Array[Int32]
  outputs : Array[Int32]
  pending_inputs : Array[() -> Bool]
  mut built : Bool
  mut running : Bool
}

///|
/// Construct a custom operator with heterogeneous inputs and outputs. New pairs
/// have identity connectivity; set_connection replaces it before build. Build
/// and connect the entire graph before executing the worker.
pub struct OperatorBuilder[T, S] {
  priv scope : Scope[T, S]
  priv ports : OperatorPorts[T, S]
  priv initial : Array[Capability[T, S]]
  priv bind : Array[(Int32) -> Unit]
  priv activation_slot : Ref[Int32?]
}

///|
/// Input data and frontier owned by a custom operator. Call for_each only within
/// that operator's build callback. The input capability is borrowed per batch.
pub struct OperatorInput[D, T, R, S] {
  priv mailbox : Mailbox[D, T, R]
  priv ports : OperatorPorts[T, S]
  priv port : Int32
  priv frontier : Ref[Antichain[T]]
}

///|
/// A borrowed input timestamp. Convert it to an owned output capability through
/// delayed; the declared path summaries determine which times are permitted.
pub struct InputCapability[T, S] {
  priv ports : OperatorPorts[T, S]
  priv port : Int32
  priv time : T
  priv mut live : Bool
}

///|
pub fn[T, S] Scope::operator(self : Scope[T, S]) -> OperatorBuilder[T, S] {
  guard self.worker.scheduler.active &&
    !self.worker.scheduler.stepping &&
    !self.progress.frozen else {
    abort("build operator before execution")
  }
  let ports : OperatorPorts[T, S] = {
    owner: Scoped(self.progress),
    domain: self.domain,
    connections: Map([]),
    inputs: [],
    outputs: [],
    pending_inputs: [],
    built: false,
    running: false,
  }
  // An unfinished builder must not silently disappear from progress tracking.
  self.worker.progress.push(fn() {
    guard ports.built else { abort("operator builder was not built") }
  })
  { scope: self, ports, initial: [], bind: [], activation_slot: Ref(None), }
}

///|
pub fn[D, T : Lattice, R, S] OperatorBuilder::new_output(
  self : OperatorBuilder[T, S],
) -> (Output[D, T, R, S], Collection[D, T, R]) {
  guard !self.ports.built else { abort("operator is already built") }
  let (output, capability, collection) = self.scope.source()
  let port = output.channel.port
  for input in self.ports.inputs {
    self.ports.connections[(input, port)] = [self.scope.domain.identity]
  }
  self.ports.outputs.push(port)
  self.initial.push(capability)
  (output, collection)
}

///|
pub fn[D, T : Lattice, R, S] OperatorBuilder::new_input(
  self : OperatorBuilder[T, S],
  source : Collection[D, T, R],
) -> OperatorInput[D, T, R, S] {
  guard !self.ports.built else { abort("operator is already built") }
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.scope.context) else {
    abort("operator input belongs to another scope")
  }
  let mailbox : Mailbox[D, T, R] = Mailbox()
  // Reserve the input port now, but subscribe only after register assigns its
  // task. Observer callbacks capture the task value at subscription time.
  let port = (self.scope.context.add_port)()
  let pending = self.scope.context.pending
  mailbox.counter = Some((pending, port))
  for output in self.ports.outputs {
    self.ports.connections[(port, output)] = [self.scope.domain.identity]
  }
  self.ports.inputs.push(port)
  let channel = source.channel
  let context = self.scope.context
  let frames = mailbox.frames
  self.ports.pending_inputs.push(fn() { !frames.is_empty() })
  let scheduler = self.scope.worker.scheduler
  self.bind.push(fn(task) {
    mailbox.task = task
    channel.subscribers.push(mailbox)
    (context.connect)(channel.port, port)
    (context.observe)(port, fn(frontier) {
      frames.push(Progress(frontier))
      scheduler.schedule(task)
    })
  })
  {
    mailbox,
    port,
    ports: self.ports,
    frontier: Ref(Antichain(source.channel.frontier.val.elements)),
  }
}

///|
/// Replace connectivity for this pair. Empty summaries disconnect progress and
/// prohibit deriving output capabilities from this input. Multiple incomparable
/// summaries are supported; each must be a lawful summary for the scope domain.
pub fn[D, E, T, R, U, S] OperatorBuilder::set_connection(
  self : OperatorBuilder[T, S],
  input : OperatorInput[D, T, R, S],
  output : Output[E, T, U, S],
  summaries : Array[S],
) -> Unit {
  guard !self.ports.built &&
    physical_equal(self.ports, input.ports) &&
    self.ports.owner.same(output.owner) &&
    self.ports.outputs.contains(output.channel.port) else {
    abort("connection requires ports of this unbuilt operator")
  }
  self.ports.connections[(input.port, output.channel.port)] = summaries.copy()
}

///|
/// Initial capabilities are owned by the builder callback, in output creation
/// order. Release them when no longer needed. The returned function runs when
/// any input has data or a frontier change; it may drain heterogeneous inputs.
pub fn[T : Compare, S] OperatorBuilder::build(
  self : OperatorBuilder[T, S],
  construct : (Array[Capability[T, S]]) -> () -> Unit,
  on_shutdown? : () -> Unit,
) -> Unit {
  self.build_reschedule(
    fn(capabilities) {
      let logic = construct(capabilities)
      fn() {
        logic()
        false
      }
    },
    on_shutdown?,
  )
}

///|
/// Returning true keeps the operator alive for unfinished external work; it does
/// not automatically schedule another invocation. Returning false permits shutdown
/// once inputs are complete and output capabilities are released. on_shutdown is
/// called exactly once on retirement or worker disposal, with re-entry forbidden.
pub fn[T : Compare, S] OperatorBuilder::build_reschedule(
  self : OperatorBuilder[T, S],
  construct : (Array[Capability[T, S]]) -> () -> Bool,
  on_shutdown? : () -> Unit,
) -> Unit {
  guard !self.ports.built else { abort("operator is already built") }
  guard self.scope.worker.scheduler.active &&
    !self.scope.worker.scheduler.stepping &&
    !self.scope.progress.frozen else {
    abort("build operator before execution")
  }
  self.ports.built = true
  for pair, summaries in self.ports.connections {
    for summary in summaries {
      self.scope.progress.graph.connect(pair.0, pair.1, summary)
    }
  }
  let capabilities = self.initial.copy()
  self.initial.clear()
  let run = construct(capabilities)
  let ports = self.ports
  let incomplete = Ref(true)
  let ran = Ref(false)
  let closing = Ref(false)
  let task = self.scope.worker.register(
    fn() {
      closing.val = false
      ports.running = true
      incomplete.val = run()
      ran.val = true
      ports.running = false
    },
    automatic=false,
  )
  let progress = self.scope.progress
  let shutdown = Ref(on_shutdown)
  let finish = fn() {
    if shutdown.val is Some(close) {
      shutdown.val = None
      close()
    }
  }
  self.scope.worker.cleanup.push(finish)
  self.scope.worker.retirement.push(
    (
      task,
      fn() {
        if !ran.val || incomplete.val || closing.val {
          return false
        }
        for pending in ports.pending_inputs {
          if pending() {
            return false
          }
        }
        guard progress.tracker is Some(tracker) else { return false }
        for input in ports.inputs {
          if !tracker.frontiers[input].is_empty() {
            return false
          }
        }
        for ((port, _), count) in tracker.counts.to_array() {
          if count != 0 && ports.outputs.contains(port) {
            return false
          }
        }
        true
      },
      finish,
    ),
  )
  let scheduler = self.scope.worker.scheduler
  for output in ports.outputs {
    (self.scope.context.observe)(output, fn(frontier) {
      if frontier.is_empty() {
        closing.val = true
        scheduler.schedule(task)
      }
    })
  }
  self.activation_slot.val = Some(task)
  for bind in self.bind {
    bind(task)
  }
  self.bind.clear()
  self.scope.worker.scheduler.schedule(task)
}

///|
pub fn[D, T : Lattice, R, S] OperatorInput::frontier(
  self : OperatorInput[D, T, R, S],
) -> Antichain[T] {
  Antichain(self.frontier.val.elements)
}

///|
/// Drain data and progress in arrival order. The frontier is current after this
/// call; data callbacks see only the progress that preceded their data.
pub fn[D, T : Lattice, R, S] OperatorInput::for_each(
  self : OperatorInput[D, T, R, S],
  consume : (InputCapability[T, S], Array[(D, R)]) -> Unit,
) -> Unit {
  guard self.ports.running else {
    abort("input must be drained by its operator")
  }
  for frame in self.mailbox.drain() {
    match frame {
      Progress(frontier) => self.frontier.val = frontier
      Data(updates) => {
        updates.sort_by(fn(a, b) { Compare::compare(a.1, b.1) })
        let mut index = 0
        while index < updates.length() {
          let time = updates[index].1
          let records = []
          while index < updates.length() && updates[index].1 == time {
            records.push((updates[index].0, updates[index].2))
            index += 1
          }
          let capability : InputCapability[T, S] = {
            ports: self.ports,
            port: self.port,
            time,
            live: true,
          }
          consume(capability, records)
          capability.live = false
        }
      }
    }
  }
}

///|
pub fn[T, S] InputCapability::time(self : InputCapability[T, S]) -> T {
  guard self.live && self.ports.running else {
    abort("input capability expired")
  }
  self.time
}

///|
pub fn[D, T : Lattice, R, S] InputCapability::try_delayed(
  self : InputCapability[T, S],
  output : Output[D, T, R, S],
  time : T,
) -> Capability[T, S]? {
  guard self.live && self.ports.running && self.ports.owner.active() else {
    abort("input capability expired")
  }
  if !self.ports.owner.same(output.owner) {
    return None
  }
  let summaries = self.ports.connections
    .get((self.port, output.channel.port))
    .unwrap_or([])
  for summary in summaries {
    if self.ports.domain.results_in(summary, self.time) is Some(lower) &&
      lower.less_equal(time) {
      return Some(self.ports.owner.capability(output.channel.port, time))
    }
  }
  None
}

///|
pub fn[D, T : Lattice, R, S] InputCapability::delayed(
  self : InputCapability[T, S],
  output : Output[D, T, R, S],
  time : T,
) -> Capability[T, S] {
  self
  .try_delayed(output, time)
  .unwrap_or_else(fn() {
    abort("output time is not reachable through the declared summaries")
  })
}
