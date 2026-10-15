///|
priv struct Scheduler {
  queue : Array[Int32]
  queued : Array[Bool]
  mut head : Int32
  mut started : Bool
  mut active : Bool
  mut stepping : Bool
  clock : (() -> Duration)?
  mut last_time : Duration
  timers : Array[(Duration, Ref[Int32?])]
}

///|
/// Cooperative worker. Build the graph before executing or sending input.
pub struct Worker {
  priv network : ProgressNetwork
  priv gate : Ref[Bool]
  priv scheduler : Scheduler
  priv tasks : Array[() -> Unit]
  priv progress : Array[() -> Unit]
  priv cleanup : Array[() -> Unit]
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
      queued: [],
      head: 0,
      started: false,
      active: true,
      stepping: false,
      clock,
      last_time: Duration(0UL),
      timers: [],
    },
    tasks: [],
    progress: [],
    cleanup: [],
  }
}

///|
fn Scheduler::schedule(self : Scheduler, id : Int32) -> Unit {
  guard self.active else { abort("worker is disposed") }
  if !self.queued[id] {
    self.queued[id] = true
    self.queue.push(id)
  }
}

///|
fn Worker::register(self : Worker, task : () -> Unit) -> Int32 {
  guard self.scheduler.active && !self.scheduler.started else {
    abort("build graph before running or sending input")
  }
  let id = self.tasks.length()
  self.tasks.push(task)
  self.scheduler.queued.push(false)
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
  if self.scheduler.head >= self.scheduler.queue.length() {
    self.scheduler.stepping = false
    self.gate.val = false
    return false
  }
  let id = self.scheduler.queue[self.scheduler.head]
  self.scheduler.head += 1
  self.scheduler.queued[id] = false
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
  self.tasks.clear()
  self.progress.clear()
  self.scheduler.queue.clear()
  self.scheduler.queued.clear()
  self.scheduler.timers.clear()
  self.scheduler.head = 0
  self.network.workers -= 1
  if self.network.workers == 0 {
    self.network.domains.clear()
    self.network.links.clear()
    self.network.topology.clear()
  }
}
