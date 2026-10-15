///|
fn[K, V, T, R] UpdatesTyped::retain_times(
  self : UpdatesTyped[K, V, T, R],
  keep : Array[Bool],
) -> UpdatesTyped[K, V, T, R] {
  guard self.canonical else {
    abort("chunk operations require consolidated updates")
  }
  let (times, values_kept) = self.times.retain_items(keep)
  let (vals, keys_kept) = self.vals.retain_items(values_kept)
  let (keys, _) = self.keys.retain_items(keys_kept)
  let diffs = []
  for i, keep in keep {
    if keep {
      diffs.push(self.diffs.values[i])
    }
  }
  {
    keys,
    vals,
    times,
    diffs: {
      values: diffs,
      ends: Array::makei(diffs.length(), fn(i) { i + 1 }),
    },
    canonical: true,
  }
}

///|
/// Split at a leaf count, preserving column grouping on either side. A split
/// beyond the end returns the entire chunk and an empty suffix.
pub fn[K, V, T, R] UpdatesTyped::split_at(
  self : UpdatesTyped[K, V, T, R],
  count : Int32,
) -> (UpdatesTyped[K, V, T, R], UpdatesTyped[K, V, T, R]) {
  guard self.canonical && count >= 0 else {
    abort("split requires a canonical chunk and nonnegative count")
  }
  if count == 0 {
    return (UpdatesTyped([]), self)
  }
  if count >= self.length() {
    return (self, UpdatesTyped([]))
  }
  let keep = Array::makei(self.length(), fn(i) { i < count })
  (self.retain_times(keep), self.retain_times(keep.map(fn(x) { !x })))
}

///|
/// Copy the suffix starting at flat key/value/time column indices.
pub fn[K, V, T, R] UpdatesTyped::suffix_chunk(
  self : UpdatesTyped[K, V, T, R],
  cursor : (Int32, Int32, Int32),
) -> UpdatesTyped[K, V, T, R] {
  guard self.canonical else { abort("suffix requires canonical updates") }
  let (k, v, t) = cursor
  if k == self.keys.value_count() &&
    v == self.vals.value_count() &&
    t == self.times.value_count() {
    return UpdatesTyped([])
  }
  let (vl, vu) = self.vals.bounds(k)
  guard vl <= v && v < vu else {
    abort("suffix cursor value does not belong to key")
  }
  let (tl, tu) = self.times.bounds(v)
  guard tl <= t && t < tu else {
    abort("suffix cursor time does not belong to value")
  }
  self.retain_times(Array::makei(self.length(), fn(i) { i >= t }))
}

///|
/// Partition a consolidated chunk by an arbitrary partial-order frontier. Ready
/// times are those not at-or-after any upper-frontier element.
pub fn[K, V, T : Lattice, R] UpdatesTyped::extract(
  self : UpdatesTyped[K, V, T, R],
  upper : Antichain[T],
) -> (UpdatesTyped[K, V, T, R], UpdatesTyped[K, V, T, R], Antichain[T]) {
  guard self.canonical else { abort("extract requires canonical updates") }
  let frontier = Antichain([])
  let keep = self.times.values.map(fn(time) {
    let kept = upper.less_equal(time)
    if kept {
      let _ = frontier.insert(time)
    }
    kept
  })
  if keep.iter().all(fn(x) { x }) {
    return (UpdatesTyped([]), self, frontier)
  }
  if keep.iter().all(fn(x) { !x }) {
    return (self, UpdatesTyped([]), frontier)
  }
  (self.retain_times(keep.map(fn(x) { !x })), self.retain_times(keep), frontier)
}

///|
/// Lazily extract an input sequence, delivering each partition immediately to
/// caller-owned sinks. The supplied frontier accumulates all retained times.
pub fn[K, V, T : Lattice, R] extract_update_chunks(
  chunks : Iter[UpdatesTyped[K, V, T, R]],
  upper : Antichain[T],
  frontier : Antichain[T],
  ship~ : (UpdatesTyped[K, V, T, R]) -> Unit,
  kept~ : (UpdatesTyped[K, V, T, R]) -> Unit,
) -> Unit {
  for chunk in chunks {
    let (ready, future, times) = chunk.extract(upper)
    for time in times.elements {
      let _ = frontier.insert(time)
    }
    if !ready.is_empty() {
      ship(ready)
    }
    if !future.is_empty() {
      kept(future)
    }
  }
}

///|
/// Merge one input completely and the corresponding prefix of the other. At
/// most one returned suffix is nonempty. Cancellations are removed immediately
/// (equivalent to upstream merge_pair followed by filter_zero).
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] UpdatesTyped::merge_pair(
  self : UpdatesTyped[K, V, T, R],
  other : UpdatesTyped[K, V, T, R],
) -> (
  UpdatesTyped[K, V, T, R],
  UpdatesTyped[K, V, T, R]?,
  UpdatesTyped[K, V, T, R]?,
) {
  guard self.canonical && other.canonical else {
    abort("merge requires canonical chunks")
  }
  if self.is_empty() {
    return (other, None, None)
  }
  if other.is_empty() {
    return (self, None, None)
  }
  let left = self.iter()
  let right = other.iter()
  let mut a = left.next()
  let mut b = right.next()
  let mut used_a = 0
  let mut used_b = 0
  let output = UpdatesBuilder()
  while a is Some(x) && b is Some(y) {
    let order = Compare::compare((x.0, x.1, x.2), (y.0, y.1, y.2))
    if order < 0 {
      output.push(x)
      used_a += 1
      a = left.next()
    } else if order > 0 {
      output.push(y)
      used_b += 1
      b = right.next()
    } else {
      let sum = x.3.plus(y.3)
      if !sum.is_zero() {
        output.push((x.0, x.1, x.2, sum))
      }
      used_a += 1
      used_b += 1
      a = left.next()
      b = right.next()
    }
  }
  let suffix_a = if used_a < self.length() {
    Some(self.retain_times(Array::makei(self.length(), fn(i) { i >= used_a })))
  } else {
    None
  }
  let suffix_b = if used_b < other.length() {
    Some(
      other.retain_times(Array::makei(other.length(), fn(i) { i >= used_b })),
    )
  } else {
    None
  }
  (output.done(), suffix_a, suffix_b)
}

///|
/// Store a consolidated update trie as a regular immutable indexed batch without
/// flattening records. The standard trace, spill, import and cursor APIs apply.
pub fn[K : Eq, V : Eq, T : Lattice, R] UpdatesTyped::batch(
  self : UpdatesTyped[K, V, T, R],
  description : Description[T],
) -> Batch[(K, V), T, R] {
  guard self.canonical else { abort("batch requires canonical updates") }
  for time in self.times.values {
    guard description.lower.less_equal(time) &&
      (
        !description.since.precedes(description.lower) ||
        !description.upper.less_equal(time)
      ) else {
      abort("columnar time outside batch interval")
    }
  }
  let columns : Columns[K, V, T, R] = {
    keys: self.keys.values,
    key_offsets: [0] + self.vals.ends,
    values: self.vals.values,
    value_offsets: [0] + self.times.ends,
    times: self.times.values,
    diffs: self.diffs.values,
  }
  { updates: columns.storage(), description, }
}

///|
/// Expose an existing columnar batch as a consolidated trie without copying its
/// values. Offset arrays are adapted to the trie list convention.
pub fn[K, V, T, R] ColumnarBatch::updates(
  self : ColumnarBatch[K, V, T, R],
) -> UpdatesTyped[K, V, T, R] {
  let c = self.columns
  {
    keys: {
      values: c.keys,
      ends: if c.keys.is_empty() {
        []
      } else {
        [c.keys.length()]
      },
    },
    vals: { values: c.values, ends: c.key_offsets[1:].to_owned(), },
    times: { values: c.times, ends: c.value_offsets[1:].to_owned(), },
    diffs: {
      values: c.diffs,
      ends: Array::makei(c.diffs.length(), fn(i) { i + 1 }),
    },
    canonical: true,
  }
}
