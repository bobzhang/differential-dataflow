///|
/// Sorted, nonzero sums of weights for each equal key; input array is unchanged.
pub fn[D : Compare, R : Semigroup] consolidate(
  input : Array[(D, R)],
) -> Array[(D, R)] {
  let sorted = input.copy()
  sorted.sort_by(fn(a, b) { a.0.compare(b.0) })
  let output : Array[(D, R)] = []
  for (key, diff) in sorted {
    if output.last() is Some((previous, accumulated)) && previous == key {
      let _ = output.pop()
      let sum = accumulated.plus(diff)
      if !sum.is_zero() {
        output.push((key, sum))
      }
    } else if !diff.is_zero() {
      output.push((key, diff))
    }
  }
  output
}

///|
/// Consolidates by record and timestamp, retaining incomparable times separately.
pub fn[D : Compare, T : Compare, R : Semigroup] consolidate_updates(
  input : Array[(D, T, R)],
) -> Array[(D, T, R)] {
  consolidate(input.map(fn(u) { ((u.0, u.1), u.2) })).map(fn(u) {
    (u.0.0, u.0.1, u.1)
  })
}
