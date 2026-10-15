///|
/// A lazy immutable batch view. Timestamp adaptation retains the backing batch;
/// it does not copy or rebuild the stored update array.
pub struct BatchView[D, T, R] {
  priv size : Int32
  priv read : (Int32) -> (D, T, R)
  priv description : Description[T]
  priv visible : (Int32) -> Bool
}

///|
pub fn[D, T, R] Batch::view(self : Batch[D, T, R]) -> BatchView[D, T, R] {
  {
    size: self.updates.length(),
    visible: fn(_) { true },
    read: self.updates.reader().read,
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
  if index < 0 || index >= self.size || !(self.visible)(index) {
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
    if self.get(index) is Some((data, time, diff)) {
      visit(data, time, diff)
    }
  }
}

///|
pub fn[D, T, R] BatchView::to_array(
  self : BatchView[D, T, R],
) -> Array[(D, T, R)] {
  let result = []
  self.for_each(fn(data, time, diff) { result.push((data, time, diff)) })
  result
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
    if (self.visible)(lower) {
      visit(value, time, diff)
    }
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
  self.map_times_at(lift, fn(_, time) { lift(time) })
}

///|
/// Map record times using the data, while lifting metadata with the scope's
/// refinement. The assignment must preserve the refinement's progress laws.
pub fn[D, T, U : Lattice, R] BatchView::map_times_at(
  self : BatchView[D, T, R],
  lift : (T) -> U,
  assign : (D, T) -> U,
) -> BatchView[D, U, R] {
  {
    size: self.size,
    visible: self.visible,
    read: fn(index) {
      let (data, time, diff) = (self.read)(index)
      (data, assign(data, time), diff)
    },
    description: Description(
      Antichain(self.description.lower.elements.map(lift)),
      Antichain(self.description.upper.elements.map(lift)),
      Antichain(self.description.since.elements.map(lift)),
    ),
  }
}

///|
/// Advance visible times by since, then suppress times at or beyond until.
/// Like upstream BatchFrontier, length, metadata and cursor keys are unchanged.
pub fn[D, T : Lattice, R] BatchView::frontier(
  self : BatchView[D, T, R],
  since : Antichain[T],
  until : Antichain[T],
) -> BatchView[D, T, R] {
  let since = Antichain(since.elements)
  let until = Antichain(until.elements)
  {
    size: self.size,
    description: self.description,
    read: fn(index) {
      let (data, time, diff) = (self.read)(index)
      (data, advance_by(time, since), diff)
    },
    visible: fn(index) {
      (self.visible)(index) &&
      !until.less_equal(advance_by((self.read)(index).1, since))
    },
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
