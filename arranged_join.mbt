///|
/// Visit a key's contiguous range in the immutable sorted batch. This searches
/// shared storage without materializing a cursor or copying unrelated keys.
pub fn[K : Compare, V, T, R] Batch::for_key(
  self : Batch[(K, V), T, R],
  key : K,
  visit : (V, T, R) -> Unit,
) -> Unit {
  let mut lower = 0
  let mut upper = self.updates.length()
  while lower < upper {
    let middle = lower + (upper - lower) / 2
    if Compare::compare(self.updates[middle].0.0, key) < 0 {
      lower = middle + 1
    } else {
      upper = middle
    }
  }
  while lower < self.updates.length() && self.updates[lower].0.0 == key {
    let ((_, value), time, diff) = self.updates[lower]
    visit(value, time, diff)
    lower += 1
  }
}

///|
/// Join two arrangements using their shared batch indexes. Each operator owns
/// independent compaction capabilities, but no private copy of either history.
/// Build before execution, like the other collection operators.
pub fn[
  K : Compare,
  V : Compare,
  W : Compare,
  D,
  T : Lattice,
  R : Semigroup,
  S : Semigroup,
  O,
] Arranged::join_map(
  self : Arranged[K, V, T, R],
  other : Arranged[K, W, T, S],
  logic : (K, V, W) -> D,
  multiply~ : (R, S) -> O,
) -> Collection[D, T, O] {
  same_worker(self.collection, other.collection)
  let reader1 = self.trace.clone()
  let reader2 = other.trace.clone()
  let shared1 = reader1.shared
  let shared2 = reader2.shared
  let batches1 : Array[Batch[(K, V), T, R]] = []
  let batches2 : Array[Batch[(K, W), T, S]] = []
  let ack1 = Ref(reader1.upper())
  let ack2 = Ref(reader2.upper())
  let frontier1 = Ref(Antichain(self.collection.channel.frontier.val.elements))
  let frontier2 = Ref(Antichain(other.collection.channel.frontier.val.elements))
  let output : Channel[D, T, O] = self.collection.channel.output(
    frontier=Antichain(frontier1.val.elements + frontier2.val.elements),
  )
  let input1 : Mailbox[(K, V), T, R] = Mailbox()
  let input2 : Mailbox[(K, W), T, S] = Mailbox()
  let listener1 = shared1.next_listener
  shared1.next_listener += 1
  let listener2 = shared2.next_listener
  shared2.next_listener += 1
  let cleanup = fn() {
    shared1.listeners.remove(listener1)
    shared2.listeners.remove(listener2)
    batches1.clear()
    batches2.clear()
    reader1.release()
    reader2.release()
  }
  let task = self.collection.worker.register(fn() {
    for frame in input1.drain() {
      if frame is Progress(frontier) {
        frontier1.val = frontier
      }
    }
    for frame in input2.drain() {
      if frame is Progress(frontier) {
        frontier2.val = frontier
      }
    }
    let results = []
    for batch in batches1 {
      // The shared trace may already contain later batches. Only the exact
      // acknowledged cut is eligible, otherwise a delta pair is counted twice.
      let history = reader2.batches_through(ack2.val).unwrap()
      for ((key, value), time, diff) in batch.updates {
        for previous in history {
          previous.for_key(key, fn(w, at, weight) {
            results.push(
              (logic(key, value, w), time.join(at), multiply(diff, weight)),
            )
          })
        }
      }
      ack1.val = batch.description.upper()
    }
    batches1.clear()
    for batch in batches2 {
      let history = reader1.batches_through(ack1.val).unwrap()
      for ((key, value), time, diff) in batch.updates {
        for previous in history {
          previous.for_key(key, fn(v, at, weight) {
            results.push(
              (logic(key, v, value), time.join(at), multiply(weight, diff)),
            )
          })
        }
      }
      ack2.val = batch.description.upper()
    }
    batches2.clear()
    output.data(results)
    output.progress(Antichain(frontier1.val.elements + frontier2.val.elements))
    if frontier1.val.is_empty() && frontier2.val.is_empty() {
      cleanup()
    } else {
      // An opposite future batch is at or beyond its input frontier. It can
      // therefore query this trace after advancing its logical compaction.
      reader1.set_logical_compaction(
        reader1.logical_compaction().join(frontier2.val),
      )
      reader2.set_logical_compaction(
        reader2.logical_compaction().join(frontier1.val),
      )
      reader1.set_physical_compaction(ack1.val)
      reader2.set_physical_compaction(ack2.val)
    }
  })
  input1.task = task
  input2.task = task
  self.collection.channel.subscribe(input1)
  other.collection.channel.subscribe(input2)
  output.depends_on(input1)
  output.depends_on(input2)
  let scheduler = self.collection.worker.scheduler
  shared1.listeners[listener1] = fn(batch) {
    batches1.push(batch)
    scheduler.schedule(task)
  }
  shared2.listeners[listener2] = fn(batch) {
    batches2.push(batch)
    scheduler.schedule(task)
  }
  self.collection.worker.cleanup.push(cleanup)
  { worker: self.collection.worker, channel: output, }
}

///|
pub fn[K : Compare, V : Compare, W : Compare, T : Lattice] Arranged::join(
  self : Arranged[K, V, T, Int64],
  other : Arranged[K, W, T, Int64],
) -> Collection[(K, (V, W)), T, Int64] {
  self.join_map(other, fn(key, v, w) { (key, (v, w)) }, multiply=fn(a, b) {
    a * b
  })
}
