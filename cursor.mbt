///|
/// A cursor merging retained immutable batch indexes. Construction retains the
/// batches without copying update history. Times are visited per batch and are
/// not consolidated across batches, matching upstream CursorList.
pub struct Cursor[K, V, T, R] {
  priv cursors : Array[BatchCursor[K, V, T, R]]
  priv min_keys : Array[Int32]
  priv min_vals : Array[Int32]
}

///|
pub fn[K : Compare, V : Compare, T, R] Cursor::Cursor(
  batches : Array[BatchView[(K, V), T, R]],
) -> Cursor[K, V, T, R] {
  let cursor = {
    cursors: batches.map(fn(batch) { BatchCursor(batch) }),
    min_keys: [],
    min_vals: [],
  }
  cursor.minimize_keys()
  cursor
}

///|
fn[K : Compare, V : Compare, T, R] Cursor::minimize_keys(
  self : Cursor[K, V, T, R],
) -> Unit {
  self.min_keys.clear()
  let mut minimum : K? = None
  for index, cursor in self.cursors {
    if cursor.key() is Some(key) {
      if minimum is Some(previous) && key < previous {
        self.min_keys.clear()
      }
      if minimum is None || (minimum is Some(previous) && key <= previous) {
        self.min_keys.push(index)
        minimum = Some(key)
      }
    }
  }
  self.minimize_vals()
}

///|
fn[K, V : Compare, T, R] Cursor::minimize_vals(
  self : Cursor[K, V, T, R],
) -> Unit {
  self.min_vals.clear()
  let mut minimum : V? = None
  for index in self.min_keys {
    if self.cursors[index].val() is Some(value) {
      if minimum is Some(previous) && value < previous {
        self.min_vals.clear()
      }
      if minimum is None || (minimum is Some(previous) && value <= previous) {
        self.min_vals.push(index)
        minimum = Some(value)
      }
    }
  }
}

///|
pub fn[K, V, T, R] Cursor::key_valid(self : Cursor[K, V, T, R]) -> Bool {
  !self.min_keys.is_empty()
}

///|
pub fn[K, V, T, R] Cursor::val_valid(self : Cursor[K, V, T, R]) -> Bool {
  !self.min_vals.is_empty()
}

///|
pub fn[K, V, T, R] Cursor::key(self : Cursor[K, V, T, R]) -> K? {
  match self.min_keys.get(0) {
    Some(index) => self.cursors[index].key()
    None => None
  }
}

///|
pub fn[K, V, T, R] Cursor::val(self : Cursor[K, V, T, R]) -> V? {
  match self.min_vals.get(0) {
    Some(index) => self.cursors[index].val()
    None => None
  }
}

///|
pub fn[K, V, T, R] Cursor::map_times(
  self : Cursor[K, V, T, R],
  visit : (T, R) -> Unit,
) -> Unit {
  for index in self.min_vals {
    self.cursors[index].map_times(visit)
  }
}

///|
pub fn[K, V, T, R] Cursor::times(self : Cursor[K, V, T, R]) -> Array[(T, R)] {
  let result = []
  self.map_times(fn(time, diff) { result.push((time, diff)) })
  result
}

///|
pub fn[K : Compare, V : Compare, T, R] Cursor::step_key(
  self : Cursor[K, V, T, R],
) -> Unit {
  for index in self.min_keys {
    self.cursors[index].step_key()
  }
  self.minimize_keys()
}

///|
pub fn[K, V : Compare, T, R] Cursor::step_val(
  self : Cursor[K, V, T, R],
) -> Unit {
  for index in self.min_vals {
    self.cursors[index].step_val()
  }
  self.minimize_vals()
}

///|
pub fn[K : Compare, V : Compare, T, R] Cursor::seek_key(
  self : Cursor[K, V, T, R],
  key : K,
) -> Unit {
  for cursor in self.cursors {
    cursor.seek_key(key)
  }
  self.minimize_keys()
}

///|
pub fn[K, V : Compare, T, R] Cursor::seek_val(
  self : Cursor[K, V, T, R],
  value : V,
) -> Unit {
  for cursor in self.cursors {
    cursor.seek_val(value)
  }
  self.minimize_vals()
}

///|
pub fn[K : Compare, V : Compare, T, R] Cursor::rewind_keys(
  self : Cursor[K, V, T, R],
) -> Unit {
  for cursor in self.cursors {
    cursor.rewind_keys()
  }
  self.minimize_keys()
}

///|
pub fn[K, V : Compare, T, R] Cursor::rewind_vals(
  self : Cursor[K, V, T, R],
) -> Unit {
  for index in self.min_keys {
    self.cursors[index].rewind_vals()
  }
  self.minimize_vals()
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] Trace::cursor(
  self : Trace[(K, V), T, R],
) -> Cursor[K, V, T, R] {
  self.cursor_through(Antichain([])).unwrap()
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] Trace::cursor_through(
  self : Trace[(K, V), T, R],
  upper : Antichain[T],
) -> Cursor[K, V, T, R]? {
  guard self.batches_through(upper) is Some(batches) else { return None }
  Some(Cursor(batches.map(fn(batch) { batch.view() })))
}
