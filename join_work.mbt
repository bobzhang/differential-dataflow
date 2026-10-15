///|
priv struct JoinWork[D, T, R] {
  lower : Antichain[T]
  step : () -> ((D, T, R)?, Bool)
}

///|
// One bounded unit either advances a cursor or emits one pair. Immutable views
// keep historical cuts valid if the shared trace compacts between activations.
fn[K : Compare, V, W, D, T : Lattice, R, S, O] join_work(
  delta : BatchView[(K, V), T, R],
  lower : Antichain[T],
  history : Array[BatchView[(K, W), T, S]],
  logic : (K, V, W) -> D,
  multiply : (R, S) -> O,
) -> JoinWork[D, T, O] {
  let mut row = 0
  let mut previous = 0
  let mut index = -1
  let current : Ref[((K, V), T, R)?] = Ref(None)
  {
    lower,
    step: fn() {
      guard current.val is Some(((key, value), time, diff)) else {
        if row == delta.size {
          return (None, true)
        }
        current.val = delta.get(row)
        row += 1
        previous = 0
        index = -1
        return (None, false)
      }
      if previous == history.length() {
        current.val = None
        return (None, false)
      }
      let batch = history[previous]
      if index < 0 {
        let mut lo = 0
        let mut hi = batch.size
        while lo < hi {
          let mid = lo + (hi - lo) / 2
          if Compare::compare((batch.read)(mid).0.0, key) < 0 {
            lo = mid + 1
          } else {
            hi = mid
          }
        }
        index = lo
        return (None, false)
      }
      if index == batch.size || (batch.read)(index).0.0 != key {
        previous += 1
        index = -1
        return (None, false)
      }
      let next = batch.get(index)
      index += 1
      match next {
        Some(((_, other), at, weight)) =>
          (
            Some(
              (logic(key, value, other), time.join(at), multiply(diff, weight)),
            ),
            false,
          )
        None => (None, false)
      }
    },
  }
}
