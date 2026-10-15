///|
/// A lazy immutable batch view. Timestamp adaptation retains the backing batch;
/// it does not copy or rebuild the stored update array.
pub struct BatchView[D, T, R] {
  priv size : Int32
  priv read : (Int32) -> (D, T, R)
  priv description : Description[T]
}

///|
pub fn[D, T, R] Batch::view(self : Batch[D, T, R]) -> BatchView[D, T, R] {
  {
    size: self.updates.length(),
    read: fn(index) { self.updates[index] },
    description: self.description,
  }
}

///|
pub fn[D, T, R] BatchView::length(self : BatchView[D, T, R]) -> Int32 {
  self.size
}

///|
pub fn[D, T, R] BatchView::description(
  self : BatchView[D, T, R],
) -> Description[T] {
  self.description
}

///|
pub fn[D, T, R] BatchView::get(
  self : BatchView[D, T, R],
  index : Int32,
) -> (D, T, R)? {
  if index < 0 || index >= self.size {
    None
  } else {
    Some((self.read)(index))
  }
}

///|
pub fn[D, T, R] BatchView::for_each(
  self : BatchView[D, T, R],
  visit : (D, T, R) -> Unit,
) -> Unit {
  for index in 0..<self.size {
    let (data, time, diff) = (self.read)(index)
    visit(data, time, diff)
  }
}

///|
pub fn[D, T, R] BatchView::to_array(
  self : BatchView[D, T, R],
) -> Array[(D, T, R)] {
  Array::makei(self.size, self.read)
}

///|
pub fn[K : Compare, V, T, R] BatchView::for_key(
  self : BatchView[(K, V), T, R],
  key : K,
  visit : (V, T, R) -> Unit,
) -> Unit {
  let mut lower = 0
  let mut upper = self.size
  while lower < upper {
    let middle = lower + (upper - lower) / 2
    if Compare::compare((self.read)(middle).0.0, key) < 0 {
      lower = middle + 1
    } else {
      upper = middle
    }
  }
  while lower < self.size {
    let ((found, value), time, diff) = (self.read)(lower)
    if found != key {
      break
    }
    visit(value, time, diff)
    lower += 1
  }
}

///|
/// Map a batch into a refined timestamp domain. The mapping must be monotonic
/// and preserve the interval and compaction laws; product entry is a typical use.
pub fn[D, T, U : Lattice, R] BatchView::map_times(
  self : BatchView[D, T, R],
  lift : (T) -> U,
) -> BatchView[D, U, R] {
  {
    size: self.size,
    read: fn(index) {
      let (data, time, diff) = (self.read)(index)
      (data, lift(time), diff)
    },
    description: Description(
      Antichain(self.description.lower.elements.map(lift)),
      Antichain(self.description.upper.elements.map(lift)),
      Antichain(self.description.since.elements.map(lift)),
    ),
  }
}

///|
pub fn[K : Compare, V : Compare, T, R] BatchView::cursor(
  self : BatchView[(K, V), T, R],
) -> Cursor[K, V, T, R] {
  Cursor([self])
}

///|
pub fn[D, T, R] BatchView::is_empty(self : BatchView[D, T, R]) -> Bool {
  self.size == 0
}
