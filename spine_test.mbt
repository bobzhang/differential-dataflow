///|
test "fueled spine retains cuts until physical compaction and cursors during merges" {
  let spine : @differential.Spine[(Int32, Int32), Int64, Int64] = Spine(0L)
  spine.insert(
    Batch(
      Array::makei(64, fn(i) { ((i, 0), 0L, 1L) }),
      lower=Antichain([0L]),
      upper=Antichain([1L]),
    ),
  )
  spine.insert(
    Batch(
      Array::makei(64, fn(i) { ((i, 0), 1L, -1L) }),
      lower=Antichain([1L]),
      upper=Antichain([2L]),
    ),
  )
  let old = spine.cursor_through(Antichain([1L])).unwrap()
  assert_eq(old.times(), [(0L, 1L)])
  spine.set_logical_compaction(Antichain([1L]))
  spine.set_physical_compaction(Antichain([2L]))
  assert_eq(spine.exert_with_fuel(1), -1)
  assert_true(spine.batches_through(Antichain([1L])) is None)
  assert_eq(spine.batches_through(Antichain([])).unwrap().length(), 2)
  assert_true(spine.snapshot(1L).is_empty())
  spine.set_exert_logic(fn(_) { None })
  spine.exert()
  assert_eq(spine.batches_through(Antichain([])).unwrap().length(), 2)
  let mut callbacks = 0
  spine.set_exert_logic(fn(levels) {
    callbacks += 1
    if levels.is_empty() {
      None
    } else {
      Some(7)
    }
  })
  for _ in 0..<32 {
    spine.exert()
  }
  assert_eq(callbacks, 32)
  assert_eq(spine.batches_through(Antichain([])).unwrap().length(), 1)
  assert_false(spine.cursor().key_valid())
  assert_eq(old.key(), Some(0))
  assert_eq(old.times(), [(0L, 1L)])
  spine.close()
  spine.close()
  assert_true(spine.upper().is_empty())
  spine.set_logical_compaction(Antichain([]))
  spine.set_physical_compaction(Antichain([]))
  let _ = spine.exert_with_fuel(1)
  assert_true(spine.levels().is_empty())
}

///|
test "fueled spine preserves old queries when exact intervals are merged" {
  let spine : @differential.Spine[Int32, Int64, Int64] = Spine(0L)
  for epoch in 0L..<64L {
    spine.insert(
      Batch(
        [(1, epoch, 1L)],
        lower=Antichain([epoch]),
        upper=Antichain([epoch + 1]),
      ),
    )
    spine.set_physical_compaction(Antichain([epoch + 1]))
    let _ = spine.exert_with_fuel(4096)
    for query in 0L..<(epoch + 1) {
      assert_eq(spine.snapshot(query), [(1, query + 1)])
    }
  }
  assert_eq(spine.batches_through(Antichain([])).unwrap().length(), 1)
}
