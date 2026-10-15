///|
/// Buffered timestamped input. The delivery callback receives data before its new frontier.
/// Close explicitly to release the final capability; callbacks must not re-enter the session.
pub struct InputSession[D, T, R] {
  priv mut time : T
  priv mut frontier : Antichain[T]
  priv mut buffer : Array[(D, T, R)]
  priv limit : Int32
  priv deliver : (Array[(D, T, R)], Antichain[T]) -> Unit
  priv mut closed : Bool
  priv mut busy : Bool
}

///|
pub fn[D, T : Lattice, R] InputSession::InputSession(
  initial : T,
  deliver~ : (Array[(D, T, R)], Antichain[T]) -> Unit,
  buffer_limit~ : Int32 = 1024,
) -> InputSession[D, T, R] {
  guard buffer_limit > 0 else { abort("input buffer limit must be positive") }
  deliver([], Antichain([initial]))
  {
    time: initial,
    frontier: Antichain([initial]),
    buffer: [],
    limit: buffer_limit,
    deliver,
    closed: false,
    busy: false,
  }
}

///|
fn[D, T, R] InputSession::check(self : InputSession[D, T, R]) -> Unit {
  guard !self.closed else { abort("input session is closed") }
  guard !self.busy else { abort("input callback cannot re-enter its session") }
}

///|
pub fn[D, T, R] InputSession::time(self : InputSession[D, T, R]) -> T {
  self.time
}

///|
pub fn[D, T : Lattice, R] InputSession::frontier(
  self : InputSession[D, T, R],
) -> Antichain[T] {
  Antichain(self.frontier.elements)
}

///|
pub fn[D, T : Lattice, R] InputSession::update(
  self : InputSession[D, T, R],
  data : D,
  diff : R,
) -> Unit {
  self.update_at(data, self.time, diff)
}

///|
pub fn[D, T : Lattice, R] InputSession::update_at(
  self : InputSession[D, T, R],
  data : D,
  time : T,
  diff : R,
) -> Unit {
  self.check()
  guard self.time.less_equal(time) else {
    abort("input update precedes session time")
  }
  if self.buffer.length() >= self.limit {
    self.send(self.frontier)
  }
  self.buffer.push((data, time, diff))
}

///|
pub fn[D, T : Lattice] InputSession::insert(
  self : InputSession[D, T, Int64],
  data : D,
) -> Unit {
  self.update(data, 1)
}

///|
pub fn[D, T : Lattice] InputSession::remove(
  self : InputSession[D, T, Int64],
  data : D,
) -> Unit {
  self.update(data, -1)
}

///|
/// Advance local time. Progress is published only on flush or close.
pub fn[D, T : Lattice, R] InputSession::advance_to(
  self : InputSession[D, T, R],
  time : T,
) -> Unit {
  self.check()
  guard self.time.less_equal(time) else {
    abort("input time cannot move backward")
  }
  self.time = time
}

///|
fn[D, T : Lattice, R] InputSession::send(
  self : InputSession[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  self.busy = true
  let data = self.buffer
  self.buffer = []
  // The callback receives copies of frontier storage; it cannot mutate our capability.
  (self.deliver)(data, Antichain(frontier.elements))
  self.frontier = Antichain(frontier.elements)
  self.busy = false
}

///|
pub fn[D, T : Lattice, R] InputSession::flush(
  self : InputSession[D, T, R],
) -> Unit {
  self.check()
  self.send(Antichain([self.time]))
}

///|
pub fn[D, T : Lattice, R] InputSession::close(
  self : InputSession[D, T, R],
) -> Unit {
  self.check()
  self.send(Antichain([]))
  self.closed = true
}
