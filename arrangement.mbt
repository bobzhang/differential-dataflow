///|
/// A shared, sealed key/value index and its consolidated update stream.
pub struct Arranged[K, V, T, R] {
  priv collection : Collection[(K, V), T, R]
  priv trace : TraceAgent[(K, V), T, R]
}

///|
/// Clone an independent reader capability. Release it explicitly after use.
pub fn[K, V, T : Lattice, R] Arranged::trace(
  self : Arranged[K, V, T, R],
) -> TraceAgent[(K, V), T, R] {
  self.trace.clone()
}

///|
pub fn[K, V, T, R] Arranged::as_collection(
  self : Arranged[K, V, T, R],
) -> Collection[(K, V), T, R] {
  self.collection
}

///|
/// Release the arrangement handle's own reader; cloned readers remain valid.
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] Arranged::release(
  self : Arranged[K, V, T, R],
) -> Unit {
  self.trace.release()
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] Collection::arrange_by_key(
  self : Collection[(K, V), T, R],
  fueled~ : Bool = false,
  columnar~ : Bool = false,
  spill? : SpillPolicy[(K, V), T, R],
) -> Arranged[K, V, T, R] {
  let (writer, trace) = shared_trace_at(self.channel.frontier.val, fueled~)
  let output : Channel[(K, V), T, R] = self.channel.output()
  let pending : Ref[Array[((K, V), T, R)]] = Ref([])
  let input : Mailbox[(K, V), T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
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
          let lower = writer.upper()
          if lower.elements != frontier.elements {
            let batch = Batch(ready, lower~, upper=frontier)
            let batch = if columnar { batch.columnar().batch() } else { batch }
            let batch = match spill {
              Some(policy) => batch.spill(policy)
              None => batch
            }
            writer.insert(batch)
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
  // Rust TraceWriter::drop seals an empty final batch. Surviving imports must
  // receive the same closure even when the producer is explicitly disposed.
  self.worker.on_task_shutdown(input.task, fn() {
    pending.val.clear()
    writer.close()
  })
  { collection: { worker: self.worker, channel: output, }, trace, }
}

///|
pub fn[K : Compare, T : Lattice, R : Semigroup] Collection::arrange_by_self(
  self : Collection[K, T, R],
  fueled~ : Bool = false,
  columnar~ : Bool = false,
  spill? : SpillPolicy[(K, Unit), T, R],
) -> Arranged[K, Unit, T, R] {
  self.map(fn(key) { (key, ()) }).arrange_by_key(fueled~, columnar~, spill?)
}
