///|
test "trace compaction and fueled spines retain columnar storage" {
  let trace : Trace[(Int32, Int32), Int64, Int64] = Trace(0L)
  let spine : Spine[(Int32, Int32), Int64, Int64] = Spine(0L)
  for time in 0L..<16L {
    let batch = ColumnarBatch(
      [((1, 2), time, 1L)],
      lower=Antichain([time]),
      upper=Antichain([time + 1]),
    ).batch()
    trace.insert(batch)
    spine.insert(batch)
  }
  trace.set_logical_compaction(Antichain([15L]))
  trace.set_physical_compaction(Antichain([16L]))
  spine.set_logical_compaction(Antichain([15L]))
  spine.set_physical_compaction(Antichain([16L]))
  let _ = spine.exert_with_fuel(1024)
  assert_eq(trace.snapshot(15L), [((1, 2), 16L)])
  assert_eq(spine.snapshot(15L), trace.snapshot(15L))
  for batch in trace.batches {
    assert_true(batch.updates is Indexed(_, _, _))
  }
  for batch in spine.batches_through(Antichain([])).unwrap() {
    assert_true(batch.updates is Indexed(_, _, _))
  }
}
