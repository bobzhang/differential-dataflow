///|
// Exercise the public custom-storage adapter over the pinned-compatible shared
// trace. Separate black-box tests implement an independent four-column backend.
fn[D : Compare, T : @differential.Lattice, R : @differential.Semigroup] external_reader(
  agent : @differential.TraceAgent[D, T, R],
) -> @differential.TraceReader[D, T, R] {
  let base = agent.reader()
  agent.release()
  external_reader_from_view(base)
}

///|
fn[D, T, R] external_reader_from_view(
  base : @differential.TraceReader[D, T, R],
) -> @differential.TraceReader[D, T, R] {
  TraceReader(
    clone_reader=fn() { external_reader_from_view(base.clone()) },
    release_reader=fn() { base.release() },
    upper=fn() { base.upper() },
    logical_compaction=fn() { base.logical_compaction() },
    physical_compaction=fn() { base.physical_compaction() },
    set_logical_compaction=fn(frontier) {
      base.set_logical_compaction(frontier)
    },
    set_physical_compaction=fn(frontier) {
      base.set_physical_compaction(frontier)
    },
    batches_through=fn(frontier) { base.batches_through(frontier) },
    subscribe=fn(notify) { base.subscribe(notify) },
  )
}

///|
fn[D : Compare, T : @differential.Lattice, R : @differential.Semigroup] external_backend(
  frontier : @differential.Antichain[T],
) -> @differential.TraceBackend[D, T, R] {
  let (writer, reader) = @differential.shared_trace(frontier.to_array()[0])
  TraceBackend(
    external_reader(reader),
    insert=fn(batch) {
      writer.insert(
        Batch(
          batch.to_array(),
          lower=batch.description().lower(),
          upper=batch.description().upper(),
        ),
      )
    },
    close=fn() { writer.close() },
  )
}
