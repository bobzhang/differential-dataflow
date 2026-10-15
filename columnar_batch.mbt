///|
/// Immutable key/value/time/difference columns. Repeated keys and values are
/// represented once, with offsets delimiting their sorted child ranges.
pub struct ColumnarBatch[K, V, T, R] {
  priv columns : Columns[K, V, T, R]
  priv description : Description[T]
}

///|
priv struct Columns[K, V, T, R] {
  keys : Array[K]
  key_offsets : Array[Int32]
  values : Array[V]
  value_offsets : Array[Int32]
  times : Array[T]
  diffs : Array[R]
}

///|
fn[K : Eq, V : Eq, T, R] columns_from_sorted(
  rows : Array[((K, V), T, R)],
) -> Columns[K, V, T, R] {
  let keys = []
  let key_offsets = []
  let values = []
  let value_offsets = []
  let times = []
  let diffs = []
  for ((key, value), time, diff) in rows {
    let new_key = keys.last() != Some(key)
    if new_key {
      keys.push(key)
      key_offsets.push(values.length())
    }
    if new_key || values.last() != Some(value) {
      values.push(value)
      value_offsets.push(times.length())
    }
    times.push(time)
    diffs.push(diff)
  }
  key_offsets.push(values.length())
  value_offsets.push(times.length())
  { keys, key_offsets, values, value_offsets, times, diffs, }
}

///|
// Return the child range containing an index. Sentinel offsets are excluded.
fn column_parent(offsets : Array[Int32], index : Int32) -> Int32 {
  let mut low = 0
  let mut high = offsets.length() - 1
  while low + 1 < high {
    let middle = low + (high - low) / 2
    if offsets[middle] <= index {
      low = middle
    } else {
      high = middle
    }
  }
  low
}

///|
fn[K, V, T, R] Columns::reader(
  self : Columns[K, V, T, R],
) -> UpdateReader[(K, V), T, R] {
  {
    size: self.times.length(),
    read: fn(index) {
      guard index >= 0 && index < self.times.length() else {
        abort("columnar update index out of bounds")
      }
      let value = column_parent(self.value_offsets, index)
      let key = column_parent(self.key_offsets, value)
      (
        (self.keys[key], self.values[value]),
        self.times[index],
        self.diffs[index],
      )
    },
  }
}

///|
fn[K : Eq, V : Eq, T, R] Columns::storage(
  self : Columns[K, V, T, R],
) -> UpdateStorage[(K, V), T, R] {
  Indexed(self.times.length(), fn() { self.reader() }, fn(rows) {
    columns_from_sorted(rows).storage()
  })
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] ColumnarBatch::ColumnarBatch(
  updates : Array[((K, V), T, R)],
  lower~ : Antichain[T],
  upper~ : Antichain[T],
) -> ColumnarBatch[K, V, T, R] {
  Batch(updates, lower~, upper~).columnar()
}

///|
/// Convert a batch without changing its interval or compaction frontier.
pub fn[K : Eq, V : Eq, T, R] Batch::columnar(
  self : Batch[(K, V), T, R],
) -> ColumnarBatch[K, V, T, R] {
  {
    columns: columns_from_sorted(self.to_array()),
    description: self.description,
  }
}

///|
/// Share these columns with ordinary trace, spine, merge and cursor APIs.
pub fn[K : Eq, V : Eq, T, R] ColumnarBatch::batch(
  self : ColumnarBatch[K, V, T, R],
) -> Batch[(K, V), T, R] {
  { updates: self.columns.storage(), description: self.description, }
}

///|
/// Number of stored keys, values and time/difference pairs (excluding offsets).
pub fn[K, V, T, R] ColumnarBatch::storage_counts(
  self : ColumnarBatch[K, V, T, R],
) -> (Int32, Int32, Int32) {
  (
    self.columns.keys.length(),
    self.columns.values.length(),
    self.columns.times.length(),
  )
}
