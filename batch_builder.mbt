///|
/// Build an immutable batch from sorted update chunks. push consumes its chunk;
/// done consumes the builder. Equal adjacent updates are consolidated.
pub struct BatchBuilder[D, T, R] {
  priv mut updates : Array[(D, T, R)]
  priv mut previous : (D, T)?
  priv mut finished : Bool
}

///|
pub fn[D, T, R] BatchBuilder::BatchBuilder(
  capacity~ : Int32 = 0,
) -> BatchBuilder[D, T, R] {
  { updates: Array(capacity~), previous: None, finished: false, }
}

///|
pub fn[D : Compare, T : Compare, R : Semigroup] BatchBuilder::push(
  self : BatchBuilder[D, T, R],
  chunk : Array[(D, T, R)],
) -> Unit {
  guard !self.finished else { abort("batch builder was consumed") }
  for (data, time, diff) in chunk {
    let key = (data, time)
    guard self.previous is None || (self.previous is Some(last) && last <= key) else {
      abort("batch builder input must be sorted")
    }
    self.previous = Some(key)
    if self.updates.last() is Some((old_data, old_time, old_diff)) &&
      old_data == data &&
      old_time == time {
      let _ = self.updates.pop()
      let sum = old_diff.plus(diff)
      if !sum.is_zero() {
        self.updates.push((data, time, sum))
      }
    } else if !diff.is_zero() {
      self.updates.push((data, time, diff))
    }
  }
  chunk.clear()
}

///|
/// Description may specify compaction; compacted records can exceed its upper.
pub fn[D, T, R] BatchBuilder::done(
  self : BatchBuilder[D, T, R],
  description : Description[T],
) -> Batch[D, T, R] {
  guard !self.finished else { abort("batch builder was consumed") }
  self.finished = true
  let updates = self.updates
  self.updates = []
  self.previous = None
  { updates, description, }
}

///|
pub fn[D : Compare, T : Compare, R : Semigroup] BatchBuilder::seal(
  chain : Array[Array[(D, T, R)]],
  description : Description[T],
) -> Batch[D, T, R] {
  let builder = BatchBuilder()
  for chunk in chain {
    builder.push(chunk)
  }
  chain.clear()
  builder.done(description)
}
