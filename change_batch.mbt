///|
/// Consolidates signed counts by key, removing zero totals.
pub struct ChangeBatch[T] {
  priv mut updates : Array[(T, Int64)]
  priv mut clean : Int32
}

///|
pub fn[T] ChangeBatch::ChangeBatch() -> ChangeBatch[T] {
  { updates: [], clean: 0, }
}

///|
pub fn[T : Compare] ChangeBatch::update(
  self : ChangeBatch[T],
  key : T,
  delta : Int64,
) -> Unit {
  self.updates.push((key, delta))
  if self.updates.length() > 32 && self.updates.length() / 2 >= self.clean {
    self.compact()
  }
}

///|
pub fn[T : Compare] ChangeBatch::update_all(
  self : ChangeBatch[T],
  changes : Array[(T, Int64)],
) -> Unit {
  for (key, delta) in changes {
    self.update(key, delta)
  }
}

///|
fn[T : Compare] ChangeBatch::compact(self : ChangeBatch[T]) -> Unit {
  if self.clean == self.updates.length() {
    return
  }
  self.updates.sort()
  let output = []
  for (key, delta) in self.updates {
    if output.last() is Some((last, count)) && last == key {
      let _ = output.pop()
      if count + delta != 0 {
        output.push((key, count + delta))
      }
    } else if delta != 0 {
      output.push((key, delta))
    }
  }
  self.updates = output
  self.clean = output.length()
}

///|
pub fn[T : Compare] ChangeBatch::to_array(
  self : ChangeBatch[T],
) -> Array[(T, Int64)] {
  self.compact()
  self.updates.copy()
}

///|
pub fn[T : Compare] ChangeBatch::drain(
  self : ChangeBatch[T],
) -> Array[(T, Int64)] {
  self.compact()
  let result = self.updates
  self.updates = []
  self.clean = 0
  result
}

///|
pub fn[T] ChangeBatch::clear(self : ChangeBatch[T]) -> Unit {
  self.updates.clear()
  self.clean = 0
}

///|
pub fn[T : Compare] ChangeBatch::is_empty(self : ChangeBatch[T]) -> Bool {
  self.compact()
  self.updates.is_empty()
}

///|
pub fn[T] ChangeBatch::is_dirty(self : ChangeBatch[T]) -> Bool {
  self.updates.length() > self.clean
}
