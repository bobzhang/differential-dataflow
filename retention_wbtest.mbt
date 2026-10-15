///|
test "compacted cancellation releases join index keys" {
  let state : Map[Int32, Array[(Int32, Int64, Int64)]] = Map([])
  for key in 0..<1000 {
    state[key] = [(1, 0L, 1L), (1, 1L, -1L)]
  }
  compact_join_state(state, Antichain([2L]))
  assert_true(state.is_empty())
}

///|
test "continuously active scheduler keeps bounded queue storage" {
  let worker = Worker()
  let scheduler = worker.scheduler
  let counters = [0, 0]
  let max_size = Ref(0)
  for index in 0..<2 {
    let _ = worker.register(fn() {
      if counters[index] < 3000 {
        counters[index] += 1
        scheduler.schedule(index)
      }
      if scheduler.queue.length() > max_size.val {
        max_size.val = scheduler.queue.length()
      }
    })
  }
  scheduler.schedule(0)
  scheduler.schedule(1)
  assert_eq(worker.run(), Quiescent(6002))
  assert_true(max_size.val <= 1025)
  assert_true(scheduler.queue.is_empty())
}

///|
test "counted feedback releases pointstamps over two thousand input epochs" {
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let (input, values) : (
    InputSession[Int32, Int64, Int64],
    Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (feedback, looped) = scope.feedback(1L)
  let all = values.concat(looped)
  feedback.connect(
    all.map(fn(x) { x + 1 }).filter(fn(x) { x < 4 }).consolidate(),
  )
  let total = Ref(0L)
  let probe = all.inspect(fn(_, _, r) { total.val += r })
  for epoch in 0L..<2000L {
    input.insert(0)
    input.advance_to((epoch + 1) * 8)
    input.flush()
    guard worker.run(max_steps=200) is Quiescent(_) else {
      fail("feedback stalled")
    }
    assert_eq(total.val, (epoch + 1) * 4)
    assert_true(!probe.less_than(input.time()))
    assert_eq(scope.progress.tracker.unwrap().counts.to_array().length(), 1)
    assert_true(scope.progress.pending.is_empty())
    assert_true(worker.scheduler.queue.is_empty())
  }
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_true(scope.progress.tracker.unwrap().counts.is_empty())
  worker.dispose()
}

///|
test "reduction compacts twenty thousand completed epochs to current state" {
  let state : Reduction[Int32, Int64, Int64, Int64, Int64] = Reduction()
  let visible : Map[Int64, Int64] = Map([])
  for epoch in 0L..<20000L {
    if epoch > 0 {
      state.update(0, epoch, -1)
    }
    state.update(0, epoch, 1)
    state.update(1, epoch, 1)
    let (ready, pending) = state.advance(Antichain([epoch + 1]), fn(values) {
      [(values.iter().fold(init=0L, fn(sum, entry) { sum + entry.1 }), 1L)]
    })
    for (value, _, diff) in ready {
      visible[value] = visible.get(value).unwrap_or(0) + diff
    }
    assert_true(pending.is_empty())
    assert_true(state.history.length() <= 2)
    assert_eq(state.emitted.length(), 1)
    assert_eq(visible.get(epoch + 2), Some(1L))
    if epoch > 0 {
      assert_eq(visible.get(epoch + 1), Some(0L))
    }
  }
}

///|
test "compacted reduction holds only unemitted corrections" {
  let state : Reduction[Int32, Int32, Product[Int64, Int64], Int64, Int64] = Reduction()
  state.update(0, Product(0, 1), 1)
  state.update(0, Product(1, 0), 1)
  let logic = fn(_ : Array[(Int32, Int64)]) { [(0, 1L)] }
  let (initial, _) = state.advance(Antichain([Product(1, 1)]), logic)
  assert_eq(initial.length(), 2)
  let (ready, _) = state.advance(Antichain([Product(2, 1)]), logic)
  assert_eq(ready, [(0, Product(1, 1), -1L)])
  let (unchanged, pending) = state.advance(Antichain([Product(2, 1)]), logic)
  assert_true(unchanged.is_empty())
  assert_true(pending.is_empty())
}

///|
test "shared trace releases pinned history when a slow reader exits" {
  let (writer, slow) : (
    TraceWriter[Int32, Int64, Int64],
    TraceAgent[Int32, Int64, Int64],
  ) = shared_trace(0)
  let fast = slow.clone()
  for epoch in 0L..<1000L {
    writer.insert(
      Batch(
        [(0, epoch, 1L)],
        lower=Antichain([epoch]),
        upper=Antichain([epoch + 1]),
      ),
    )
    fast.set_logical_compaction(Antichain([epoch + 1]))
    fast.set_physical_compaction(Antichain([epoch + 1]))
  }
  assert_eq(slow.snapshot(0), [(0, 1L)])
  assert_eq(writer.shared.trace.batches.length(), 1000)
  slow.release()
  assert_eq(writer.shared.trace.batches.length(), 1)
  assert_eq(writer.shared.trace.batches[0].updates.length(), 1)
  for epoch in 1000L..<2000L {
    writer.insert(
      Batch(
        [(0, epoch, 1L)],
        lower=Antichain([epoch]),
        upper=Antichain([epoch + 1]),
      ),
    )
    assert_eq(fast.snapshot(epoch), [(0, epoch + 1)])
    fast.set_logical_compaction(Antichain([epoch + 1]))
    fast.set_physical_compaction(Antichain([epoch + 1]))
    assert_eq(writer.shared.trace.batches.length(), 1)
    assert_eq(writer.shared.trace.batches[0].updates.length(), 1)
  }
  fast.release()
  assert_true(writer.shared.readers.is_empty())
  assert_true(writer.shared.trace.batches.is_empty())
}

///|
test "disposing an importer removes its listener and reader capability" {
  let (writer, reader) : (
    TraceWriter[Int32, Int64, Int64],
    TraceAgent[Int32, Int64, Int64],
  ) = shared_trace(0)
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let _ = reader.import_into(scope).probe()
  assert_eq(writer.shared.readers.length(), 2)
  assert_eq(writer.shared.listeners.length(), 1)
  worker.dispose()
  assert_eq(writer.shared.readers.length(), 1)
  assert_true(writer.shared.listeners.is_empty())
  writer.insert(
    Batch([(1, 0L, 1L)], lower=Antichain([0L]), upper=Antichain([1L])),
  )
  assert_eq(reader.snapshot(0), [(1, 1L)])
  reader.release()
}

///|
test "worker disposal clears scoped progress and queued data even with a retained scope" {
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let (output, cap, values) : (
    Output[Int32, Int64, Int64, Int64],
    Capability[Int64, Int64],
    Collection[Int32, Int64, Int64],
  ) = scope.source()
  let _ = values.map(fn(x) { x + 1 }).probe()
  output.send(cap, Array::makei(1000, fn(i) { (i, 1L) }))
  worker.dispose()
  assert_true(scope.progress.observers.is_empty())
  assert_true(scope.progress.graph.edges.is_empty())
  assert_true(scope.progress.pending.is_empty())
  assert_true(scope.progress.tracker is None)
  assert_true(!cap.is_live())
  cap.release()
  assert_true(scope.progress.pending.is_empty())
}

///|
test "capture replay releases completed deduplication state over ten thousand intervals" {
  let replay : Replayer[Int32, Int64, Int64] = Replayer(0)
  for epoch in 0L..<10000L {
    assert_true(
      replay.push(
        Progress(
          CaptureProgress(Antichain([epoch]), Antichain([epoch + 1]), [
            (epoch, 1L),
          ]),
        ),
      )
      is None,
    )
    let (data, frontier) = replay.push(Updates([(1, epoch, 1L)])).unwrap()
    assert_eq(data, [(1, epoch, 1L)])
    assert_eq(frontier.to_array(), [epoch + 1])
    assert_true(replay.updates.is_empty())
    assert_true(replay.counts.updates().is_empty())
    assert_true(replay.statements.is_empty())
  }
}

///|
test "canceling replay after disposal does not retain dead progress counts" {
  let worker = Worker()
  let scope = worker.scope(0L, SummaryDomain::int64())
  let (replay, _) : (
    ReplayInput[Int32, Int64, Int64],
    Collection[Int32, Int64, Int64],
  ) = scope.replay()
  worker.dispose()
  replay.cancel()
  assert_true(scope.progress.pending.is_empty())
}

///|
test "worker group disposal clears global pointstamp ownership" {
  let group = WorkerGroup(2)
  let scopes = group.scopes(0L, SummaryDomain::int64())
  let inputs : Array[
    (InputSession[Int32, Int64, Int64], Collection[Int32, Int64, Int64]),
  ] = scopes.input()
  let outputs = scopes.exchange(inputs.map(fn(input) { input.1 }), fn(key) {
    key.to_uint64()
  })
  for stream in outputs {
    let _ = stream.probe()
  }
  inputs[0].0.insert(3)
  inputs[0].0.flush()
  let _ = group.run()
  assert_true(scopes.coordinator.tracker is Some(_))
  group.dispose()
  assert_true(scopes.coordinator.tracker is None)
  assert_true(scopes.coordinator.local_counts.is_empty())
  assert_true(scopes.coordinator.members.is_empty())
}
