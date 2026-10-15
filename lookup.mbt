///|
/// Read a key at a completed timestamp, subject to this reader's logical frontier.
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] TraceAgent::lookup_at(
  self : TraceAgent[(K, V), T, R],
  key : K,
  time : T,
) -> Array[(V, R)] {
  self
  .snapshot(time)
  .filter_map(fn(entry) {
    if entry.0.0 == key {
      Some((entry.0.1, entry.1))
    } else {
      None
    }
  })
}

///|
/// Answer timestamped key queries after the trace seals the requested time.
/// Query data is (key, snapshot_time); results retain the query's stream timestamp.
/// The reader pins historical data until queries finish or their worker is disposed.
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup, Q, O] TraceAgent::lookup(
  self : TraceAgent[(K, V), T, R],
  queries : Collection[(K, T), T, Q],
  multiply~ : (R, Q) -> O,
) -> Collection[(K, V), T, O] {
  self.check()
  let reader = self.clone()
  let shared = reader.shared
  let listener = shared.next_listener
  shared.next_listener += 1
  let output : Channel[(K, V), T, O] = queries.channel.output()
  let input : Mailbox[(K, T), T, Q] = Mailbox()
  let pending : Ref[Array[((K, T), T, Q)]] = Ref([])
  let frontier = Ref(Antichain(queries.channel.frontier.val.elements))
  let finished = Ref(false)
  let cleanup = fn() {
    if !finished.val {
      finished.val = true
      shared.listeners.remove(listener)
      for (_, time, _) in pending.val {
        output.hold(time, -1)
      }
      pending.val.clear()
      reader.release()
    }
  }
  input.task = queries.worker.register(fn() {
    if finished.val {
      return
    }
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          for update in updates {
            guard reader.logical_compaction().less_equal(update.0.1) else {
              abort("lookup query precedes retained history")
            }
            pending.val.push(update)
            output.hold(update.1, 1)
          }
        Progress(next) => frontier.val = next
      }
    }
    let ready = []
    let retained = []
    for ((key, query), time, weight) in pending.val {
      if reader.upper().less_equal(query) {
        retained.push(((key, query), time, weight))
      } else {
        for (value, diff) in reader.lookup_at(key, query) {
          ready.push(((key, value), time, multiply(diff, weight)))
        }
        output.hold(time, -1)
      }
    }
    pending.val = retained
    output.data(ready)
    output.progress(
      Antichain(frontier.val.elements + retained.map(fn(query) { query.1 })),
    )
    if frontier.val.is_empty() && retained.is_empty() {
      cleanup()
    }
  })
  queries.channel.subscribe(input)
  output.depends_on(input)
  let scheduler = queries.worker.scheduler
  let task = input.task
  shared.listeners[listener] = fn(_) { scheduler.schedule(task) }
  queries.worker.cleanup.push(cleanup)
  { worker: queries.worker, channel: output, }
}
