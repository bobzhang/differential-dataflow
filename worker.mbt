///|
priv struct Scheduler {
  queue : Array[Int32]
  queued : Array[Bool]
  mut head : Int32
  mut started : Bool
  mut active : Bool
  mut stepping : Bool
}

///|
/// Cooperative worker. Build the graph before executing or sending input.
pub struct Worker {
  priv scheduler : Scheduler
  priv tasks : Array[() -> Unit]
}

///|
pub fn Worker::Worker() -> Worker {
  {
    scheduler: {
      queue: [],
      queued: [],
      head: 0,
      started: false,
      active: true,
      stepping: false,
    },
    tasks: [],
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
  guard !self.scheduler.stepping else { abort("worker step cannot re-enter") }
  self.scheduler.started = true
  if self.scheduler.head >= self.scheduler.queue.length() {
    return false
  }
  let id = self.scheduler.queue[self.scheduler.head]
  self.scheduler.head += 1
  self.scheduler.queued[id] = false
  if self.scheduler.head == self.scheduler.queue.length() {
    self.scheduler.queue.clear()
    self.scheduler.head = 0
  }
  self.scheduler.stepping = true
  self.tasks[id]()
  self.scheduler.stepping = false
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
  guard self.scheduler.active && !self.scheduler.stepping else {
    abort("worker is disposed or running")
  }
  self.scheduler.started = true
  guard max_steps >= 0 else { abort("step limit must be nonnegative") }
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
  guard !self.scheduler.stepping else {
    abort("cannot dispose a running worker")
  }
  self.scheduler.active = false
  self.tasks.clear()
  self.scheduler.queue.clear()
  self.scheduler.queued.clear()
  self.scheduler.head = 0
}
