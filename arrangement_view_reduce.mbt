///|
/// Reduce directly from a shared arrangement. Input history stays in the shared
/// index; per-key state retains only output history and unfinished corrections.
/// Logic is recomputed only for changed keys, and its input is a copied snapshot.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Abelian,
] ArrangementView::reduce(
  self : ArrangementView[K, V, T, R],
  logic : (K, Array[(V, R)]) -> Array[(W, S)],
) -> Collection[(K, W), T, S] {
  let reader = self.trace.clone()
  let output : Channel[(K, W), T, S] = self.collection.channel.output()
  let input : Mailbox[(K, V), T, R] = Mailbox()
  let states : Map[K, Reduction[V, W, T, R, S]] = Map([])
  let held : Ref[Array[T]] = Ref([])
  input.task = self.collection.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          for ((key, _), time, _) in updates {
            let state = states
              .get(key)
              .unwrap_or_else(fn() {
                let state = Reduction()
                state.since = Some(reader.logical_compaction())
                state
              })
            state.dirty = true
            states[key] = state
            output.hold(time, 1)
            held.val.push(time)
          }
        Progress(frontier) => {
          let results = []
          let next_held = []
          let empty_keys = []
          for key, state in states {
            if state.dirty {
              let history = []
              for batch in reader.batches_through(Antichain([])).unwrap() {
                batch.for_key(key, fn(value, time, diff) {
                  let time = match state.since {
                    None => time
                    Some(since) => advance_by(time, since)
                  }
                  history.push((value, time, diff))
                })
              }
              state.history = consolidate_updates(history)
            }
            let (ready, pending) = state.advance(frontier, fn(values) {
              logic(key, values)
            })
            for (value, time, diff) in ready {
              results.push(((key, value), time, diff))
            }
            for time in pending {
              next_held.push(time)
            }
            // The shared index is the only persistent copy of input history.
            state.history.clear()
            if state.emitted.is_empty() && state.corrections.is_empty() {
              empty_keys.push(key)
            }
          }
          for key in empty_keys {
            states.remove(key)
          }
          output.data(results)
          for time in next_held {
            output.hold(time, 1)
          }
          for time in held.val {
            output.hold(time, -1)
          }
          held.val = next_held
          output.progress(frontier)
          reader.set_logical_compaction(
            reader.logical_compaction().join(frontier),
          )
          reader.set_physical_compaction(reader.upper())
          if frontier.is_empty() {
            states.clear()
            reader.release()
          }
        }
      }
    }
  })
  self.collection.channel.subscribe(input)
  output.depends_on(input)
  self.collection.worker.on_task_shutdown(input.task, fn() {
    reader.release()
    states.clear()
    held.val.clear()
  })
  { worker: self.collection.worker, channel: output, }
}

///|
/// Retain the reduced output as a shared index for downstream joins or reductions.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Abelian,
] ArrangementView::reduce_arranged(
  self : ArrangementView[K, V, T, R],
  logic : (K, Array[(V, R)]) -> Array[(W, S)],
) -> Arranged[K, W, T, S] {
  self.reduce(logic).arrange_by_key()
}
