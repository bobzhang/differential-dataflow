///|
fn main {
  for _ in 0..<4 {
    let file = @spill_file.SpillFile()
    let policy : @differential.SpillPolicy[(Int32, Int32), Int64, Int64] = SpillPolicy(
      8L,
      store=file.store(),
      codec=@differential.WireCodec::json(),
      chunk_size=8,
    )
    let spine : @differential.Spine[(Int32, Int32), Int64, Int64] = Spine(0L)
    let expected : Map[(Int32, Int32), Int64] = Map([])
    let mut random = 42U
    for epoch in 0L..<32L {
      let updates = []
      for _ in 0..<32 {
        random = random * 1664525U + 1013904223U
        let i = ((random >> 8) % 64U).reinterpret_as_int()
        let key = (i / 8, i % 8)
        let diff = (random % 5U).to_int64() - 2L
        expected[key] = expected.get(key).unwrap_or(0L) + diff
        updates.push((key, epoch, diff))
      }
      let batch = @differential.ColumnarBatch(
          updates,
          lower=Antichain([epoch]),
          upper=Antichain([epoch + 1]),
        )
        .batch()
        .spill(policy)
      spine.set_logical_compaction(Antichain([epoch]))
      spine.set_physical_compaction(Antichain([epoch]))
      spine.insert(batch)
      let _ = spine.exert_with_fuel(4096)
      let rows = expected.to_array().filter(fn(row) { row.1 != 0L })
      rows.sort()
      guard spine.snapshot(epoch) == rows else {
        abort("disk spill snapshot differs")
      }
    }
    guard policy.stats().spilled_records > 0L &&
      policy.stats().fetched_chunks > 0L &&
      policy.stats().resident_records <= 8L else {
      abort("disk spill was not exercised")
    }
    spine.close()
    spine.set_logical_compaction(Antichain([]))
    spine.set_physical_compaction(Antichain([]))
    let _ = spine.exert_with_fuel(1)
    file.close()
  }
  println("disk spill snapshots passed")
}
