///|
test "typed logger batches, replacement and callback reentry preserve ownership" {
  let now = Ref(@differential.Duration(0UL))
  let batches = []
  let recursive : Ref[@differential.Logger[Int32]?] = Ref(None)
  let logger = @differential.Logger(clock=fn() { now.val }, capacity=2, publish=fn(
    t,
    batch,
  ) {
    batches.push((t, batch))
    if !batch.is_empty() && batch[0].1 == 1 {
      recursive.val.unwrap().log(3)
      recursive.val.unwrap().flush()
    }
  })
  recursive.val = Some(logger)
  let registry = @differential.LogRegistry()
  assert_true(registry.insert("test", logger) is None)
  logger.log(1)
  now.val = Duration(1UL)
  logger.log(2)
  assert_eq(batches, [(Duration(1UL), [(Duration(0UL), 1), (Duration(1UL), 2)])])
  assert_eq(logger.pending(), 1)
  registry.flush()
  assert_eq(batches[1], (Duration(1UL), [(Duration(1UL), 3)]))
  let replacement_events = []
  let replacement = @differential.Logger(clock=fn() { now.val }, publish=fn(
    _,
    rows,
  ) {
    for (_, value) in rows {
      replacement_events.push(value)
    }
  })
  let old = registry.insert("test", replacement).unwrap()
  old.log(4)
  registry.get("test").unwrap().log(5)
  registry.flush()
  assert_eq(replacement_events, [5])
  assert_eq(old.pending(), 1)
  old.flush()
  assert_eq(batches[2].1, [(Duration(1UL), 4)])
  let removed = registry.remove("test").unwrap()
  assert_true(registry.get("test") is None)
  removed.log(6)
  removed.flush()
  assert_eq(replacement_events, [5, 6])
  recursive.val = None
}

///|
fn logging_balances(
  events : Array[(@differential.Duration, @differential.DifferentialEvent)],
) -> (Int32, Int32, Int32, Int32) {
  let mut resident = 0
  let mut shares = 0
  let mut pending = 0
  let mut merges = 0
  for (_, event) in events {
    match event {
      BatchCreated(e) => resident += e.length
      BatchDropped(e) => resident -= e.length
      MergeProgress(e) =>
        if e.complete is Some(n) {
          resident += n - e.length1 - e.length2
          merges += 1
        }
      TraceShare(e) => shares += e.diff
      BatcherSize(e) => {
        pending += e.records_diff
        guard e.size_diff is None &&
          e.capacity_diff is None &&
          e.allocations_diff is None else {
          abort("managed memory must not invent byte accounting")
        }
      }
      MergeShortfall(_) => ()
    }
    guard resident >= 0 && shares >= 0 && pending >= 0 else {
      abort("negative diagnostic balance")
    }
  }
  (resident, shares, pending, merges)
}

///|
test "trace diagnostics balance through compaction, pinned readers and final release" {
  for fueled in [false, true] {
    let events = []
    let logger = @differential.Logger(clock=fn() { Duration(0UL) }, publish=fn(
      _,
      rows,
    ) {
      for row in rows {
        events.push(row)
      }
    })
    let trace_logger = @differential.TraceLogger(logger, operator=7)
    let (writer, reader) : (
      @differential.TraceWriter[Int32, UInt64, Int64],
      @differential.TraceAgent[Int32, UInt64, Int64],
    ) = if fueled {
      @differential.shared_spine(0UL, logger=trace_logger)
    } else {
      @differential.shared_trace(0UL, logger=trace_logger)
    }
    let pin = reader.clone()
    for epoch in 0..<24 {
      let t = epoch.to_uint64()
      writer.insert(
        Batch(
          [(epoch % 3, t, 1L), ((epoch + 1) % 3, t, -1L)],
          lower=Antichain([t]),
          upper=Antichain([t + 1]),
        ),
      )
      reader.set_logical_compaction(Antichain([t + 1]))
      reader.set_physical_compaction(Antichain([t + 1]))
      if epoch >= 3 {
        pin.set_logical_compaction(Antichain([t - 2]))
        pin.set_physical_compaction(Antichain([t - 2]))
      }
      logger.flush()
      let mut actual = 0
      pin.map_batches(fn(b) { actual += b.length() })
      let balance = logging_balances(events)
      assert_eq(balance.0, actual)
      assert_eq(balance.1, 2)
    }
    writer.close()
    reader.release()
    logger.flush()
    assert_eq(logging_balances(events).1, 1)
    pin.release()
    pin.release()
    logger.flush()
    let balance = logging_balances(events)
    assert_eq((balance.0, balance.1, balance.2), (0, 0, 0))
    assert_true(balance.3 > 0)
  }
}

///|
test "arrangements retain logging sinks and balance pending records on cancellation" {
  let worker = @differential.Worker()
  let events = []
  let logger = @differential.Logger(clock=fn() { Duration(0UL) }, publish=fn(
    _,
    rows,
  ) {
    for row in rows {
      events.push(row)
    }
  })
  let _ = worker.differential_logs().insert("differential/arrange", logger)
  let scope = worker.scope(0UL, @differential.SummaryDomain::uint64())
  let (input, stream) : (
    @differential.InputSession[(Int32, Int32), UInt64, Int64],
    @differential.Collection[(Int32, Int32), UInt64, Int64],
  ) = scope.input()
  let arranged = stream.arrange_by_key(fueled=true, columnar=true)
  let pin = arranged.trace()
  let _ = worker.differential_logs().remove("differential/arrange")
  input.update_at((1, 2), 10UL, 1L)
  input.update_at((1, 3), 0UL, 1L)
  input.advance_to(1UL)
  input.flush()
  let _ = worker.run()
  logger.flush()
  let first = logging_balances(events)
  assert_eq((first.0, first.1, first.2), (1, 2, 1))
  worker.dispose()
  logger.flush()
  assert_eq(logging_balances(events).2, 0)
  assert_true(pin.upper().is_empty())
  arranged.release()
  pin.release()
  logger.flush()
  let finished = logging_balances(events)
  assert_eq((finished.0, finished.1, finished.2), (0, 0, 0))
}

///|
test "batcher logging follows consolidated retained records and explicit abandonment" {
  let events = []
  let logger = @differential.Logger(clock=fn() { Duration(0UL) }, publish=fn(
    _,
    rows,
  ) {
    for row in rows {
      events.push(row)
    }
  })
  let batcher : @differential.Batcher[Int32, UInt64, Int64] = Batcher(
    0UL,
    logger=TraceLogger(logger, operator=9),
  )
  batcher.push([(1, 0UL, 1L), (1, 0UL, -1L), (2, 1UL, 2L), (3, 5UL, 3L)])
  logger.flush()
  assert_eq(logging_balances(events).2, 2)
  let _ = batcher.seal(Antichain([2UL]))
  logger.flush()
  assert_eq(logging_balances(events).2, 1)
  batcher.dispose()
  batcher.dispose()
  logger.flush()
  assert_eq(logging_balances(events).2, 0)
}

///|
test "empty logging flush advances time and grouped events share one timestamp" {
  let clock = Ref(0UL)
  let batches = []
  let logger = @differential.Logger(
    clock=fn() {
      let time = @differential.Duration(clock.val)
      clock.val += 1
      time
    },
    publish=fn(time, events) { batches.push((time, events)) },
  )
  logger.flush()
  assert_eq(batches[0], (Duration(0UL), []))
  logger.log_many([1, 2, 3])
  logger.flush()
  assert_eq(
    batches[1],
    (
      Duration(2UL),
      [(Duration(1UL), 1), (Duration(1UL), 2), (Duration(1UL), 3)],
    ),
  )
}
