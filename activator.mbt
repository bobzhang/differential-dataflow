///|
/// A cloneable local activation handle. It retains the scheduler, not the worker
/// or operator closure. Activations are coalesced until the operator runs.
pub struct Activator {
  priv scheduler : Scheduler
  priv slot : Ref[Int32?]
}

///|
pub fn[T, S] OperatorBuilder::activator(
  self : OperatorBuilder[T, S],
) -> Activator {
  { scheduler: self.scope.worker.scheduler, slot: self.activation_slot, }
}

///|
pub fn Activator::clone(self : Activator) -> Activator {
  { scheduler: self.scheduler, slot: self.slot, }
}

///|
/// Queue a wakeup. A handle retained after worker disposal becomes inert.
pub fn Activator::activate(self : Activator) -> Unit {
  let _ = self.try_activate()
}

///|
pub fn Activator::try_activate(self : Activator) -> Bool {
  if !self.scheduler.active {
    return false
  }
  if self.slot.val is Some(task) {
    self.scheduler.schedule(task)
  }
  true
}

///|
/// Queue a timed wakeup using the worker's supplied monotonic clock. A zero
/// delay is an ordinary activation. The host drives step/run and can use
/// next_activation to decide when to call again; no backend-specific sleep runs.
pub fn Activator::activate_after(self : Activator, delay : Duration) -> Unit {
  if !self.scheduler.active {
    return
  }
  if delay == Duration(0UL) {
    self.activate()
    return
  }
  let now = self.scheduler.read_clock()
  let deadline = now
    .checked_add(delay)
    .unwrap_or_else(fn() { abort("activation deadline overflow") })
  self.scheduler.timers.push((deadline, self.slot))
}

///|
fn Scheduler::read_clock(self : Scheduler) -> Duration {
  guard self.clock is Some(clock) else {
    abort("timed activation requires Worker(clock=...) with a monotonic clock")
  }
  let now = clock()
  guard self.last_time <= now else { abort("worker clock moved backward") }
  self.last_time = now
  now
}

///|
fn Scheduler::poll_timers(self : Scheduler) -> Unit {
  if self.timers.is_empty() {
    return
  }
  let now = self.read_clock()
  let pending = self.timers.copy()
  self.timers.clear()
  for (deadline, slot) in pending {
    if deadline <= now {
      if slot.val is Some(task) {
        self.schedule(task)
      }
    } else {
      self.timers.push((deadline, slot))
    }
  }
}

///|
/// Time until runnable work or the earliest timer; None means no queued wakeup.
/// A nonempty capability frontier alone does not imply a queued activation.
pub fn Worker::next_activation(self : Worker) -> Duration? {
  if !self.scheduler.active {
    return None
  }
  if self.scheduler.head < self.scheduler.queue.length() {
    return Some(Duration(0UL))
  }
  if self.scheduler.timers.is_empty() {
    return None
  }
  let now = self.scheduler.read_clock()
  let mut first = self.scheduler.timers[0].0
  for (deadline, _) in self.scheduler.timers {
    if deadline < first {
      first = deadline
    }
  }
  if first <= now {
    return Some(Duration(0UL))
  }
  let borrow = if first.nanos < now.nanos { 1UL } else { 0UL }
  let nanos = if borrow == 0UL {
    first.nanos - now.nanos
  } else {
    first.nanos + 1000000000U - now.nanos
  }
  Some(Duration(first.seconds - now.seconds - borrow, nanoseconds=nanos))
}

///|
pub fn WorkerGroup::next_activation(self : WorkerGroup) -> Duration? {
  let mut first : Duration? = None
  for worker in self.workers {
    if worker.next_activation() is Some(delay) &&
      (first is None || (first is Some(current) && delay < current)) {
      first = Some(delay)
    }
  }
  first
}
