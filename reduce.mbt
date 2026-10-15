///|
/// Corrections over the finite join-closure, relative to already emitted output.
/// Restrict recomputation to the retained future region after compaction.
fn[V : Compare, W : Compare, T : Lattice, R : Semigroup, S : Semigroup] reduce_history_core(
  history : Array[(V, T, R)],
  emitted : Array[(W, T, S)],
  since : Antichain[T]?,
  logic : (Array[(V, R)], Array[(W, S)]) -> Array[(W, S)],
) -> Array[(W, T, S)] {
  let times : Array[T] = []
  for (_, time, _) in history {
    if !times.contains(time) {
      times.push(time)
    }
  }
  for (_, time, _) in emitted {
    if !times.contains(time) {
      times.push(time)
    }
  }
  if since is Some(frontier) {
    for time in frontier.elements {
      if !times.contains(time) {
        times.push(time)
      }
    }
  }
  let mut index = 0
  while index < times.length() {
    let length = times.length()
    for j in 0..<length {
      let time = times[index].join(times[j])
      if !times.contains(time) {
        times.push(time)
      }
    }
    index += 1
  }
  times.sort()
  let result : Array[(W, T, S)] = []
  for time in times {
    if since is Some(frontier) && !frontier.less_equal(time) {
      continue
    }
    let input = []
    for (value, at, diff) in history {
      if at.less_equal(time) {
        input.push((value, diff))
      }
    }
    let input = consolidate(input)
    let previous = []
    for (value, at, diff) in emitted + result {
      if at.less_equal(time) {
        previous.push((value, diff))
      }
    }
    let previous = consolidate(previous)
    if input.is_empty() && previous.is_empty() {
      continue
    }
    for (value, diff) in consolidate(logic(input, previous)) {
      result.push((value, time, diff))
    }
  }
  result
}

///|
priv struct Reduction[V, W, T, R, S] {
  mut history : Array[(V, T, R)]
  mut emitted : Array[(W, T, S)]
  mut since : Antichain[T]?
  mut dirty : Bool
  mut corrections : Array[(W, T, S)]
}

///|
fn[V, W, T, R, S] Reduction::Reduction() -> Reduction[V, W, T, R, S] {
  { history: [], emitted: [], since: None, dirty: true, corrections: [], }
}

///|
fn[V : Compare, W, T : Lattice, R : Semigroup, S] Reduction::update(
  self : Reduction[V, W, T, R, S],
  value : V,
  time : T,
  diff : R,
) -> Unit {
  guard self.since is None || self.since.unwrap().less_equal(time) else {
    abort("reduction update precedes compaction")
  }
  self.dirty = true
  self.history.push((value, time, diff))
  self.history = consolidate_updates(self.history)
}

///|
fn[V : Compare, W : Compare, T : Lattice, R : Semigroup, S : Semigroup] Reduction::advance_core(
  self : Reduction[V, W, T, R, S],
  frontier : Antichain[T],
  logic : (Array[(V, R)], Array[(W, S)]) -> Array[(W, S)],
) -> (Array[(W, T, S)], Array[T]) {
  guard self.since is None || self.since.unwrap().precedes(frontier) else {
    abort("reduction frontier cannot move backward")
  }
  let delta = if self.dirty {
    reduce_history_core(self.history, self.emitted, self.since, logic)
  } else {
    self.corrections.copy()
  }
  self.dirty = false
  self.corrections = []
  let ready = []
  let pending = []
  for update in consolidate_updates(delta) {
    if frontier.less_equal(update.1) {
      pending.push(update.1)
      self.corrections.push(update)
    } else {
      ready.push(update)
    }
  }
  self.emitted = consolidate_updates(self.emitted + ready)
  if frontier.is_empty() {
    self.history.clear()
    self.emitted.clear()
  } else {
    // Advance-by preserves every snapshot in the future region of an arbitrary
    // antichain. Recomputing only in that region avoids inventing corrections at
    // compacted historical times outside it.
    self.history = consolidate_updates(
      self.history.map(fn(u) { (u.0, advance_by(u.1, frontier), u.2) }),
    )
    self.emitted = consolidate_updates(
      self.emitted.map(fn(u) { (u.0, advance_by(u.1, frontier), u.2) }),
    )
  }
  self.since = Some(Antichain(frontier.elements))
  (ready, pending)
}

///|
/// Pure grouped reduction with partial-order timestamp semantics. Uses the
/// join-closure algorithm, compacting history at arbitrary antichain frontiers.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Abelian,
] Collection::reduce(
  self : Collection[(K, V), T, R],
  logic : (K, Array[(V, R)]) -> Array[(W, S)],
) -> Collection[(K, W), T, S] {
  self.reduce_core_collection(fn(key, values, previous) {
    let changes = if values.is_empty() { [] } else { logic(key, values).copy() }
    for (value, diff) in previous {
      changes.push((value, diff.negate()))
    }
    changes
  })
}

///|
pub fn[D : Compare + Hash, T : Lattice, R : Semigroup, S : Abelian] Collection::threshold(
  self : Collection[D, T, R],
  logic : (D, R) -> S,
) -> Collection[D, T, S] {
  self
  .map(fn(data) { (data, ()) })
  .reduce(fn(key, values) { [((), logic(key, values[0].1))] })
  .map(fn(pair) { pair.0 })
}

///|
/// Presence at any nonzero accumulated weight, including a negative weight.
pub fn[D : Compare + Hash, T : Lattice, R : Semigroup] Collection::distinct(
  self : Collection[D, T, R],
) -> Collection[D, T, Int64] {
  self.threshold(fn(_, _) { 1L })
}

///|
pub fn[D : Compare + Hash, T : Lattice, R : Semigroup + Compare] Collection::count(
  self : Collection[D, T, R],
) -> Collection[(D, R), T, Int64] {
  self
  .map(fn(data) { (data, ()) })
  .reduce(fn(_, values) { [(values[0].1, 1L)] })
}

///|
/// Compute output changes from the current input and accumulated output snapshots.
/// Both snapshots are sorted, consolidated copies. Either may be empty, but not
/// both. Return changes, not the complete desired output. No negation is required
/// of the output difference type. The callback must be deterministic and satisfy
/// its reduction invariant after applying the returned changes.
/// Output is arranged for downstream reuse, matching upstream reduce_core.
fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Semigroup,
] Collection::reduce_core_collection(
  self : Collection[(K, V), T, R],
  logic : (K, Array[(V, R)], Array[(W, S)]) -> Array[(W, S)],
) -> Collection[(K, W), T, S] {
  let output : Channel[(K, W), T, S] = self.channel.output()
  let input : Mailbox[(K, V), T, R] = Mailbox()
  let states : Map[K, Reduction[V, W, T, R, S]] = Map([])
  let held : Ref[Array[T]] = Ref([])
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          for ((key, value), time, diff) in updates {
            output.hold(time, 1)
            held.val.push(time)
            let state = states.get(key).unwrap_or_else(fn() { Reduction() })
            state.update(value, time, diff)
            states[key] = state
          }
        Progress(frontier) => {
          let results = []
          let next_held = []
          let empty_keys = []
          for key, state in states {
            let (ready, pending) = state.advance_core(frontier, fn(
              values,
              previous,
            ) {
              logic(key, values, previous)
            })
            for (value, time, diff) in ready {
              results.push(((key, value), time, diff))
            }
            for time in pending {
              next_held.push(time)
            }
            if state.history.is_empty() && state.emitted.is_empty() {
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
          if frontier.is_empty() {
            states.clear()
          }
        }
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  { worker: self.worker, channel: output, }
}

///|
/// Compute corrections using input and existing output snapshots. The returned
/// arrangement owns a shared index; release it when no longer needed.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Semigroup,
] Collection::reduce_core(
  self : Collection[(K, V), T, R],
  logic : (K, Array[(V, R)], Array[(W, S)]) -> Array[(W, S)],
) -> Arranged[K, W, T, S] {
  self.reduce_core_collection(logic).arrange_by_key()
}
