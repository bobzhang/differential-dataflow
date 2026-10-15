///|
priv enum Frame[D, T, R] {
  Data(Array[(D, T, R)])
  Progress(Antichain[T])
}

///|
priv struct Mailbox[D, T, R] {
  frames : Array[Frame[D, T, R]]
  mut task : Int32
}

///|
priv struct Channel[D, T, R] {
  scheduler : Scheduler
  subscribers : Array[Mailbox[D, T, R]]
  mut frontier : Antichain[T]
}

///|
fn[D, T : Lattice, R] Channel::data(
  self : Channel[D, T, R],
  updates : Array[(D, T, R)],
) -> Unit {
  guard self.scheduler.active else { abort("worker is disposed") }
  for (_, time, _) in updates {
    guard self.frontier.less_equal(time) else {
      abort("update precedes channel frontier")
    }
  }
  if updates.is_empty() {
    return
  }
  self.scheduler.started = true
  for mailbox in self.subscribers {
    mailbox.frames.push(Data(updates.copy()))
    self.scheduler.schedule(mailbox.task)
  }
}

///|
fn[D, T : Lattice, R] Channel::progress(
  self : Channel[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  guard self.scheduler.active else { abort("worker is disposed") }
  guard self.frontier.precedes(frontier) else {
    abort("channel frontier cannot move backward")
  }
  if self.frontier.elements == frontier.elements {
    return
  }
  self.scheduler.started = true
  self.frontier = Antichain(frontier.elements)
  for mailbox in self.subscribers {
    mailbox.frames.push(Progress(Antichain(frontier.elements)))
    self.scheduler.schedule(mailbox.task)
  }
}

///|
fn[D, T : Lattice, R] Channel::subscribe(
  self : Channel[D, T, R],
  mailbox : Mailbox[D, T, R],
) -> Unit {
  self.subscribers.push(mailbox)
  mailbox.frames.push(Progress(Antichain(self.frontier.elements)))
  self.scheduler.schedule(mailbox.task)
}

///|
fn[D, T, R] Mailbox::drain(self : Mailbox[D, T, R]) -> Array[Frame[D, T, R]] {
  let frames = self.frames.copy()
  self.frames.clear()
  frames
}
