///|
/// A stable snapshot cursor over keys, values, and timestamped differences.
pub struct Cursor[K, V, T, R] {
  priv updates : Array[((K, V), T, R)]
  priv mut key_start : Int32
  priv mut key_end : Int32
  priv mut val_start : Int32
  priv mut val_end : Int32
}

///|
fn[K : Compare, V : Compare, T : Compare, R : Semigroup] Cursor::Cursor(
  updates : Array[((K, V), T, R)],
) -> Cursor[K, V, T, R] {
  let cursor = {
    updates: consolidate_updates(updates),
    key_start: 0,
    key_end: 0,
    val_start: 0,
    val_end: 0,
  }
  cursor.load_key()
  cursor
}

///|
fn[K : Eq, V : Eq, T, R] Cursor::load_key(self : Cursor[K, V, T, R]) -> Unit {
  self.key_end = self.key_start
  if self.key_valid() {
    let key = self.updates[self.key_start].0.0
    while self.key_end < self.updates.length() &&
          self.updates[self.key_end].0.0 == key {
      self.key_end += 1
    }
  }
  self.val_start = self.key_start
  self.load_val()
}

///|
fn[K, V : Eq, T, R] Cursor::load_val(self : Cursor[K, V, T, R]) -> Unit {
  self.val_end = self.val_start
  if self.val_valid() {
    let value = self.updates[self.val_start].0.1
    while self.val_end < self.key_end && self.updates[self.val_end].0.1 == value {
      self.val_end += 1
    }
  }
}

///|
pub fn[K, V, T, R] Cursor::key_valid(self : Cursor[K, V, T, R]) -> Bool {
  self.key_start < self.updates.length()
}

///|
pub fn[K, V, T, R] Cursor::val_valid(self : Cursor[K, V, T, R]) -> Bool {
  self.val_start < self.key_end
}

///|
pub fn[K, V, T, R] Cursor::key(self : Cursor[K, V, T, R]) -> K? {
  if self.key_valid() {
    Some(self.updates[self.key_start].0.0)
  } else {
    None
  }
}

///|
pub fn[K, V, T, R] Cursor::val(self : Cursor[K, V, T, R]) -> V? {
  if self.val_valid() {
    Some(self.updates[self.val_start].0.1)
  } else {
    None
  }
}

///|
pub fn[K, V, T, R] Cursor::times(self : Cursor[K, V, T, R]) -> Array[(T, R)] {
  [
    for i in self.val_start..<self.val_end => {
      (self.updates[i].1, self.updates[i].2)
    }
  ]
}

///|
pub fn[K, V, T, R] Cursor::map_times(
  self : Cursor[K, V, T, R],
  logic : (T, R) -> Unit,
) -> Unit {
  for i in self.val_start..<self.val_end {
    logic(self.updates[i].1, self.updates[i].2)
  }
}

///|
pub fn[K : Eq, V : Eq, T, R] Cursor::step_key(
  self : Cursor[K, V, T, R],
) -> Unit {
  self.key_start = self.key_end
  self.load_key()
}

///|
pub fn[K, V : Eq, T, R] Cursor::step_val(self : Cursor[K, V, T, R]) -> Unit {
  self.val_start = self.val_end
  self.load_val()
}

///|
pub fn[K : Eq, V : Eq, T, R] Cursor::rewind_keys(
  self : Cursor[K, V, T, R],
) -> Unit {
  self.key_start = 0
  self.load_key()
}

///|
pub fn[K, V : Eq, T, R] Cursor::rewind_vals(self : Cursor[K, V, T, R]) -> Unit {
  self.val_start = self.key_start
  self.load_val()
}

///|
pub fn[K : Compare, V : Eq, T, R] Cursor::seek_key(
  self : Cursor[K, V, T, R],
  key : K,
) -> Unit {
  self.key_start = for lo = self.key_start, hi = self.updates.length(); lo < hi; {
    let mid = lo + (hi - lo) / 2
    if self.updates[mid].0.0 < key {
      continue mid + 1, hi
    } else {
      continue lo, mid
    }
  } nobreak {
    lo
  }
  self.load_key()
}

///|
pub fn[K, V : Compare, T, R] Cursor::seek_val(
  self : Cursor[K, V, T, R],
  value : V,
) -> Unit {
  self.val_start = for lo = self.val_start, hi = self.key_end; lo < hi; {
    let mid = lo + (hi - lo) / 2
    if self.updates[mid].0.1 < value {
      continue mid + 1, hi
    } else {
      continue lo, mid
    }
  } nobreak {
    lo
  }
  self.load_val()
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] Trace::cursor(
  self : Trace[(K, V), T, R],
) -> Cursor[K, V, T, R] {
  self.cursor_through(Antichain([])).unwrap()
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] Trace::cursor_through(
  self : Trace[(K, V), T, R],
  upper : Antichain[T],
) -> Cursor[K, V, T, R]? {
  guard self.batches_through(upper) is Some(batches) else { return None }
  let updates = []
  for batch in batches {
    for update in batch.updates {
      updates.push(update)
    }
  }
  Some(Cursor(updates))
}
