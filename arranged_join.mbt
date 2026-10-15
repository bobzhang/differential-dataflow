///|
/// Visit a key's contiguous range in the immutable sorted batch. This searches
/// shared storage without materializing a cursor or copying unrelated keys.
pub fn[K : Compare, V, T, R] Batch::for_key(
  self : Batch[(K, V), T, R],
  key : K,
  visit : (V, T, R) -> Unit,
) -> Unit {
  let mut lower = 0
  let mut upper = self.updates.length()
  while lower < upper {
    let middle = lower + (upper - lower) / 2
    if Compare::compare(self.updates[middle].0.0, key) < 0 {
      lower = middle + 1
    } else {
      upper = middle
    }
  }
  while lower < self.updates.length() && self.updates[lower].0.0 == key {
    let ((_, value), time, diff) = self.updates[lower]
    visit(value, time, diff)
    lower += 1
  }
}

///|
/// Join arrangements through independent readers of shared batch indexes.
pub fn[
  K : Compare,
  V : Compare,
  W : Compare,
  D,
  T : Lattice,
  R : Semigroup,
  S : Semigroup,
  O,
] Arranged::join_map(
  self : Arranged[K, V, T, R],
  other : Arranged[K, W, T, S],
  logic : (K, V, W) -> D,
  multiply~ : (R, S) -> O,
) -> Collection[D, T, O] {
  let left = self.view()
  let right = other.view()
  defer left.release()
  defer right.release()
  left.join_map(right, logic, multiply~)
}

///|
pub fn[K : Compare, V : Compare, W : Compare, T : Lattice] Arranged::join(
  self : Arranged[K, V, T, Int64],
  other : Arranged[K, W, T, Int64],
) -> Collection[(K, (V, W)), T, Int64] {
  self.join_map(other, fn(key, v, w) { (key, (v, w)) }, multiply=fn(a, b) {
    a * b
  })
}
