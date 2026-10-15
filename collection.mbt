///|
/// A stream of timestamped weighted updates within a worker.
pub struct Collection[D, T, R] {
  priv worker : Worker
  priv channel : Channel[D, T, R]
}

///|
pub fn[D, T : Lattice, R] Worker::input(
  self : Worker,
  initial : T,
) -> (InputSession[D, T, R], Collection[D, T, R]) {
  guard self.scheduler.active && !self.scheduler.started else {
    abort("build graph before running or sending input")
  }
  let channel = Channel(self.scheduler, Antichain([initial]))
  let input = InputSession(initial, deliver=fn(data, frontier) {
    if !data.is_empty() {
      channel.data_at(channel.frontier.val.elements[0], data)
    }
    channel.progress(frontier)
  })
  (input, { worker: self, channel, })
}

///|
pub fn[D, E, T : Lattice, R] Collection::flat_map(
  self : Collection[D, T, R],
  logic : (D) -> Array[E],
) -> Collection[E, T, R] {
  let output : Channel[E, T, R] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) => {
          let result = []
          for (data, time, diff) in updates {
            for value in logic(data) {
              result.push((value, time, diff))
            }
          }
          output.data_at(envelope, result)
        }
        Progress(frontier) => output.progress(frontier)
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  { worker: self.worker, channel: output, }
}

///|
pub fn[D, E, T : Lattice, R] Collection::map(
  self : Collection[D, T, R],
  logic : (D) -> E,
) -> Collection[E, T, R] {
  self.flat_map(fn(data) { [logic(data)] })
}

///|
pub fn[D, T : Lattice, R] Collection::filter(
  self : Collection[D, T, R],
  predicate : (D) -> Bool,
) -> Collection[D, T, R] {
  self.flat_map(fn(data) { if predicate(data) { [data] } else { [] } })
}

///|
pub fn[D, T : Lattice, R : Abelian] Collection::negate(
  self : Collection[D, T, R],
) -> Collection[D, T, R] {
  self.explode(fn(data) { [(data, fn(diff) { diff.negate() })] })
}

///|
/// General weight transformation, including cross-type multiplication.
pub fn[D, E, T : Lattice, R, S] Collection::explode(
  self : Collection[D, T, R],
  logic : (D) -> Array[(E, (R) -> S)],
) -> Collection[E, T, S] {
  let output : Channel[E, T, S] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) => {
          let result = []
          for (data, time, diff) in updates {
            for (value, multiply) in logic(data) {
              result.push((value, time, multiply(diff)))
            }
          }
          output.data_at(envelope, result)
        }
        Progress(frontier) => output.progress(frontier)
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  { worker: self.worker, channel: output, }
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] Collection::consolidate(
  self : Collection[D, T, R],
) -> Collection[D, T, R] {
  let output : Channel[D, T, R] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  let pending : Ref[Array[(D, T, R)]] = Ref([])
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(_, updates) =>
          for update in updates {
            pending.val.push(update)
            output.hold(update.1, 1)
          }
        Progress(frontier) => {
          let ready = []
          let retained = []
          for update in pending.val {
            if frontier.less_equal(update.1) {
              retained.push(update)
            } else {
              ready.push(update)
            }
          }
          pending.val = retained
          output.data(consolidate_updates(ready))
          for (_, time, _) in ready {
            output.hold(time, -1)
          }
          output.progress(frontier)
        }
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  { worker: self.worker, channel: output, }
}

///|
pub struct Probe[T] {
  priv state : Ref[Antichain[T]]
}

///|
pub fn[T : Lattice] Probe::frontier(self : Probe[T]) -> Antichain[T] {
  Antichain(self.state.val.elements)
}

///|
pub fn[T : Lattice] Probe::less_than(self : Probe[T], time : T) -> Bool {
  self.state.val.less_than(time)
}

///|
pub fn[T : Lattice] Probe::less_equal(self : Probe[T], time : T) -> Bool {
  self.state.val.less_equal(time)
}

///|
pub fn[T] Probe::done(self : Probe[T]) -> Bool {
  self.state.val.is_empty()
}

///|
pub fn[D, T : Lattice, R] Collection::inspect(
  self : Collection[D, T, R],
  logic : (D, T, R) -> Unit,
) -> Probe[T] {
  let state = Ref(Antichain(self.channel.frontier.val.elements))
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(_, updates) =>
          for (data, time, diff) in updates {
            logic(data, time, diff)
          }
        Progress(frontier) => state.val = frontier
      }
    }
  })
  self.channel.subscribe(input)
  { state, }
}

///|
pub fn[D, T : Lattice, R] Collection::probe(
  self : Collection[D, T, R],
) -> Probe[T] {
  self.inspect(fn(_, _, _) {  })
}
