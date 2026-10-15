///|
priv enum Frame[D, T, R] {
  Records(T, Array[(D, T, R)])
  Progress(Antichain[T])
}

///|
priv struct Mailbox[D, T, R] {
  frames : Array[Frame[D, T, R]]
  ended : Ref[Bool]
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
fn[D, T : Lattice, R] Channel::data_at(
  self : Channel[D, T, R],
  envelope : T,
  updates : Array[(D, T, R)],
) -> Unit {
  guard self.scheduler.active else { abort("worker is disposed") }
  if self.context is Some(context) && !(context.active)() {
    return
  }
  if updates.is_empty() {
    return
  }
  guard self.frontier.val.less_equal(envelope) else {
    abort("message precedes channel frontier")
  }
  for (_, time, _) in updates {
    guard envelope.less_equal(time) else {
      abort("record precedes message capability")
    }
  }
  if updates.is_empty() {
    return
  }
  self.scheduler.started = true
  if self.context is Some(context) {
    (context.freeze)()
  }
  for mailbox in self.subscribers {
    if mailbox.counter is Some((pending, port)) {
      pending.update((port, envelope), 1)
    }
    mailbox.frames.push(Records(envelope, updates.copy()))
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
  if self.context is Some(context) {
    (context.freeze)()
  }
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
  let frames = mailbox.frames
  let ended = mailbox.ended
  self.scheduler.slots[mailbox.task].input_done.push(fn() {
    ended.val && frames.is_empty()
  })
  match self.context {
    None => {
      guard !self.scheduler.started else { abort("unscoped graph is frozen") }
      mailbox.frames.push(Progress(Antichain(self.frontier.val.elements)))
      self.scheduler.schedule(mailbox.task)
    }
    Some(context) => {
      (context.own_task)(mailbox.task)
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
  for frame in frames {
    if frame is Progress(frontier) {
      self.ended.val = frontier.is_empty()
    }
  }
  if self.counter is Some((pending, port)) {
    for frame in frames {
      if frame is Records(envelope, _) {
        pending.update((port, envelope), -1)
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
    None => {
      guard !scheduler.started else { abort("unscoped graph is frozen") }
      -1
    }
    Some(context) => {
      let port = (context.add_port)()
      (context.observe)(port, fn(next) { frontier.val = next })
      port
    }
  }
  let subscribers : Array[Mailbox[D, T, R]] = []
  if context is Some(context) {
    (context.on_close)(fn() {
      frontier.val = Antichain([])
      for mailbox in subscribers {
        mailbox.frames.clear()
        mailbox.ended.val = true
        mailbox.counter = None
      }
      subscribers.clear()
    })
  }
  { scheduler, subscribers, frontier, context, port, }
}

///|
fn[D, T, R] Mailbox::Mailbox() -> Mailbox[D, T, R] {
  { frames: [], ended: Ref(false), task: -1, counter: None, }
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
  let frontier = self.frontier
  self.scheduler.slots[input.task].output_done.push(fn() {
    frontier.val.is_empty()
  })
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
  if self.scheduler.active &&
    self.context is Some(context) &&
    (context.active)() {
    context.pending.update((self.port, time), diff)
  }
}

///|
// Stateful operators may produce records at incomparable times. Each equal-time
// group gets a real message capability; never synthesize their meet, which might
// precede the output frontier.
fn[D, T : Lattice, R] Channel::data(
  self : Channel[D, T, R],
  updates : Array[(D, T, R)],
) -> Unit {
  let updates = updates.copy()
  updates.sort_by(fn(a, b) { Compare::compare(a.1, b.1) })
  let mut index = 0
  while index < updates.length() {
    let time = updates[index].1
    let records = []
    while index < updates.length() && updates[index].1 == time {
      records.push(updates[index])
      index += 1
    }
    self.data_at(time, records)
  }
}
