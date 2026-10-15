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
/// Pure grouped reduction with partial-order timestamp semantics.
/// Currently uses the reference join-closure algorithm and retains open-input history.
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
  let output : Channel[(K, W), T, S] = {
    scheduler: self.worker.scheduler,
    subscribers: [],
    frontier: Antichain(self.channel.frontier.elements),
  }
  let input : Mailbox[(K, V), T, R] = { frames: [], task: -1, }
  let histories : Map[K, Array[(V, T, R)]] = Map([])
  let emitted : Map[K, Array[(W, T, S)]] = Map([])
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          for ((key, value), time, diff) in updates {
            let history = histories.get(key).unwrap_or([]).copy()
            history.push((value, time, diff))
            histories[key] = consolidate_updates(history)
          }
        Progress(frontier) => {
          let results = []
          for key, history in histories {
            let ready = reduce_history(history, fn(values) {
              logic(key, values)
            }).filter(fn(u) { !frontier.less_equal(u.1) })
            let delta = ready.copy()
            for (value, time, diff) in emitted.get(key).unwrap_or([]) {
              delta.push((value, time, diff.negate()))
            }
            for (value, time, diff) in consolidate_updates(delta) {
              results.push(((key, value), time, diff))
            }
            emitted[key] = ready
          }
          output.data(results)
          output.progress(frontier)
          if frontier.is_empty() {
            histories.clear()
            emitted.clear()
          }
        }
      }
    }
  })
  self.channel.subscribe(input)
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
