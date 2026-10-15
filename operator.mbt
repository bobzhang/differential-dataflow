///|
/// Output port whose records require a live capability for this exact port.
pub struct Output[D, T, R, S] {
  priv channel : Channel[D, T, R]
  priv owner : CapabilityOwner[T, S]
}

///|
pub fn[D, T, R, S] Output::accepts(
  self : Output[D, T, R, S],
  capability : Capability[T, S],
) -> Bool {
  self.channel.scheduler.active &&
  capability.live &&
  capability.owner.active() &&
  capability.port == self.channel.port &&
  capability.owner.same(self.owner)
}

///|
pub fn[D, T : Lattice, R, S] Output::send(
  self : Output[D, T, R, S],
  capability : Capability[T, S],
  records : Array[(D, R)],
) -> Unit {
  guard self.accepts(capability) else {
    abort("output requires a live capability for its port")
  }
  self.channel.data(
    records.map(fn(record) { (record.0, capability.time, record.1) }),
  )
}

///|
/// Each record's timestamp must be at or beyond the supplied capability.
pub fn[D, T : Lattice, R, S] Output::send_at(
  self : Output[D, T, R, S],
  capability : Capability[T, S],
  records : Array[(D, T, R)],
) -> Unit {
  guard self.accepts(capability) else {
    abort("output requires a live capability for its port")
  }
  for (_, time, _) in records {
    guard capability.time.less_equal(time) else {
      abort("record precedes capability")
    }
  }
  self.channel.data(records)
}

///|
/// Create a manually driven source. Release every cloned capability to finish it.
pub fn[D, T : Lattice, R, S] Scope::source(
  self : Scope[T, S],
) -> (Output[D, T, R, S], Capability[T, S], Collection[D, T, R]) {
  let channel : Channel[D, T, R] = Channel(
    self.worker.scheduler,
    Antichain([self.minimum]),
    context=self.context,
  )
  let owner = Scoped(self.progress)
  let capability = owner.capability(channel.port, self.minimum)
  ({ channel, owner, }, capability, { worker: self.worker, channel, })
}

///|
/// Data capabilities are borrowed for the callback: clone one to retain it.
/// Progress describes the input frontier, excluding the output's held capabilities.
pub(all) enum OperatorEvent[D, T, R, S] {
  Data(Capability[T, S], Array[(D, R)])
  Progress(Antichain[T])
}

///|
/// Build a frontier-aware unary operator with identity timestamp connectivity.
/// The builder receives an initial owned capability; release it when no longer needed.
/// Data callbacks receive a borrowed capability valid for the output port.
pub fn[D, E, T : Lattice, R, U, S] Scope::unary(
  self : Scope[T, S],
  source : Collection[D, T, R],
  build : (Output[E, T, U, S], Capability[T, S]) -> (OperatorEvent[D, T, R, S]) -> Unit,
) -> Collection[E, T, U] {
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.context) else {
    abort("operator input belongs to a different scope")
  }
  let (output, initial, collection) = self.source()
  let handle = build(output, initial)
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) => {
          updates.sort_by(fn(a, b) { Compare::compare(a.1, b.1) })
          let mut start = 0
          while start < updates.length() {
            let time = updates[start].1
            let records = []
            let mut end = start
            while end < updates.length() && updates[end].1 == time {
              records.push((updates[end].0, updates[end].2))
              end += 1
            }
            let capability = output.owner.capability(output.channel.port, time)
            handle(Data(capability, records))
            capability.release()
            start = end
          }
        }
        Progress(frontier) => handle(Progress(frontier))
      }
    }
  })
  source.channel.subscribe(input)
  output.channel.depends_on(input)
  collection
}
