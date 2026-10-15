///|
/// Immutable lists sharing one value column, delimited by cumulative end offsets.
/// Constructors copy their arrays; views can be retained across builder updates.
pub struct ColumnLists[A] {
  priv values : Array[A]
  priv ends : Array[Int32]
}

///|
pub fn[A] ColumnLists::ColumnLists(
  values : Array[A],
  ends : Array[Int32],
) -> ColumnLists[A] {
  let mut previous = 0
  for end in ends {
    guard previous <= end && end <= values.length() else {
      abort("invalid column list bounds")
    }
    previous = end
  }
  guard previous == values.length() else { abort("unreferenced column values") }
  { values: values.copy(), ends: ends.copy(), }
}

///|
pub fn[A] ColumnLists::length(self : ColumnLists[A]) -> Int32 {
  self.ends.length()
}

///|
pub fn[A] ColumnLists::value_count(self : ColumnLists[A]) -> Int32 {
  self.values.length()
}

///|
pub fn[A] ColumnLists::get(self : ColumnLists[A], index : Int32) -> A {
  self.values[index]
}

///|
pub fn[A] ColumnLists::bounds(
  self : ColumnLists[A],
  index : Int32,
) -> (Int32, Int32) {
  guard index >= 0 && index < self.ends.length() else {
    abort("column list index out of bounds")
  }
  (if index == 0 { 0 } else { self.ends[index - 1] }, self.ends[index])
}

///|
pub fn[A] ColumnLists::values(self : ColumnLists[A]) -> Array[A] {
  self.values.copy()
}

///|
pub fn[A] ColumnLists::offsets(self : ColumnLists[A]) -> Array[Int32] {
  self.ends.copy()
}

///|
/// Keep selected values, remove empty lists, and return a bitmap of surviving lists.
pub fn[A] ColumnLists::retain_items(
  self : ColumnLists[A],
  keep : Array[Bool],
) -> (ColumnLists[A], Array[Bool]) {
  guard keep.length() == self.values.length() else {
    abort("column bitmap length mismatch")
  }
  let values = []
  let ends = []
  let present = []
  let mut lower = 0
  for upper in self.ends {
    let before = values.length()
    for i in lower..<upper {
      if keep[i] {
        values.push(self.values[i])
      }
    }
    let kept = values.length() > before
    present.push(kept)
    if kept {
      ends.push(values.length())
    }
    lower = upper
  }
  ({ values, ends, }, present)
}

///|
/// Four-level key/value/time/difference trie. Leaves may be unconsolidated,
/// including repeated keys, times, and several differences at one time.
pub struct UpdatesTyped[K, V, T, R] {
  priv keys : ColumnLists[K]
  priv vals : ColumnLists[V]
  priv times : ColumnLists[T]
  priv diffs : ColumnLists[R]
  priv canonical : Bool
}

///|
/// Build singleton groups from raw updates without sorting or consolidation.
pub fn[K, V, T, R] UpdatesTyped::UpdatesTyped(
  rows : Array[(K, V, T, R)],
) -> UpdatesTyped[K, V, T, R] {
  let ends = Array::makei(rows.length(), fn(i) { i + 1 })
  {
    keys: { values: rows.map(fn(x) { x.0 }), ends, },
    vals: { values: rows.map(fn(x) { x.1 }), ends, },
    times: { values: rows.map(fn(x) { x.2 }), ends, },
    diffs: { values: rows.map(fn(x) { x.3 }), ends, },
    canonical: rows.is_empty(),
  }
}

///|
/// Adapt four independently stored list columns. Each parent value must have
/// exactly one child list; empty child lists are allowed.
pub fn[K, V, T, R] UpdatesTyped::from_columns(
  keys : ColumnLists[K],
  vals : ColumnLists[V],
  times : ColumnLists[T],
  diffs : ColumnLists[R],
) -> UpdatesTyped[K, V, T, R] {
  guard keys.value_count() == vals.length() &&
    vals.value_count() == times.length() &&
    times.value_count() == diffs.length() else {
    abort("trie columns have mismatched child counts")
  }
  { keys, vals, times, diffs, canonical: false, }
}

///|
pub fn[K, V, T, R] UpdatesTyped::columns(
  self : UpdatesTyped[K, V, T, R],
) -> (ColumnLists[K], ColumnLists[V], ColumnLists[T], ColumnLists[R]) {
  (self.keys, self.vals, self.times, self.diffs)
}

///|
pub fn[K, V, T, R] UpdatesTyped::length(
  self : UpdatesTyped[K, V, T, R],
) -> Int32 {
  self.diffs.value_count()
}

///|
pub fn[K, V, T, R] UpdatesTyped::is_empty(
  self : UpdatesTyped[K, V, T, R],
) -> Bool {
  self.length() == 0
}

///|
/// Stream leaves in storage order. Empty groups at every level are skipped.
pub fn[K, V, T, R] UpdatesTyped::iter(
  self : UpdatesTyped[K, V, T, R],
) -> Iter[(K, V, T, R)] {
  let mut k = 0
  let mut v = 0
  let mut t = 0
  let mut d = 0
  Iter::new(fn() {
    if d == self.diffs.value_count() {
      return None
    }
    while d >= self.diffs.ends[t] {
      t += 1
    }
    while t >= self.times.ends[v] {
      v += 1
    }
    while v >= self.vals.ends[k] {
      k += 1
    }
    let result = (
      self.keys.values[k],
      self.vals.values[v],
      self.times.values[t],
      self.diffs.values[d],
    )
    d += 1
    Some(result)
  })
}

///|
pub fn[K, V, T, R] UpdatesTyped::vals_bounds(
  self : UpdatesTyped[K, V, T, R],
  lower : Int32,
  upper : Int32,
) -> (Int32, Int32) {
  guard lower >= 0 && lower <= upper && upper <= self.keys.value_count() else {
    abort("invalid key range")
  }
  if lower == upper {
    return (lower, upper)
  }
  (
    if lower == 0 {
      0
    } else {
      self.vals.ends[lower - 1]
    },
    self.vals.ends[upper - 1],
  )
}

///|
pub fn[K, V, T, R] UpdatesTyped::times_bounds(
  self : UpdatesTyped[K, V, T, R],
  lower : Int32,
  upper : Int32,
) -> (Int32, Int32) {
  guard lower >= 0 && lower <= upper && upper <= self.vals.value_count() else {
    abort("invalid value range")
  }
  if lower == upper {
    return (lower, upper)
  }
  (
    if lower == 0 {
      0
    } else {
      self.times.ends[lower - 1]
    },
    self.times.ends[upper - 1],
  )
}

///|
/// Ordered builder. Melded chunks must be consolidated and strictly increasing
/// in (key, value, time); key/value groups can continue across chunk boundaries.
pub struct UpdatesBuilder[K, V, T, R] {
  priv keys : Array[K]
  priv vals : Array[V]
  priv times : Array[T]
  priv diffs : Array[R]
  priv val_ends : Array[Int32]
  priv time_ends : Array[Int32]
  priv mut last : (K, V, T)?
  priv mut finished : Bool
}

///|
pub fn[K, V, T, R] UpdatesBuilder::UpdatesBuilder() -> UpdatesBuilder[
  K,
  V,
  T,
  R,
] {
  {
    keys: [],
    vals: [],
    times: [],
    diffs: [],
    val_ends: [],
    time_ends: [],
    last: None,
    finished: false,
  }
}

///|
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] UpdatesBuilder::push(
  self : UpdatesBuilder[K, V, T, R],
  row : (K, V, T, R),
) -> Unit {
  guard !self.finished else { abort("columnar builder was finished") }
  let (k, v, t, r) = row
  guard !r.is_zero() else {
    abort("ordered builder requires nonzero differences")
  }
  if self.last is Some(previous) {
    guard Compare::compare(previous, (k, v, t)) < 0 else {
      abort("columnar builder inputs must be strictly ordered")
    }
  }
  let new_key = self.keys.last() != Some(k)
  let new_val = new_key || self.vals.last() != Some(v)
  if new_key {
    self.keys.push(k)
    self.val_ends.push(self.vals.length())
  }
  if new_val {
    self.vals.push(v)
    self.time_ends.push(self.times.length())
  }
  self.times.push(t)
  self.diffs.push(r)
  self.val_ends[self.val_ends.length() - 1] = self.vals.length()
  self.time_ends[self.time_ends.length() - 1] = self.times.length()
  self.last = Some((k, v, t))
}

///|
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] UpdatesBuilder::meld(
  self : UpdatesBuilder[K, V, T, R],
  chunk : UpdatesTyped[K, V, T, R],
) -> Unit {
  guard !self.finished && chunk.canonical else {
    abort("meld requires canonical chunks and an unfinished builder")
  }
  for row in chunk.iter() {
    self.push(row)
  }
}

///|
pub fn[K, V, T, R] UpdatesBuilder::done(
  self : UpdatesBuilder[K, V, T, R],
) -> UpdatesTyped[K, V, T, R] {
  guard !self.finished else { abort("columnar builder was finished") }
  self.finished = true
  {
    keys: {
      values: self.keys,
      ends: if self.keys.is_empty() {
        []
      } else {
        [self.keys.length()]
      },
    },
    vals: { values: self.vals, ends: self.val_ends, },
    times: { values: self.times, ends: self.time_ends, },
    diffs: {
      values: self.diffs,
      ends: Array::makei(self.diffs.length(), fn(i) { i + 1 }),
    },
    canonical: true,
  }
}

///|
/// Consolidate a sorted stream without materializing an intermediate row array.
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] UpdatesTyped::form(
  rows : Iter[(K, V, T, R)],
) -> UpdatesTyped[K, V, T, R] {
  let builder = UpdatesBuilder()
  let mut pending : (K, V, T, R)? = None
  for row in rows {
    match pending {
      None => pending = Some(row)
      Some(old) => {
        let order = Compare::compare(
          (old.0, old.1, old.2),
          (row.0, row.1, row.2),
        )
        guard order <= 0 else { abort("form requires sorted updates") }
        if order == 0 {
          pending = Some((old.0, old.1, old.2, old.3.plus(row.3)))
        } else {
          if !old.3.is_zero() {
            builder.push(old)
          }
          pending = Some(row)
        }
      }
    }
  }
  if pending is Some(row) && !row.3.is_zero() {
    builder.push(row)
  }
  builder.done()
}

///|
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] UpdatesTyped::form_unsorted(
  rows : Iter[(K, V, T, R)],
) -> UpdatesTyped[K, V, T, R] {
  let sorted = rows.to_array()
  sorted.sort_by(fn(a, b) { Compare::compare((a.0, a.1, a.2), (b.0, b.1, b.2)) })
  UpdatesTyped::form(sorted.iter())
}

///|
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] UpdatesTyped::consolidate(
  self : UpdatesTyped[K, V, T, R],
) -> UpdatesTyped[K, V, T, R] {
  UpdatesTyped::form_unsorted(self.iter())
}

///|
/// Remove empty difference lists and their newly empty ancestors. As upstream,
/// this assumes at most one difference per time and does not test numeric zeros.
pub fn[K, V, T, R] UpdatesTyped::filter_zero(
  self : UpdatesTyped[K, V, T, R],
) -> UpdatesTyped[K, V, T, R] {
  let keep = Array::makei(self.diffs.length(), fn(i) {
    let (a, b) = self.diffs.bounds(i)
    guard b - a <= 1 else {
      abort("filter_zero requires singleton or empty differences")
    }
    b > a
  })
  let (times, values_kept) = self.times.retain_items(keep)
  let (vals, keys_kept) = self.vals.retain_items(values_kept)
  let (keys, _) = self.keys.retain_items(keys_kept)
  {
    keys,
    vals,
    times,
    diffs: {
      values: self.diffs.values,
      ends: Array::makei(self.diffs.value_count(), fn(i) { i + 1 }),
    },
    canonical: self.canonical,
  }
}
