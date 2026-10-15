///|
fn[A, B, T, R, S] same_worker(
  left : Collection[A, T, R],
  right : Collection[B, T, S],
) -> Unit {
  guard physical_equal(left.worker, right.worker) else {
    abort("collections belong to different workers")
  }
}

///|
pub fn[D, T : Lattice, R] Collection::concat(
  self : Collection[D, T, R],
  other : Collection[D, T, R],
) -> Collection[D, T, R] {
  same_worker(self, other)
  let left_frontier = Ref(Antichain(self.channel.frontier.elements))
  let right_frontier = Ref(Antichain(other.channel.frontier.elements))
  let output : Channel[D, T, R] = {
    scheduler: self.worker.scheduler,
    subscribers: [],
    frontier: Antichain(
      left_frontier.val.elements + right_frontier.val.elements,
    ),
  }
  let left : Mailbox[D, T, R] = { frames: [], task: -1, }
  let right : Mailbox[D, T, R] = { frames: [], task: -1, }
  let task = self.worker.register(fn() {
    for frame in left.drain() {
      match frame {
        Data(updates) => output.data(updates)
        Progress(frontier) => left_frontier.val = frontier
      }
    }
    for frame in right.drain() {
      match frame {
        Data(updates) => output.data(updates)
        Progress(frontier) => right_frontier.val = frontier
      }
    }
    output.progress(
      Antichain(left_frontier.val.elements + right_frontier.val.elements),
    )
  })
  left.task = task
  right.task = task
  self.channel.subscribe(left)
  other.channel.subscribe(right)
  { worker: self.worker, channel: output, }
}

///|
/// Incremental weighted equijoin; timestamps combine with lattice join.
/// Multiplication may map two different weight types to a third type.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  D,
  T : Lattice,
  R : Semigroup,
  S : Semigroup,
  O,
] Collection::join_map(
  self : Collection[(K, V), T, R],
  other : Collection[(K, W), T, S],
  logic : (K, V, W) -> D,
  multiply~ : (R, S) -> O,
) -> Collection[D, T, O] {
  same_worker(self, other)
  let left_frontier = Ref(Antichain(self.channel.frontier.elements))
  let right_frontier = Ref(Antichain(other.channel.frontier.elements))
  let output : Channel[D, T, O] = {
    scheduler: self.worker.scheduler,
    subscribers: [],
    frontier: Antichain(
      left_frontier.val.elements + right_frontier.val.elements,
    ),
  }
  let left : Mailbox[(K, V), T, R] = { frames: [], task: -1, }
  let right : Mailbox[(K, W), T, S] = { frames: [], task: -1, }
  let left_state : Map[K, Array[(V, T, R)]] = Map([])
  let right_state : Map[K, Array[(W, T, S)]] = Map([])
  let task = self.worker.register(fn() {
    for frame in left.drain() {
      match frame {
        Data(updates) => {
          let results = []
          for ((key, value), time, diff) in updates {
            if right_state.get(key) is Some(history) {
              for (w, at, weight) in history {
                results.push(
                  (logic(key, value, w), time.join(at), multiply(diff, weight)),
                )
              }
            }
            let history = left_state.get(key).unwrap_or([]).copy()
            history.push((value, time, diff))
            let compact = consolidate_updates(history)
            if compact.is_empty() {
              left_state.remove(key)
            } else {
              left_state[key] = compact
            }
          }
          output.data(results)
        }
        Progress(frontier) => left_frontier.val = frontier
      }
    }
    for frame in right.drain() {
      match frame {
        Data(updates) => {
          let results = []
          for ((key, value), time, diff) in updates {
            if left_state.get(key) is Some(history) {
              for (v, at, weight) in history {
                results.push(
                  (logic(key, v, value), time.join(at), multiply(weight, diff)),
                )
              }
            }
            let history = right_state.get(key).unwrap_or([]).copy()
            history.push((value, time, diff))
            let compact = consolidate_updates(history)
            if compact.is_empty() {
              right_state.remove(key)
            } else {
              right_state[key] = compact
            }
          }
          output.data(results)
        }
        Progress(frontier) => right_frontier.val = frontier
      }
    }
    // Compact each history only as far as the opposite input can no longer revisit.
    compact_join_state(left_state, right_frontier.val)
    compact_join_state(right_state, left_frontier.val)
    output.progress(
      Antichain(left_frontier.val.elements + right_frontier.val.elements),
    )
  })
  left.task = task
  right.task = task
  self.channel.subscribe(left)
  other.channel.subscribe(right)
  { worker: self.worker, channel: output, }
}

///|
pub fn[K : Compare + Hash, V : Compare, W : Compare, T : Lattice] Collection::join(
  self : Collection[(K, V), T, Int64],
  other : Collection[(K, W), T, Int64],
) -> Collection[(K, (V, W)), T, Int64] {
  self.join_map(other, fn(k, v, w) { (k, (v, w)) }, multiply=fn(a, b) { a * b })
}

///|
pub fn[K : Compare + Hash, V : Compare, T : Lattice] Collection::semijoin(
  self : Collection[(K, V), T, Int64],
  keys : Collection[K, T, Int64],
) -> Collection[(K, V), T, Int64] {
  self.join_map(keys.map(fn(k) { (k, ()) }), fn(k, v, _) { (k, v) }, multiply=fn(
    a,
    b,
  ) {
    a * b
  })
}

///|
/// Weighted antijoin. For set exclusion the key collection must have weights 0 or 1.
pub fn[K : Compare + Hash, V : Compare, T : Lattice] Collection::antijoin(
  self : Collection[(K, V), T, Int64],
  keys : Collection[K, T, Int64],
) -> Collection[(K, V), T, Int64] {
  self.concat(self.semijoin(keys).negate())
}

///|
fn[K : Eq + Hash, V : Compare, T : Lattice, R : Semigroup] compact_join_state(
  state : Map[K, Array[(V, T, R)]],
  frontier : Antichain[T],
) -> Unit {
  if frontier.is_empty() {
    state.clear()
    return
  }
  let empty = []
  for key, history in state {
    let compact = consolidate_updates(
      history.map(fn(u) { (u.0, advance_by(u.1, frontier), u.2) }),
    )
    if compact.is_empty() {
      empty.push(key)
    } else {
      state[key] = compact
    }
  }
  for key in empty {
    state.remove(key)
  }
}
