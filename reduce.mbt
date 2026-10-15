///|
/// Reference implementation over the finite join-closure of input timestamps.
fn[V : Compare, W : Compare, T : Lattice, R : Semigroup, S : Abelian] reduce_history(
  history : Array[(V, T, R)],
  logic : (Array[(V, R)]) -> Array[(W, S)],
) -> Array[(W, T, S)] {
  let times : Array[T] = []
  for (_, time, _) in history {
    if !times.contains(time) {
      times.push(time)
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
    let input = []
    for (value, at, diff) in history {
      if at.less_equal(time) {
        input.push((value, diff))
      }
    }
    let input = consolidate(input)
    let desired = if input.is_empty() { [] } else { logic(input).copy() }
    for (value, at, diff) in result {
      if at.less_equal(time) {
        desired.push((value, diff.negate()))
      }
    }
    for (value, diff) in consolidate(desired) {
      result.push((value, time, diff))
    }
  }
  result
}

///|
priv struct Reduction[V, W, T, R, S] {
  mut history : Array[(V, T, R)]
  mut emitted : Array[(W, T, S)]
}

///|
fn[V, W, T, R, S] Reduction::Reduction() -> Reduction[V, W, T, R, S] {
  { history: [], emitted: [], }
}

///|
fn[V : Compare, W, T : Lattice, R : Semigroup, S] Reduction::update(
  self : Reduction[V, W, T, R, S],
  value : V,
  time : T,
  diff : R,
) -> Unit {
  self.history.push((value, time, diff))
  self.history = consolidate_updates(self.history)
}

///|
fn[V : Compare, W : Compare, T : Lattice, R : Semigroup, S : Abelian] Reduction::advance(
  self : Reduction[V, W, T, R, S],
  frontier : Antichain[T],
  logic : (Array[(V, R)]) -> Array[(W, S)],
) -> (Array[(W, T, S)], Array[T]) {
  let delta = reduce_history(self.history, logic)
  for (value, time, diff) in self.emitted {
    delta.push((value, time, diff.negate()))
  }
  let ready = []
  let pending = []
  for update in consolidate_updates(delta) {
    if frontier.less_equal(update.1) {
      pending.push(update.1)
    } else {
      ready.push(update)
    }
  }
  self.emitted = consolidate_updates(self.emitted + ready)
  if frontier.elements is [time] {
    // All future input/output queries are >= time. Joining both histories with
    // this singleton preserves their snapshots on that entire future upset.
    // Multiple incomparable frontier elements require a more general tactic.
    self.history = consolidate_updates(
      self.history.map(fn(u) { (u.0, u.1.join(time), u.2) }),
    )
    self.emitted = consolidate_updates(
      self.emitted.map(fn(u) { (u.0, u.1.join(time), u.2) }),
    )
  }
  (ready, pending)
}

///|
/// Pure grouped reduction with partial-order timestamp semantics. Uses the
/// join-closure reference algorithm, compacting history at singleton frontiers.
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
            let (ready, pending) = state.advance(frontier, fn(values) {
              logic(key, values)
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
