///|
/// Reorders and deduplicates capture protocol messages. Missing updates keep
/// progress pending even if their progress statements have already arrived.
pub struct Replayer[D, T, R] {
  priv mut updates : Array[(D, T, R)]
  priv mut reported : Antichain[T]
  priv mut progress : Antichain[T]
  priv counts : MutableAntichain[T]
  priv mut statements : Array[CaptureProgress[T]]
}

///|
pub fn[D, T : Lattice, R] Replayer::Replayer(minimum : T) -> Replayer[D, T, R] {
  {
    updates: [],
    reported: Antichain([minimum]),
    progress: Antichain([minimum]),
    counts: MutableAntichain(),
    statements: [],
  }
}

///|
pub fn[D, T : Lattice, R] Replayer::frontier(
  self : Replayer[D, T, R],
) -> Antichain[T] {
  Antichain(self.reported.elements)
}

///|
/// Publish a newly completed interval, if this message makes one available.
/// Duplicate records inside a single update message are also suppressed.
pub fn[D : Compare, T : Lattice, R : Compare] Replayer::push(
  self : Replayer[D, T, R],
  message : CaptureMessage[D, T, R],
) -> (Array[(D, T, R)], Antichain[T])? {
  match message {
    Updates(updates) => {
      let changes = []
      for update in updates {
        if self.reported.less_equal(update.1) && !self.updates.contains(update) {
          self.updates.push(update)
          changes.push((update.1, -1L))
        }
      }
      let _ = self.counts.update_all(changes)
    }
    Progress(progress) => self.statements.push(progress)
  }
  while self.next_statement() is Some(statement) {
    let _ = self.counts.update_all(
      statement.counts.filter(fn(entry) { self.progress.less_equal(entry.0) }),
    )
    self.progress = self.progress.join(statement.upper)
    self.statements = self.statements.filter(fn(statement) {
      !statement.upper.precedes(self.progress)
    })
  }
  let frontier = Antichain(
    self.progress.elements + self.counts.frontier().elements,
  )
  if frontier.elements == self.reported.elements {
    return None
  }
  let ready = self.updates.filter(fn(update) { !frontier.less_equal(update.1) })
  self.updates = self.updates.filter(fn(update) {
    frontier.less_equal(update.1)
  })
  self.reported = frontier
  ready.sort()
  Some((ready, self.frontier()))
}

///|
pub struct ReplayInput[D, T, R] {
  priv replayer : Replayer[D, T, R]
  priv output : Channel[D, T, R]
  priv mut closed : Bool
}

///|
pub fn[D, T : Lattice, R, S] Scope::replay(
  self : Scope[T, S],
) -> (ReplayInput[D, T, R], Collection[D, T, R]) {
  let output = Channel(
    self.worker.scheduler,
    Antichain([self.minimum]),
    context=self.context,
  )
  output.hold(self.minimum, 1)
  (
    { replayer: Replayer(self.minimum), output, closed: false, },
    { worker: self.worker, channel: output, },
  )
}

///|
pub fn[D : Compare, T : Lattice, R : Compare] ReplayInput::push(
  self : ReplayInput[D, T, R],
  message : CaptureMessage[D, T, R],
) -> Unit {
  guard !self.closed && self.output.scheduler.active else {
    abort("replay input is closed or disposed")
  }
  self.output.scheduler.started = true
  let previous = self.replayer.frontier()
  if self.replayer.push(message) is Some((updates, frontier)) {
    self.output.data(updates)
    for time in frontier.elements {
      self.output.hold(time, 1)
    }
    for time in previous.elements {
      self.output.hold(time, -1)
    }
  }
}

///|
/// Cancel replay and discard incomplete intervals. Normal completion is signaled
/// by a fully satisfied terminal progress message, not by calling cancel.
pub fn[D, T : Lattice, R] ReplayInput::cancel(
  self : ReplayInput[D, T, R],
) -> Unit {
  if !self.closed {
    for time in self.replayer.reported.elements {
      self.output.hold(time, -1)
    }
    self.replayer.reported = Antichain([])
    self.replayer.updates.clear()
    self.replayer.statements.clear()
    self.replayer.counts.clear()
    self.closed = true
  }
}

///|
fn[D, T : Lattice, R] Replayer::next_statement(
  self : Replayer[D, T, R],
) -> CaptureProgress[T]? {
  for statement in self.statements {
    if statement.lower.precedes(self.progress) {
      return Some(statement)
    }
  }
  None
}
