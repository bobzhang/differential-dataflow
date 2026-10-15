///|
// Scheduler handles retain task metadata, never operator closures. Retired task
// identities are never reused, so old activators remain permanently inert.
priv struct TaskStatus {
  mut queued : Bool
  input_done : Array[() -> Bool]
  output_done : Array[() -> Bool]
  finalizers : Array[() -> Unit]
}

///|
priv struct Scheduler {
  queue : Array[Int32]
  slots : Map[Int32, TaskStatus]
  mut next_task : Int32
  mut head : Int32
  mut started : Bool
  mut active : Bool
  mut stepping : Bool
  clock : (() -> Duration)?
  mut last_time : Duration
  timers : Array[(Duration, Ref[Int32?])]
}

///|
/// Cooperative worker. Each scope is frozen on first execution or input flush;
/// fresh scopes can be built between worker steps.
pub struct Worker {
  priv network : ProgressNetwork
  priv gate : Ref[Bool]
  priv scheduler : Scheduler
  priv tasks : Map[Int32, () -> Unit]
  priv retirement : Array[(Int32, () -> Bool, () -> Unit)]
  priv progress : Array[() -> Unit]
  priv cleanup : Array[() -> Unit]
  priv dataflows : Map[Int32, DataflowState]
  priv mut next_dataflow : Int32
}

///|
pub fn Worker::Worker(clock? : () -> Duration) -> Worker {
  Worker::with_gate(Ref(false), ProgressNetwork(), clock?)
}

///|
fn Worker::with_gate(
  gate : Ref[Bool],
  network : ProgressNetwork,
  clock? : () -> Duration,
) -> Worker {
  network.workers += 1
  {
    network,
    gate,
    scheduler: {
      queue: [],
      slots: Map([]),
      next_task: 0,
      head: 0,
      started: false,
      active: true,
      stepping: false,
      clock,
      last_time: Duration(0UL),
      timers: [],
    },
    tasks: Map([]),
    retirement: [],
    progress: [],
    cleanup: [],
    dataflows: Map([]),
    next_dataflow: 0,
  }
}

///|
fn Scheduler::schedule(self : Scheduler, id : Int32) -> Unit {
  guard self.active else { abort("worker is disposed") }
  if self.slots.get(id) is Some(status) && !status.queued {
    status.queued = true
    self.queue.push(id)
  }
}

///|
fn Worker::register(
  self : Worker,
  task : () -> Unit,
  automatic~ : Bool = true,
) -> Int32 {
  guard self.scheduler.active && !self.scheduler.stepping && !self.gate.val else {
    abort("build graph only on an idle active worker")
  }
  let id = self.scheduler.next_task
  guard id < 0x7fff_ffff else { abort("worker task identity space exhausted") }
  self.scheduler.next_task += 1
  self.tasks[id] = task
  let status : TaskStatus = {
    queued: false,
    input_done: [],
    output_done: [],
    finalizers: [],
  }
  self.scheduler.slots[id] = status
  if automatic {
    self.retirement.push(
      (
        id,
        fn() {
          !status.queued &&
          !status.input_done.is_empty() &&
          status.input_done.iter().all(fn(done) { done() }) &&
          status.output_done.iter().all(fn(done) { done() })
        },
        fn() { () },
      ),
    )
  }
  id
}

///|
/// Execute one activated operator; true means a task ran, not that inputs are complete.
pub fn Worker::step(self : Worker) -> Bool {
  guard self.scheduler.active else { abort("worker is disposed") }
  guard !self.scheduler.stepping && !self.gate.val else {
    abort("worker group step cannot re-enter")
  }
  self.scheduler.started = true
  self.scheduler.stepping = true
  self.gate.val = true
  self.scheduler.poll_timers()
  for pump in self.progress {
    pump()
  }
  self.network.pump()
  self.retire_completed()
  self.network.reclaim_completed()
  if self.scheduler.head >= self.scheduler.queue.length() {
    self.scheduler.stepping = false
    self.gate.val = false
    return false
  }
  let id = self.scheduler.queue[self.scheduler.head]
  self.scheduler.head += 1
  self.scheduler.slots[id].queued = false
  if self.scheduler.head == self.scheduler.queue.length() {
    self.scheduler.queue.clear()
    self.scheduler.head = 0
  } else if self.scheduler.head >= 1024 &&
    self.scheduler.head >= self.scheduler.queue.length() / 2 {
    let retained = self.scheduler.queue[self.scheduler.head:].to_owned()
    self.scheduler.queue.clear()
    for task in retained {
      self.scheduler.queue.push(task)
    }
    self.scheduler.head = 0
  }
  self.scheduler.stepping = true
  self.tasks[id]()
  for pump in self.progress {
    pump()
  }
  self.network.pump()
  self.retire_completed()
  self.network.reclaim_completed()
  self.scheduler.stepping = false
  self.gate.val = false
  true
}

///|
pub(all) enum RunResult {
  Quiescent(Int32)
  StepLimit(Int32)
} derive(Eq, Debug)

///|
pub extend RunResult with Eq::{equal, not_equal}

///|
pub extend RunResult with Debug::{to_repr}

///|
pub fn Worker::run(self : Worker, max_steps~ : Int32 = 100000) -> RunResult {
  guard self.scheduler.active && !self.scheduler.stepping && !self.gate.val else {
    abort("worker is disposed or running")
  }
  self.scheduler.started = true
  guard max_steps >= 0 else { abort("step limit must be nonnegative") }
  self.scheduler.stepping = true
  self.gate.val = true
  self.scheduler.poll_timers()
  for pump in self.progress {
    pump()
  }
  self.network.pump()
  self.retire_completed()
  self.network.reclaim_completed()
  self.scheduler.stepping = false
  self.gate.val = false
  let mut steps = 0
  while steps < max_steps {
    if !self.step() {
      return Quiescent(steps)
    }
    steps += 1
  }
  if self.scheduler.head == self.scheduler.queue.length() {
    Quiescent(steps)
  } else {
    StepLimit(steps)
  }
}

///|
pub fn Worker::dispose(self : Worker) -> Unit {
  guard !self.scheduler.stepping && !self.gate.val else {
    abort("cannot dispose a running worker")
  }
  if !self.scheduler.active {
    return
  }
  self.scheduler.active = false
  for offset in 0..<self.cleanup.length() {
    self.cleanup[self.cleanup.length() - 1 - offset]()
  }
  self.cleanup.clear()
  self.dataflows.clear()
  self.tasks.clear()
  self.retirement.clear()
  self.progress.clear()
  self.scheduler.queue.clear()
  self.scheduler.slots.clear()
  self.scheduler.timers.clear()
  self.scheduler.head = 0
  self.network.workers -= 1
  if self.network.workers == 0 {
    self.network.domains.clear()
    self.network.links.clear()
    self.network.topology.clear()
  }
}

///|
// The worker keeps a once-only wrapper, not the resource-owning closure, after
// the task finishes. Disposal preserves reverse registration order.
fn Worker::on_task_shutdown(
  self : Worker,
  task : Int32,
  close : () -> Unit,
) -> Unit {
  let pending = Ref(Some(close))
  let finish = fn() {
    if pending.val is Some(close) {
      pending.val = None
      close()
    }
  }
  self.cleanup.push(finish)
  self.scheduler.slots[task].finalizers.push(finish)
}
