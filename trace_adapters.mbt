///|
/// Adapt immutable external storage as an indexed batch. Rows must be sorted by
/// (data,time), consolidated, and consistent with description. The read callback
/// must return the same row for the lifetime of the view and retain its storage.
/// No eager row copy or scan is performed, so paged and columnar stores can remain
/// lazy. The callback is invoked only for indices in [0,length).
pub fn[D, T, R] BatchView::BatchView(
  length : Int32,
  description : Description[T],
  read~ : (Int32) -> (D, T, R),
) -> BatchView[D, T, R] {
  guard length >= 0 else { abort("batch length cannot be negative") }
  { size: length, read, description, visible: fn(_) { true }, }
}

///|
/// Adapt a custom trace implementation to the storage-neutral reader interface.
/// clone_reader must acquire an independent compaction pin; release_reader drops
/// this pin once. Frontiers and returned batch arrays must be owned snapshots.
/// batches_through must reject unavailable clean cuts. subscribe registers future
/// sealed batches and returns an idempotent cancellation function. Implementors
/// must enforce monotone compaction, preserve immutable retained batches, and
/// notify listeners only after making a newly sealed batch visible to reads.
pub fn[D, T, R] TraceReader::TraceReader(
  clone_reader~ : () -> TraceReader[D, T, R],
  release_reader~ : () -> Unit,
  upper~ : () -> Antichain[T],
  logical_compaction~ : () -> Antichain[T],
  physical_compaction~ : () -> Antichain[T],
  set_logical_compaction~ : (Antichain[T]) -> Unit,
  set_physical_compaction~ : (Antichain[T]) -> Unit,
  batches_through~ : (Antichain[T]) -> Array[BatchView[D, T, R]]?,
  subscribe~ : ((BatchView[D, T, R]) -> Unit) -> () -> Unit,
) -> TraceReader[D, T, R] {
  {
    copy_reader: clone_reader,
    drop_reader: release_reader,
    read_upper: upper,
    read_logical: logical_compaction,
    read_physical: physical_compaction,
    compact_logical: set_logical_compaction,
    compact_physical: set_physical_compaction,
    read_batches: batches_through,
    listen: subscribe,
    live: true,
  }
}

///|
/// A custom arrangement writer and its initial independently owned reader.
/// close must seal the trace at the empty upper frontier and notify imports;
/// the wrapper calls it at most once. The writer must not release the reader.
pub struct TraceBackend[D, T, R] {
  priv reader : TraceReader[D, T, R]
  priv write_batch : (BatchView[D, T, R]) -> Unit
  priv finish : () -> Unit
  priv build_batch : (Array[(D, T, R)], Description[T]) -> BatchView[D, T, R]
  priv mut closed : Bool
}

///|
pub fn[D : Compare, T : Lattice, R : Semigroup] TraceBackend::TraceBackend(
  reader : TraceReader[D, T, R],
  insert~ : (BatchView[D, T, R]) -> Unit,
  close~ : () -> Unit,
  build? : (Array[(D, T, R)], Description[T]) -> BatchView[D, T, R],
) -> TraceBackend[D, T, R] {
  {
    reader,
    write_batch: insert,
    finish: close,
    build_batch: build.unwrap_or(fn(rows, description) {
      Batch(rows, lower=description.lower(), upper=description.upper()).view()
    }),
    closed: false,
  }
}

///|
fn[D, T, R] TraceBackend::close(self : TraceBackend[D, T, R]) -> Unit {
  if !self.closed {
    self.closed = true
    (self.finish)()
  }
}

///|
/// Build an arrangement using custom storage. The factory receives the initial
/// frontier and transfers ownership of its returned reader to the arrangement.
/// The optional backend builder receives sorted, consolidated rows; its result
/// must preserve the supplied interval and rows. Shared joins, reductions,
/// nesting and imports operate through the same reader interface.
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] Collection::arrange_with(
  self : Collection[(K, V), T, R],
  factory : (Antichain[T]) -> TraceBackend[(K, V), T, R],
) -> ArrangementView[K, V, T, R] {
  let backend = factory(Antichain(self.channel.frontier.val.elements))
  let output : Channel[(K, V), T, R] = self.channel.output()
  let pending : Ref[Array[((K, V), T, R)]] = Ref([])
  let lower = Ref(backend.reader.upper())
  guard lower.val.elements == self.channel.frontier.val.elements else {
    abort("custom trace must start at the collection frontier")
  }
  let input : Mailbox[(K, V), T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(_, updates) =>
          for update in updates {
            pending.val.push(update)
            output.hold(update.1, 1)
          }
        Progress(frontier) => {
          let ready = []
          let retained = []
          for update in pending.val {
            if frontier.less_equal(update.1) {
              retained.push(update)
            } else {
              ready.push(update)
            }
          }
          pending.val = retained
          if lower.val.elements != frontier.elements {
            let batch = (backend.build_batch)(
              consolidate_updates(ready),
              Description(lower.val, frontier, lower.val),
            )
            guard batch.description().lower().elements == lower.val.elements &&
              batch.description().upper().elements == frontier.elements else {
              abort("custom batch builder changed the sealed interval")
            }
            (backend.write_batch)(batch)
            lower.val = Antichain(frontier.elements)
            output.data(batch.to_array())
          }
          for (_, time, _) in ready {
            output.hold(time, -1)
          }
          output.progress(frontier)
        }
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  self.worker.on_task_shutdown(input.task, fn() {
    pending.val.clear()
    backend.close()
  })
  {
    collection: { worker: self.worker, channel: output, },
    trace: backend.reader,
  }
}

///|
/// Import a custom or built-in keyed trace while retaining an independent reader
/// for indexed downstream operators. Both the import and returned view own pins.
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup, S] TraceReader::import_arranged(
  self : TraceReader[(K, V), T, R],
  scope : Scope[T, S],
) -> ArrangementView[K, V, T, R] {
  { collection: self.import_into(scope), trace: self.clone(), }
}
