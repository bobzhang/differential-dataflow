///|
// Called only after progress publication, while the worker re-entry gate is held.
fn Worker::retire_completed(self : Worker) -> Unit {
  if self.retirement.is_empty() {
    return
  }
  let retained = []
  let mut changed = false
  for (task, ready, finish) in self.retirement {
    if ready() {
      self.scheduler.live[task] = false
      self.scheduler.queued[task] = false
      self.tasks[task] = None
      finish()
      changed = true
    } else {
      retained.push((task, ready, finish))
    }
  }
  self.retirement.clear()
  for entry in retained {
    self.retirement.push(entry)
  }
  if changed {
    let queued = self.scheduler.queue[self.scheduler.head:].to_owned()
    self.scheduler.queue.clear()
    self.scheduler.head = 0
    for task in queued {
      if self.scheduler.live[task] {
        self.scheduler.queue.push(task)
      }
    }
    let timers = self.scheduler.timers.copy()
    self.scheduler.timers.clear()
    for (deadline, slot) in timers {
      if slot.val is None ||
        (slot.val is Some(task) && self.scheduler.live[task]) {
        self.scheduler.timers.push((deadline, slot))
      }
    }
  }
}
