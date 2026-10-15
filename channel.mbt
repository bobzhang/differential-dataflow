///|
priv enum Frame[D, T, R] {
  Data(Array[(D, T, R)])
  Progress(Antichain[T])
}

///|
priv struct Mailbox[D, T, R] {
  frames : Array[Frame[D, T, R]]
  mut task : Int32
  mut counter : (ChangeBatch[(Int32, T)], Int32)?
}

///|
priv struct Channel[D, T, R] {
  scheduler : Scheduler
  subscribers : Array[Mailbox[D, T, R]]
  frontier : Ref[Antichain[T]]
  context : ProgressContext[T]?
  port : Int32
}

///|
fn[D, T : Lattice, R] Channel::data(
  self : Channel[D, T, R],
  updates : Array[(D, T, R)],
) -> Unit {
  guard self.scheduler.active else { abort("worker is disposed") }
  for (_, time, _) in updates {
    guard self.frontier.val.less_equal(time) else {
      abort("update precedes channel frontier")
    }
  }
  if updates.is_empty() {
    return
  }
  self.scheduler.started = true
  for mailbox in self.subscribers {
    if mailbox.counter is Some((pending, port)) {
      for (_, time, _) in updates {
        pending.update((port, time), 1)
      }
    }
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
  if self.context is Some(_) {
    return
  }
  guard self.frontier.val.precedes(frontier) else {
    abort("channel frontier cannot move backward")
  }
  if self.frontier.val.elements == frontier.elements {
    return
  }
  self.scheduler.started = true
  self.frontier.val = Antichain(frontier.elements)
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
  match self.context {
    None => {
      mailbox.frames.push(Progress(Antichain(self.frontier.val.elements)))
      self.scheduler.schedule(mailbox.task)
    }
    Some(context) => {
      let port = (context.add_port)()
      (context.connect)(self.port, port)
      mailbox.counter = Some((context.pending, port))
      let frames = mailbox.frames
      let scheduler = self.scheduler
      let task = mailbox.task
      (context.observe)(port, fn(frontier) {
        frames.push(Progress(frontier))
        scheduler.schedule(task)
      })
    }
  }
}

///|
fn[D, T : Lattice, R] Mailbox::drain(
  self : Mailbox[D, T, R],
) -> Array[Frame[D, T, R]] {
  let frames = self.frames.copy()
  self.frames.clear()
  if self.counter is Some((pending, port)) {
    for frame in frames {
      if frame is Data(updates) {
        for (_, time, _) in updates {
          pending.update((port, time), -1)
        }
      }
    }
  }
  frames
}

///|
fn[D, T : Lattice, R] Channel::Channel(
  scheduler : Scheduler,
  frontier : Antichain[T],
  context? : ProgressContext[T],
) -> Channel[D, T, R] {
  let frontier = Ref(Antichain(frontier.elements))
  let port = match context {
    None => -1
    Some(context) => {
      let port = (context.add_port)()
      (context.observe)(port, fn(next) { frontier.val = next })
      port
    }
  }
  { scheduler, subscribers: [], frontier, context, port, }
}

///|
fn[D, T, R] Mailbox::Mailbox() -> Mailbox[D, T, R] {
  { frames: [], task: -1, counter: None, }
}

///|
fn[D, E, T : Lattice, R, S] Channel::output(
  self : Channel[D, T, R],
  frontier? : Antichain[T],
) -> Channel[E, T, S] {
  Channel(
    self.scheduler,
    frontier.unwrap_or(self.frontier.val),
    context?=self.context,
  )
}

///|
fn[D, E, T, R, S] Channel::depends_on(
  self : Channel[D, T, R],
  input : Mailbox[E, T, S],
) -> Unit {
  if self.context is Some(context) && input.counter is Some((_, port)) {
    (context.connect)(port, self.port)
  }
}

///|
fn[D, T : Lattice, R] Channel::hold(
  self : Channel[D, T, R],
  time : T,
  diff : Int64,
) -> Unit {
  if self.scheduler.active && self.context is Some(context) {
    context.pending.update((self.port, time), diff)
  }
}
