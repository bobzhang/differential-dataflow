///|
/// Data messages retain their capability timestamp separately from the logical
/// timestamp in each update. Frontiers describe future message capabilities.
pub(all) enum CollectionEvent[D, T, R] {
  Records(T, Array[(D, T, R)])
  Frontier(Antichain[T])
}

///|
/// Observe copied message containers and progress while forwarding the stream.
pub fn[D, T : Lattice, R] Collection::inspect_container(
  self : Collection[D, T, R],
  logic : (CollectionEvent[D, T, R]) -> Unit,
) -> Collection[D, T, R] {
  let output : Channel[D, T, R] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) => {
          logic(Records(envelope, updates.copy()))
          output.data_at(envelope, updates)
        }
        Progress(frontier) => {
          logic(Frontier(Antichain(frontier.elements)))
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
/// Observe each batch at its message capability time. Individual updates can have
/// later logical times. Container boundaries may vary between execution backends.
pub fn[D, T : Lattice, R] Collection::inspect_batch(
  self : Collection[D, T, R],
  logic : (T, Array[(D, T, R)]) -> Unit,
) -> Collection[D, T, R] {
  self.inspect_container(fn(event) {
    if event is Records(time, updates) {
      logic(time, updates)
    }
  })
}

///|
/// Consolidate each message independently without waiting for progress. Unlike
/// consolidate, cancellations arriving in different messages may remain separate.
pub fn[D : Compare, T : Lattice, R : Semigroup] Collection::consolidate_stream(
  self : Collection[D, T, R],
) -> Collection[D, T, R] {
  let output : Channel[D, T, R] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) =>
          output.data_at(envelope, consolidate_updates(updates))
        Progress(frontier) => output.progress(frontier)
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  { worker: self.worker, channel: output, }
}

///|
/// Advance logical record times by a summary, retaining the message capability.
/// Overflowed record timestamps are discarded. As upstream, results must still
/// lie at or beyond the enclosing message capability.
pub fn[D, T : Lattice, R, S] Collection::results_in(
  self : Collection[D, T, R],
  step : S,
  domain : SummaryDomain[T, S],
) -> Collection[D, T, R] {
  let output : Channel[D, T, R] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) => {
          let result = []
          for (data, time, diff) in updates {
            if domain.results_in(step, time) is Some(time) {
              result.push((data, time, diff))
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
/// Delay message capabilities and record timestamps with a pure, monotone,
/// nondecreasing function. Messages are held until the input frontier passes
/// their delayed capability, matching Timely's notification-based delay_batch.
pub fn[D, T : Lattice, R] Collection::delay(
  self : Collection[D, T, R],
  advance : (T) -> T,
) -> Collection[D, T, R] {
  let output : Channel[D, T, R] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  let pending : Ref[Array[(T, Array[(D, T, R)])]] = Ref([])
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) => {
          let delayed = advance(envelope)
          guard envelope.less_equal(delayed) else {
            abort("delay cannot move a capability backward")
          }
          let records = updates.map(fn(update) {
            let time = advance(update.1)
            guard update.1.less_equal(time) && delayed.less_equal(time) else {
              abort("delay function must advance timestamps monotonically")
            }
            (update.0, time, update.2)
          })
          output.hold(delayed, 1)
          pending.val.push((delayed, records))
        }
        Progress(frontier) => {
          let retained = []
          for (envelope, records) in pending.val {
            if frontier.less_equal(envelope) {
              retained.push((envelope, records))
            } else {
              output.data_at(envelope, records)
              output.hold(envelope, -1)
            }
          }
          pending.val = retained
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
/// Join each input update with a computed set of weighted, timestamped rows.
/// Timestamps join in the lattice; multiplication receives computed weight first,
/// then the input weight, as in upstream join_function.
pub fn[D, E, T : Lattice, R, S, O] Collection::join_function(
  self : Collection[D, T, R],
  logic : (D) -> Array[(E, T, S)],
  multiply~ : (S, R) -> O,
) -> Collection[E, T, O] {
  let output : Channel[E, T, O] = self.channel.output()
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(envelope, updates) => {
          let result = []
          for (data, time, diff) in updates {
            for (value, at, weight) in logic(data) {
              result.push((value, time.join(at), multiply(weight, diff)))
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
