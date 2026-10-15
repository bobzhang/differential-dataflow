///|
// Called only after progress publication, while the worker re-entry gate is held.
fn Worker::retire_completed(self : Worker, cancel? : Set[Int32]) -> Unit {
  if self.retirement.is_empty() {
    return
  }
  let retained = []
  let mut changed = false
  for (task, ready, finish) in self.retirement {
    if (cancel is Some(ids) && ids.contains(task)) || ready() {
      let status = self.scheduler.slots[task]
      self.scheduler.slots.remove(task)
      self.tasks.remove(task)
      finish()
      for offset in 0..<status.finalizers.length() {
        status.finalizers[status.finalizers.length() - 1 - offset]()
      }
      status.finalizers.clear()
      status.input_done.clear()
      status.output_done.clear()
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
      if self.scheduler.slots.contains(task) {
        self.scheduler.queue.push(task)
      }
    }
    let timers = self.scheduler.timers.copy()
    self.scheduler.timers.clear()
    for (deadline, slot) in timers {
      if slot.val is None ||
        (slot.val is Some(task) && self.scheduler.slots.contains(task)) {
        self.scheduler.timers.push((deadline, slot))
      }
    }
  }
}
