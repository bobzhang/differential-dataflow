///|
priv struct ReaderBounds[T] {
  logical : Antichain[T]
  physical : Antichain[T]
}

///|
priv struct SharedTrace[D, T, R] {
  trace : Trace[D, T, R]
  mut spine : Spine[D, T, R]?
  readers : Map[Int32, ReaderBounds[T]]
  listeners : Map[Int32, (Batch[D, T, R]) -> Unit]
  mut next_listener : Int32
  mut next_id : Int32
}

///|
/// A writer seals contiguous intervals; compaction is governed by all live readers.
pub struct TraceWriter[D, T, R] {
  priv shared : SharedTrace[D, T, R]
}

///|
/// An independently owned trace reader. Clone to retain a separate compaction
/// capability, and release explicitly when the reader is no longer needed.
pub struct TraceAgent[D, T, R] {
  priv shared : SharedTrace[D, T, R]
  priv id : Int32
  priv mut live : Bool
}

///|
pub fn[D, T : Lattice, R] shared_trace(
  minimum : T,
  logger? : TraceLogger,
) -> (TraceWriter[D, T, R], TraceAgent[D, T, R]) {
  shared_trace_at(Antichain([minimum]), logger?)
}

///|
fn[D, T : Lattice, R] shared_trace_at(
  frontier : Antichain[T],
  fueled~ : Bool = false,
  logger? : TraceLogger,
) -> (TraceWriter[D, T, R], TraceAgent[D, T, R]) {
  guard !frontier.is_empty() else {
    abort("trace requires a nonempty initial frontier")
  }
  let shared : SharedTrace[D, T, R] = {
    trace: {
      logger,
      batches: [],
      upper: Antichain(frontier.elements),
      logical: Antichain(frontier.elements),
      physical: Antichain(frontier.elements),
    },
    spine: None,
    readers: Map([
      (
        0,
        {
          logical: Antichain(frontier.elements),
          physical: Antichain(frontier.elements),
        },
      ),
    ]),
    next_id: 1,
    listeners: Map([]),
    next_listener: 0,
  }
  if fueled {
    let minimum = frontier.elements
      .iter()
      .fold(init=frontier.elements[0], fn(a, b) { a.meet(b) })
    shared.spine = Some({
      trace: shared.trace,
      minimum,
      merging: None,
      exert_logic: fn(_) { Some(1024) },
    })
  }
  if logger is Some(logger) {
    logger.share(1)
  }
  ({ shared, }, { shared, id: 0, live: true, })
}

///|
fn[D, T, R] TraceAgent::check(self : TraceAgent[D, T, R]) -> Unit {
  guard self.live else { abort("trace reader was released") }
}

///|
pub fn[D, T : Lattice, R] TraceAgent::clone(
  self : TraceAgent[D, T, R],
) -> TraceAgent[D, T, R] {
  self.check()
  let bounds = self.shared.readers.get(self.id).unwrap()
  let id = self.shared.next_id
  self.shared.next_id += 1
  self.shared.readers[id] = {
    logical: Antichain(bounds.logical.elements),
    physical: Antichain(bounds.physical.elements),
  }
  if self.shared.trace.logger is Some(logger) {
    logger.share(1)
  }
  { shared: self.shared, id, live: true, }
}

///|
fn[D : Compare, T : Lattice, R : Semigroup] SharedTrace::compact(
  self : SharedTrace[D, T, R],
) -> Unit {
  let logical = Antichain([])
  let physical = Antichain([])
  for _, bounds in self.readers {
    for time in bounds.logical.elements {
      let _ = logical.insert(time)
    }
    for time in bounds.physical.elements {
      let _ = physical.insert(time)
    }
  }
  match self.spine {
    None => {
      self.trace.set_logical_compaction(logical)
      self.trace.set_physical_compaction(physical)
    }
    Some(spine) => {
      spine.set_logical_compaction(logical)
      spine.set_physical_compaction(physical)
      spine.exert()
    }
  }
  if logical.is_empty() && physical.is_empty() {
    if self.spine is Some(spine) {
      spine.merging = None
    }
    self.trace.drop_batches()
  }
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceAgent::release(
  self : TraceAgent[D, T, R],
) -> Unit {
  if self.live {
    self.shared.readers.remove(self.id)
    self.live = false
    if self.shared.trace.logger is Some(logger) {
      logger.share(-1)
    }
    self.shared.compact()
  }
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceAgent::set_logical_compaction(
  self : TraceAgent[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  self.check()
  let bounds = self.shared.readers.get(self.id).unwrap()
  // Each request contributes a compaction guarantee. Upstream TraceAgent joins
  // it with the reader's existing guarantee, including incomparable or older
  // requests, rather than rejecting requests that are not monotone on their own.
  self.shared.readers[self.id] = {
    logical: bounds.logical.join(frontier),
    physical: bounds.physical,
  }
  self.shared.compact()
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceAgent::set_physical_compaction(
  self : TraceAgent[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  self.check()
  let bounds = self.shared.readers.get(self.id).unwrap()
  self.shared.readers[self.id] = {
    logical: bounds.logical,
    physical: bounds.physical.join(frontier),
  }
  self.shared.compact()
}

///|
pub fn[D, T : Lattice, R] TraceAgent::logical_compaction(
  self : TraceAgent[D, T, R],
) -> Antichain[T] {
  self.check()
  Antichain(self.shared.readers.get(self.id).unwrap().logical.elements)
}

///|
pub fn[D, T : Lattice, R] TraceAgent::physical_compaction(
  self : TraceAgent[D, T, R],
) -> Antichain[T] {
  self.check()
  Antichain(self.shared.readers.get(self.id).unwrap().physical.elements)
}

///|
pub fn[D, T : Lattice, R] TraceAgent::upper(
  self : TraceAgent[D, T, R],
) -> Antichain[T] {
  self.check()
  self.shared.trace.upper()
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceAgent::snapshot(
  self : TraceAgent[D, T, R],
  time : T,
) -> Array[(D, R)] {
  self.check()
  guard self.logical_compaction().less_equal(time) else {
    abort("query precedes reader logical compaction")
  }
  self.shared.trace.snapshot(time)
}

///|
pub fn[D, T : Lattice, R] TraceAgent::batches_through(
  self : TraceAgent[D, T, R],
  upper : Antichain[T],
) -> Array[Batch[D, T, R]]? {
  self.check()
  guard self.physical_compaction().precedes(upper) else { return None }
  self.shared.trace.batches_through(upper)
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceWriter::insert(
  self : TraceWriter[D, T, R],
  batch : Batch[D, T, R],
) -> Unit {
  match self.shared.spine {
    None => self.shared.trace.insert(batch)
    Some(spine) => spine.insert(batch)
  }
  self.shared.compact()
  for _, notify in self.shared.listeners {
    notify(batch)
  }
}

///|
pub fn[D, T : Lattice, R] TraceWriter::upper(
  self : TraceWriter[D, T, R],
) -> Antichain[T] {
  self.shared.trace.upper()
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] TraceAgent::cursor(
  self : TraceAgent[(K, V), T, R],
) -> Cursor[K, V, T, R] {
  self.check()
  self.shared.trace.cursor()
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceWriter::close(
  self : TraceWriter[D, T, R],
) -> Unit {
  if !self.upper().is_empty() {
    self.insert(Batch::empty(lower=self.upper(), upper=Antichain([])))
  }
}

///|
pub fn[D, T, R] TraceAgent::map_batches(
  self : TraceAgent[D, T, R],
  visit : (Batch[D, T, R]) -> Unit,
) -> Unit {
  self.check()
  self.shared.trace.map_batches(visit)
}

///|
pub fn[D, T : Lattice, R] TraceAgent::advance_upper(
  self : TraceAgent[D, T, R],
  upper : Antichain[T],
) -> Antichain[T] {
  self.check()
  self.shared.trace.advance_upper(upper)
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] TraceAgent::cursor_through(
  self : TraceAgent[(K, V), T, R],
  upper : Antichain[T],
) -> Cursor[K, V, T, R]? {
  self.check()
  guard self.physical_compaction().precedes(upper) else { return None }
  self.shared.trace.cursor_through(upper)
}

///|
/// Shared trace with a fueled spine backend and independently pinned readers.
pub fn[D, T : Lattice, R] shared_spine(
  minimum : T,
  logger? : TraceLogger,
) -> (TraceWriter[D, T, R], TraceAgent[D, T, R]) {
  shared_trace_at(Antichain([minimum]), fueled=true, logger?)
}

///|
/// Request background merging. Eager traces have already performed this work.
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceWriter::exert(
  self : TraceWriter[D, T, R],
) -> Unit {
  if self.shared.spine is Some(spine) {
    spine.exert()
  }
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceAgent::exert(
  self : TraceAgent[D, T, R],
) -> Unit {
  self.check()
  if self.shared.spine is Some(spine) {
    spine.exert()
  }
}

///|
/// Configure fueled maintenance. This is only supported by shared_spine traces.
pub fn[D, T, R] TraceWriter::set_exert_logic(
  self : TraceWriter[D, T, R],
  logic : (Array[(Int32, Int32, Int32)]) -> Int32?,
) -> Unit {
  guard self.shared.spine is Some(spine) else {
    abort("exertion logic requires a fueled spine")
  }
  spine.set_exert_logic(logic)
}
