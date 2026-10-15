///|
test "trace seals contiguous batches and preserves snapshots through compaction" {
  let trace : @differential.Trace[String, Int64, Int64] = Trace(0)
  trace.insert(
    Batch([("a", 0L, 1L)], lower=Antichain([0L]), upper=Antichain([2L])),
  )
  trace.insert(
    Batch(
      [("a", 2L, -1L), ("b", 3L, 2L)],
      lower=Antichain([2L]),
      upper=Antichain([4L]),
    ),
  )
  trace.insert(
    Batch([("b", 5L, -1L)], lower=Antichain([4L]), upper=Antichain([6L])),
  )
  assert_eq(trace.snapshot(1), [("a", 1L)])
  assert_eq(trace.snapshot(3), [("b", 2L)])
  assert_eq(trace.snapshot(5), [("b", 1L)])
  trace.set_logical_compaction(Antichain([3L]))
  trace.set_physical_compaction(Antichain([4L]))
  assert_eq(trace.snapshot(3), [("b", 2L)])
  assert_eq(trace.snapshot(5), [("b", 1L)])
  assert_true(trace.batches_through(Antichain([2L])) is None)
  assert_eq(trace.batches_through(Antichain([4L])).unwrap().length(), 1)
  assert_eq(trace.batches_through(Antichain([])).unwrap().length(), 2)
  let frontier = trace.logical_compaction()
  frontier.clear()
  assert_eq(trace.logical_compaction().to_array(), [3L])
  let batch = trace.batches_through(Antichain([4L])).unwrap()[0]
  let copy = batch.to_array()
  copy.clear()
  assert_eq(trace.snapshot(3), [("b", 2L)])
  trace.insert(
    Batch([("a", 6L, 1L)], lower=Antichain([6L]), upper=Antichain([])),
  )
  assert_eq(trace.snapshot(100), [("a", 1L), ("b", 1L)])
}

///|
test "product trace compaction preserves every permitted future query" {
  let updates = []
  for x in 0L..<10L {
    for y in 0L..<10L {
      updates.push(((x + y) % 3L, @differential.Product(x, y), x - y))
    }
  }
  let trace : @differential.Trace[
    Int64,
    @differential.Product[Int64, Int64],
    Int64,
  ] = Trace(Product(0, 0))
  trace.insert(
    Batch(updates, lower=Antichain([Product(0, 0)]), upper=Antichain([])),
  )
  let frontier = @differential.Antichain([
    @differential.Product(4L, 7L),
    Product(6L, 3L),
  ])
  trace.set_logical_compaction(frontier)
  trace.set_physical_compaction(Antichain([]))
  for x in 0L..<12L {
    for y in 0L..<12L {
      let time = @differential.Product(x, y)
      if frontier.less_equal(time) {
        let sums = Array::make(3, 0L)
        for (key, at, diff) in updates {
          if at.outer <= x && at.inner <= y {
            sums[key.to_int()] += diff
          }
        }
        let expected = [
          for k in 0..<3 if sums[k] != 0L => (k.to_int64(), sums[k])
        ]
        assert_eq(trace.snapshot(time), expected)
      }
    }
  }
}

///|
test "sustained trace updates with bounded compacted history" {
  let trace : @differential.Trace[Int32, Int64, Int64] = Trace(0)
  let counts = Array::make(17, 0L)
  let mut random = 11U
  for time in 0L..<1000L {
    let updates = []
    for _ in 0..<5 {
      random = random * 1664525U + 1013904223U
      let key = ((random >> 8) % 17U).reinterpret_as_int()
      let diff = (random % 5U).to_int64() - 2L
      counts[key] += diff
      updates.push((key, time, diff))
    }
    trace.insert(
      Batch(updates, lower=Antichain([time]), upper=Antichain([time + 1])),
    )
    trace.set_logical_compaction(Antichain([time]))
    trace.set_physical_compaction(Antichain([time]))
    assert_eq(
      trace.snapshot(time),
      [
        for k in 0..<17 if counts[k] != 0L => (k, counts[k])
      ],
    )
    let batches = trace.batches_through(Antichain([])).unwrap()
    assert_true(batches.length() <= 2)
    let mut stored = 0
    for batch in batches {
      stored += batch.to_array().length()
    }
    assert_true(stored <= 22)
  }
}

///|
test "panic query at unfinished timestamp" {
  let trace : @differential.Trace[Int32, Int64, Int64] = Trace(0)
  let _ = trace.snapshot(0)
}

///|
test "panic query before compaction" {
  let trace : @differential.Trace[Int32, Int64, Int64] = Trace(0)
  trace.insert(Batch([(1, 0L, 1L)], lower=Antichain([0L]), upper=Antichain([])))
  trace.set_logical_compaction(Antichain([2L]))
  let _ = trace.snapshot(1)
}

///|
test "panic batch outside interval" {
  let _ : @differential.Batch[Int32, Int64, Int64] = Batch(
    [(1, 2L, 1L)],
    lower=Antichain([0L]),
    upper=Antichain([2L]),
  )
}

///|
test "panic noncontiguous trace batch" {
  let trace : @differential.Trace[Int32, Int64, Int64] = Trace(0)
  trace.insert(
    Batch([(1, 2L, 1L)], lower=Antichain([2L]), upper=Antichain([3L])),
  )
}
