///|
/// Import a trace's retained state and subsequent sealed batches into a scope.
/// The imported data represents snapshots at or beyond this reader's logical
/// frontier. Its independent reader is released on closure or worker disposal.
pub fn[D : Compare, T : Lattice, R : Semigroup, S] TraceReader::import_into(
  self : TraceReader[D, T, R],
  scope : Scope[T, S],
) -> Collection[D, T, R] {
  self.check()
  let base = self.logical_compaction()
  let output : Channel[D, T, R] = Channel(
    scope.worker.scheduler,
    Antichain([scope.minimum]),
    context=scope.context,
  )
  if base.is_empty() {
    return { worker: scope.worker, channel: output, }
  }
  let reader = self.clone()
  let cancel : Ref[() -> Unit] = Ref(fn() { () })
  let held = Ref(Antichain([scope.minimum]))
  for time in held.val.elements {
    output.hold(time, 1)
  }
  let frames : Array[Frame[D, T, R]] = []
  let initial = []
  reader.map_batches(fn(batch) {
    batch.for_each(fn(data, time, diff) { initial.push((data, time, diff)) })
  })
  frames.push(Data(initial))
  frames.push(Progress(reader.upper()))
  let pending = scope.context.pending
  let port = output.port
  let cleanup = fn() {
    (cancel.val)()
    for time in held.val.elements {
      pending.update((port, time), -1)
    }
    held.val = Antichain([])
    reader.release()
    frames.clear()
  }
  let task = scope.worker.register(fn() {
    let events = frames.copy()
    frames.clear()
    for frame in events {
      match frame {
        Data(updates) =>
          output.data(
            consolidate_updates(
              updates.map(fn(u) { (u.0, advance_by(u.1, base), u.2) }),
            ),
          )
        Progress(frontier) => {
          let next = Antichain(frontier.elements)
          for time in next.elements {
            output.hold(time, 1)
          }
          for time in held.val.elements {
            output.hold(time, -1)
          }
          held.val = next
          reader.set_logical_compaction(
            reader.logical_compaction().join(frontier),
          )
          reader.set_physical_compaction(
            reader.physical_compaction().join(frontier),
          )
          if frontier.is_empty() {
            cleanup()
          }
        }
      }
    }
  })
  (scope.context.own_task)(task)
  let scheduler = scope.worker.scheduler
  cancel.val = reader.subscribe(fn(batch) {
    frames.push(Data(batch.to_array()))
    frames.push(Progress(batch.description.upper()))
    scheduler.schedule(task)
  })
  scheduler.schedule(task)
  scheduler.slots[task].input_done.push(fn() {
    frames.is_empty() && held.val.is_empty()
  })
  let frontier = output.frontier
  scheduler.slots[task].output_done.push(fn() { frontier.val.is_empty() })
  scope.worker.on_task_shutdown(task, cleanup)
  { worker: scope.worker, channel: output, }
}

///|
/// Import through an independent storage-neutral reader capability.
pub fn[D : Compare, T : Lattice, R : Semigroup, S] TraceAgent::import_into(
  self : TraceAgent[D, T, R],
  scope : Scope[T, S],
) -> Collection[D, T, R] {
  let reader = self.reader()
  defer reader.release()
  reader.import_into(scope)
}
