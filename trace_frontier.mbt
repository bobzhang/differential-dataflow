///|
/// Retain a frontier-filtered trace view. Compaction capabilities and batch cuts
/// still refer to the backing trace, exactly as for upstream TraceFrontier.
pub fn[D, T : Lattice, R] TraceReader::frontier(
  self : TraceReader[D, T, R],
  since : Antichain[T],
  until : Antichain[T],
) -> TraceReader[D, T, R] {
  trace_frontier_owned(
    self.clone(),
    Antichain(since.elements),
    Antichain(until.elements),
  )
}

///|
fn[D, T : Lattice, R] trace_frontier_owned(
  parent : TraceReader[D, T, R],
  since : Antichain[T],
  until : Antichain[T],
) -> TraceReader[D, T, R] {
  {
    copy_reader: fn() { trace_frontier_owned(parent.clone(), since, until) },
    drop_reader: fn() { parent.release() },
    read_upper: fn() { parent.upper() },
    read_logical: fn() { parent.logical_compaction() },
    read_physical: fn() { parent.physical_compaction() },
    compact_logical: fn(frontier) { parent.set_logical_compaction(frontier) },
    compact_physical: fn(frontier) { parent.set_physical_compaction(frontier) },
    read_batches: fn(upper) {
      parent
      .batches_through(upper)
      .map(fn(batches) {
        batches.map(fn(batch) { batch.frontier(since, until) })
      })
    },
    listen: fn(notify) {
      parent.subscribe(fn(batch) { notify(batch.frontier(since, until)) })
    },
    live: true,
  }
}
