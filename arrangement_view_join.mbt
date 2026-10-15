///|
/// Join two arrangements using their shared batch indexes. Each operator owns
/// independent compaction capabilities, but no private copy of either history.
/// Each activation performs at most fuel cursor/emission steps and retains
/// output capabilities until pending work finishes. Build before execution.
pub fn[K : Compare, V, W, D, T : Lattice, R, S, O] ArrangementView::join_map(
  self : ArrangementView[K, V, T, R],
  other : ArrangementView[K, W, T, S],
  logic : (K, V, W) -> D,
  multiply~ : (R, S) -> O,
  fuel~ : Int32 = 100000,
) -> Collection[D, T, O] {
  guard fuel > 0 else { abort("join fuel must be positive") }
  same_worker(self.collection, other.collection)
  let reader1 = self.trace.clone()
  let reader2 = other.trace.clone()
  let batches1 : Array[(BatchView[(K, V), T, R], Antichain[T])] = []
  let batches2 : Array[(BatchView[(K, W), T, S], Antichain[T])] = []
  let ack1 = Ref(reader1.upper())
  let ack2 = Ref(reader2.upper())
  let frontier1 = Ref(Antichain(self.collection.channel.frontier.val.elements))
  let frontier2 = Ref(Antichain(other.collection.channel.frontier.val.elements))
  let output : Channel[D, T, O] = self.collection.channel.output(
    frontier=Antichain(frontier1.val.elements + frontier2.val.elements),
  )
  let input1 : Mailbox[(K, V), T, R] = Mailbox()
  let input2 : Mailbox[(K, W), T, S] = Mailbox()
  let jobs : Array[JoinWork[D, T, O]] = []
  let head = Ref(0)
  let task_slot = Ref(-1)
  let scheduler = self.collection.worker.scheduler
  let cancel1 : Ref[() -> Unit] = Ref(fn() { () })
  let cancel2 : Ref[() -> Unit] = Ref(fn() { () })
  let cleanup = fn() {
    (cancel1.val)()
    (cancel2.val)()
    batches1.clear()
    batches2.clear()
    jobs.clear()
    head.val = 0
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
    for (batch, lower) in batches1 {
      // New left deltas see the acknowledged right cut. New right deltas then
      // see the updated left cut, counting each pair exactly once.
      jobs.push(
        join_work(
          batch,
          lower,
          reader2.batches_through(ack2.val).unwrap(),
          logic,
          multiply,
        ),
      )
      ack1.val = batch.description.upper()
    }
    batches1.clear()
    for (batch, lower) in batches2 {
      jobs.push(
        join_work(
          batch,
          lower,
          reader1.batches_through(ack1.val).unwrap(),
          fn(k, w, v) { logic(k, v, w) },
          fn(s, r) { multiply(r, s) },
        ),
      )
      ack2.val = batch.description.upper()
    }
    batches2.clear()
    let results = []
    let released = []
    for _ in 0..<fuel {
      if head.val == jobs.length() {
        break
      }
      let job = jobs[head.val]
      let (update, done) = (job.step)()
      if update is Some(update) {
        results.push(update)
      }
      if done {
        for time in job.lower.elements {
          released.push(time)
        }
        head.val += 1
      }
    }
    output.data(results)
    for time in released {
      output.hold(time, -1)
    }
    if head.val == jobs.length() {
      jobs.clear()
      head.val = 0
    } else {
      if head.val > 0 {
        let retained = jobs[head.val:].to_owned()
        jobs.clear()
        for job in retained {
          jobs.push(job)
        }
        head.val = 0
      }
      scheduler.schedule(task_slot.val)
    }
    let frontier = Antichain(frontier1.val.elements + frontier2.val.elements)
    for job in jobs {
      for time in job.lower.elements {
        let _ = frontier.insert(time)
      }
    }
    output.progress(frontier)
    if frontier1.val.is_empty() && frontier2.val.is_empty() && jobs.is_empty() {
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
  task_slot.val = task
  input1.task = task
  input2.task = task
  self.collection.channel.subscribe(input1)
  other.collection.channel.subscribe(input2)
  output.depends_on(input1)
  output.depends_on(input2)
  cancel1.val = reader1.subscribe(fn(batch) {
    let lower = Antichain([])
    batch.for_each(fn(_, time, _) { let _ = lower.insert(time) })
    for time in lower.elements {
      output.hold(time, 1)
    }
    batches1.push((batch, lower))
    scheduler.schedule(task)
  })
  cancel2.val = reader2.subscribe(fn(batch) {
    let lower = Antichain([])
    batch.for_each(fn(_, time, _) { let _ = lower.insert(time) })
    for time in lower.elements {
      output.hold(time, 1)
    }
    batches2.push((batch, lower))
    scheduler.schedule(task)
  })
  self.collection.worker.cleanup.push(cleanup)
  { worker: self.collection.worker, channel: output, }
}

///|
pub fn[K : Compare, V, W, T : Lattice] ArrangementView::join(
  self : ArrangementView[K, V, T, Int64],
  other : ArrangementView[K, W, T, Int64],
  fuel~ : Int32 = 100000,
) -> Collection[(K, (V, W)), T, Int64] {
  self.join_map(
    other,
    fn(key, v, w) { (key, (v, w)) },
    multiply=fn(a, b) { a * b },
    fuel~,
  )
}
