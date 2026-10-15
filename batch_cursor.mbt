///|
/// A stable snapshot cursor over keys, values, and timestamped differences.
priv struct BatchCursor[K, V, T, R] {
  view : BatchView[(K, V), T, R]
  mut key_start : Int32
  mut key_end : Int32
  mut val_start : Int32
  mut val_end : Int32
}

///|
fn[K : Eq, V : Eq, T, R] BatchCursor::BatchCursor(
  view : BatchView[(K, V), T, R],
) -> BatchCursor[K, V, T, R] {
  let cursor = { view, key_start: 0, key_end: 0, val_start: 0, val_end: 0, }
  cursor.load_key()
  cursor
}

///|
fn[K : Eq, V : Eq, T, R] BatchCursor::load_key(
  self : BatchCursor[K, V, T, R],
) -> Unit {
  self.key_end = self.key_start
  if self.key_valid() {
    let key = (self.view.read)(self.key_start).0.0
    self.key_end = for lower = self.key_start, upper = self.view.size; lower <
                      upper; {
      let middle = lower + (upper - lower) / 2
      if (self.view.read)(middle).0.0 == key {
        continue middle + 1, upper
      } else {
        continue lower, middle
      }
    } nobreak {
      lower
    }
  }
  self.val_start = self.key_start
  self.load_val()
}

///|
fn[K, V : Eq, T, R] BatchCursor::load_val(
  self : BatchCursor[K, V, T, R],
) -> Unit {
  self.val_end = self.val_start
  if self.val_valid() {
    let value = (self.view.read)(self.val_start).0.1
    self.val_end = for lower = self.val_start, upper = self.key_end; lower <
                      upper; {
      let middle = lower + (upper - lower) / 2
      if (self.view.read)(middle).0.1 == value {
        continue middle + 1, upper
      } else {
        continue lower, middle
      }
    } nobreak {
      lower
    }
  }
}

///|
fn[K, V, T, R] BatchCursor::key_valid(self : BatchCursor[K, V, T, R]) -> Bool {
  self.key_start < self.view.size
}

///|
fn[K, V, T, R] BatchCursor::val_valid(self : BatchCursor[K, V, T, R]) -> Bool {
  self.val_start < self.key_end
}

///|
fn[K, V, T, R] BatchCursor::key(self : BatchCursor[K, V, T, R]) -> K? {
  if self.key_valid() {
    Some((self.view.read)(self.key_start).0.0)
  } else {
    None
  }
}

///|
fn[K, V, T, R] BatchCursor::val(self : BatchCursor[K, V, T, R]) -> V? {
  if self.val_valid() {
    Some((self.view.read)(self.val_start).0.1)
  } else {
    None
  }
}

///|
fn[K, V, T, R] BatchCursor::map_times(
  self : BatchCursor[K, V, T, R],
  logic : (T, R) -> Unit,
) -> Unit {
  for index in self.val_start..<self.val_end {
    if self.view.get(index) is Some((_, time, diff)) {
      logic(time, diff)
    }
  }
}

///|
fn[K : Eq, V : Eq, T, R] BatchCursor::step_key(
  self : BatchCursor[K, V, T, R],
) -> Unit {
  self.key_start = self.key_end
  self.load_key()
}

///|
fn[K, V : Eq, T, R] BatchCursor::step_val(
  self : BatchCursor[K, V, T, R],
) -> Unit {
  self.val_start = self.val_end
  self.load_val()
}

///|
fn[K : Eq, V : Eq, T, R] BatchCursor::rewind_keys(
  self : BatchCursor[K, V, T, R],
) -> Unit {
  self.key_start = 0
  self.load_key()
}

///|
fn[K, V : Eq, T, R] BatchCursor::rewind_vals(
  self : BatchCursor[K, V, T, R],
) -> Unit {
  self.val_start = self.key_start
  self.load_val()
}

///|
fn[K : Compare, V : Eq, T, R] BatchCursor::seek_key(
  self : BatchCursor[K, V, T, R],
  key : K,
) -> Unit {
  self.key_start = for lo = self.key_start, hi = self.view.size; lo < hi; {
    let mid = lo + (hi - lo) / 2
    if (self.view.read)(mid).0.0 < key {
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
fn[K, V : Compare, T, R] BatchCursor::seek_val(
  self : BatchCursor[K, V, T, R],
  value : V,
) -> Unit {
  self.val_start = for lo = self.val_start, hi = self.key_end; lo < hi; {
    let mid = lo + (hi - lo) / 2
    if (self.view.read)(mid).0.1 < value {
      continue mid + 1, hi
    } else {
      continue lo, mid
    }
  } nobreak {
    lo
  }
  self.load_val()
}
