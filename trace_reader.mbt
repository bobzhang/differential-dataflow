///|
/// A trace-reader capability independent of storage and timestamp representation.
/// Clone retains an independent compaction capability. Release explicitly.
pub struct TraceReader[D, T, R] {
  priv copy_reader : () -> TraceReader[D, T, R]
  priv drop_reader : () -> Unit
  priv read_upper : () -> Antichain[T]
  priv read_logical : () -> Antichain[T]
  priv read_physical : () -> Antichain[T]
  priv compact_logical : (Antichain[T]) -> Unit
  priv compact_physical : (Antichain[T]) -> Unit
  priv read_batches : (Antichain[T]) -> Array[BatchView[D, T, R]]?
  priv listen : ((BatchView[D, T, R]) -> Unit) -> () -> Unit
  priv mut live : Bool
}

///|
fn[D, T, R] TraceReader::check(self : TraceReader[D, T, R]) -> Unit {
  guard self.live else { abort("trace reader was released") }
}

///|
pub fn[D, T, R] TraceReader::clone(
  self : TraceReader[D, T, R],
) -> TraceReader[D, T, R] {
  self.check()
  (self.copy_reader)()
}

///|
pub fn[D, T, R] TraceReader::release(self : TraceReader[D, T, R]) -> Unit {
  if self.live {
    self.live = false
    (self.drop_reader)()
  }
}

///|
pub fn[D, T, R] TraceReader::upper(self : TraceReader[D, T, R]) -> Antichain[T] {
  self.check()
  (self.read_upper)()
}

///|
pub fn[D, T, R] TraceReader::logical_compaction(
  self : TraceReader[D, T, R],
) -> Antichain[T] {
  self.check()
  (self.read_logical)()
}

///|
pub fn[D, T, R] TraceReader::physical_compaction(
  self : TraceReader[D, T, R],
) -> Antichain[T] {
  self.check()
  (self.read_physical)()
}

///|
pub fn[D, T, R] TraceReader::set_logical_compaction(
  self : TraceReader[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  self.check()
  (self.compact_logical)(frontier)
}

///|
pub fn[D, T, R] TraceReader::set_physical_compaction(
  self : TraceReader[D, T, R],
  frontier : Antichain[T],
) -> Unit {
  self.check()
  (self.compact_physical)(frontier)
}

///|
pub fn[D, T, R] TraceReader::batches_through(
  self : TraceReader[D, T, R],
  upper : Antichain[T],
) -> Array[BatchView[D, T, R]]? {
  self.check()
  (self.read_batches)(upper)
}

///|
fn[D, T, R] TraceReader::subscribe(
  self : TraceReader[D, T, R],
  notify : (BatchView[D, T, R]) -> Unit,
) -> () -> Unit {
  self.check()
  (self.listen)(notify)
}

///|
/// Retain a storage-independent reader over this shared trace.
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceAgent::reader(
  self : TraceAgent[D, T, R],
) -> TraceReader[D, T, R] {
  trace_reader_from_agent(self.clone())
}

///|
fn[D : Compare, T : Lattice, R : Semigroup] trace_reader_from_agent(
  agent : TraceAgent[D, T, R],
) -> TraceReader[D, T, R] {
  {
    copy_reader: fn() { trace_reader_from_agent(agent.clone()) },
    drop_reader: fn() { agent.release() },
    read_upper: fn() { agent.upper() },
    read_logical: fn() { agent.logical_compaction() },
    read_physical: fn() { agent.physical_compaction() },
    compact_logical: fn(frontier) { agent.set_logical_compaction(frontier) },
    compact_physical: fn(frontier) { agent.set_physical_compaction(frontier) },
    read_batches: fn(upper) {
      agent
      .batches_through(upper)
      .map(fn(batches) { batches.map(fn(batch) { batch.view() }) })
    },
    listen: fn(notify) {
      let shared = agent.shared
      let id = shared.next_listener
      shared.next_listener += 1
      shared.listeners[id] = fn(batch) { notify(batch.view()) }
      fn() { shared.listeners.remove(id) }
    },
    live: true,
  }
}

///|
/// Retain a view in a refined timestamp domain. Frontiers and exact batch cuts
/// project into the backing reader; returned compaction bounds are lifted back,
/// matching upstream TraceEnter. The functions must satisfy refinement laws.
pub fn[D, T : Lattice, U : Lattice, R] TraceReader::refine(
  self : TraceReader[D, T, R],
  lift~ : (T) -> U,
  project~ : (U) -> T,
) -> TraceReader[D, U, R] {
  trace_reader_refine_owned(self.clone(), lift, project)
}

///|
fn[D, T : Lattice, U : Lattice, R] trace_reader_refine_owned(
  parent : TraceReader[D, T, R],
  lift : (T) -> U,
  project : (U) -> T,
) -> TraceReader[D, U, R] {
  trace_reader_refine_at_owned(
    parent,
    lift,
    project,
    fn(_, time) { lift(time) },
    project,
  )
}

///|
/// Retain a data-dependent timestamp view. Exact cuts use project; compaction
/// capabilities use prior, which must conservatively invert the assignment.
pub fn[D, T : Lattice, U : Lattice, R] TraceReader::refine_at(
  self : TraceReader[D, T, R],
  lift~ : (T) -> U,
  project~ : (U) -> T,
  assign~ : (D, T) -> U,
  prior~ : (U) -> T,
) -> TraceReader[D, U, R] {
  trace_reader_refine_at_owned(self.clone(), lift, project, assign, prior)
}

///|
fn[D, T : Lattice, U : Lattice, R] trace_reader_refine_at_owned(
  parent : TraceReader[D, T, R],
  lift : (T) -> U,
  project : (U) -> T,
  assign : (D, T) -> U,
  prior : (U) -> T,
) -> TraceReader[D, U, R] {
  {
    copy_reader: fn() {
      trace_reader_refine_at_owned(parent.clone(), lift, project, assign, prior)
    },
    drop_reader: fn() { parent.release() },
    read_upper: fn() { Antichain(parent.upper().elements.map(lift)) },
    read_logical: fn() {
      Antichain(parent.logical_compaction().elements.map(lift))
    },
    read_physical: fn() {
      Antichain(parent.physical_compaction().elements.map(lift))
    },
    compact_logical: fn(frontier) {
      parent.set_logical_compaction(Antichain(frontier.elements.map(prior)))
    },
    compact_physical: fn(frontier) {
      parent.set_physical_compaction(Antichain(frontier.elements.map(prior)))
    },
    read_batches: fn(upper) {
      parent
      .batches_through(Antichain(upper.elements.map(project)))
      .map(fn(batches) {
        batches.map(fn(batch) { batch.map_times_at(lift, assign) })
      })
    },
    listen: fn(notify) {
      parent.subscribe(fn(batch) { notify(batch.map_times_at(lift, assign)) })
    },
    live: true,
  }
}

///|
pub fn[D, T : Lattice, U : Lattice, R] TraceReader::enter(
  self : TraceReader[D, T, R],
  minimum : U,
) -> TraceReader[D, Product[T, U], R] {
  self.refine(lift=fn(time) { Product(time, minimum) }, project=fn(time) {
    time.outer
  })
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceReader::snapshot(
  self : TraceReader[D, T, R],
  time : T,
) -> Array[(D, R)] {
  guard self.logical_compaction().less_equal(time) &&
    !self.upper().less_equal(time) else {
    abort("snapshot time must be complete and beyond logical compaction")
  }
  let result = []
  for batch in self.batches_through(Antichain([])).unwrap() {
    batch.for_each(fn(data, at, diff) {
      if at.less_equal(time) {
        result.push((data, diff))
      }
    })
  }
  consolidate(result)
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R] TraceReader::cursor(
  self : TraceReader[(K, V), T, R],
) -> Cursor[K, V, T, R] {
  self.cursor_through(Antichain([])).unwrap()
}

///|
pub fn[K : Compare, V : Compare, T, R] TraceReader::cursor_through(
  self : TraceReader[(K, V), T, R],
  upper : Antichain[T],
) -> Cursor[K, V, T, R]? {
  guard self.batches_through(upper) is Some(batches) else { return None }
  Some(Cursor(batches))
}

///|
pub fn[D, T : Lattice, R] TraceReader::map_batches(
  self : TraceReader[D, T, R],
  visit : (BatchView[D, T, R]) -> Unit,
) -> Unit {
  for batch in self.batches_through(Antichain([])).unwrap() {
    visit(batch)
  }
}

///|
pub fn[D, T : Lattice, R] TraceReader::advance_upper(
  self : TraceReader[D, T, R],
  upper : Antichain[T],
) -> Antichain[T] {
  let mut result = Antichain(upper.elements)
  self.map_batches(fn(batch) {
    if batch.is_empty() && batch.description.lower.elements == result.elements {
      result = batch.description.upper()
    }
  })
  result
}
