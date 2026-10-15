///|
test "columnar batches deduplicate keys and values and preserve immutable cursors" {
  let rows = []
  for key in 0..<8 {
    for value in 0..<4 {
      for time in 0L..<16L {
        rows.push(((key, value), time, 1L))
      }
    }
  }
  // Consolidation cancels an extra pair without changing the stored trie.
  rows.push(((99, 99), 0L, 1L))
  rows.push(((99, 99), 0L, -1L))
  let columns = @differential.ColumnarBatch(
    rows,
    lower=Antichain([0L]),
    upper=Antichain([16L]),
  )
  rows.clear()
  assert_eq(columns.storage_counts(), (8, 32, 512))
  let batch = columns.batch()
  assert_eq(batch.length(), 512)
  let old = batch.view().cursor()
  let compacted = batch.compact(Antichain([20L]))
  assert_eq(compacted.length(), 32)
  assert_eq(compacted.columnar().storage_counts(), (8, 32, 32))
  let current = compacted.view().cursor()
  for key in 0..<8 {
    assert_eq(current.key(), Some(key))
    for value in 0..<4 {
      assert_eq(current.val(), Some(value))
      assert_eq(current.times(), [(20L, 16L)])
      current.step_val()
    }
    current.step_key()
  }
  assert_false(current.key_valid())
  old.seek_key(7)
  old.seek_val(3)
  assert_eq(old.times(), Array::makei(16, fn(i) { (i.to_int64(), 1L) }))
  let copy = batch.to_array()
  copy.clear()
  assert_eq(batch.length(), 512)
}

///|
test "columnar empty and mixed-layout merges preserve cancellation and metadata" {
  let empty : @differential.ColumnarBatch[Int32, Int32, Int64, Int64] = ColumnarBatch(
    [],
    lower=Antichain([0L]),
    upper=Antichain([1L]),
  )
  assert_eq(empty.storage_counts(), (0, 0, 0))
  assert_false(empty.batch().view().cursor().key_valid())
  let a = @differential.ColumnarBatch(
    [((1, 2), 1L, 3L)],
    lower=Antichain([1L]),
    upper=Antichain([2L]),
  ).batch()
  let b = @differential.Batch(
    [((1, 2), 2L, -3L), ((3, 4), 2L, 1L)],
    lower=Antichain([2L]),
    upper=Antichain([3L]),
  )
  let merged = empty.batch().merge(a, Antichain([0L])).merge(b, Antichain([2L]))
  assert_eq(merged.to_array(), [((3, 4), 2L, 1L)])
  assert_eq(merged.description().lower().to_array(), [0L])
  assert_eq(merged.description().upper().to_array(), [3L])
  assert_eq(merged.description().since().to_array(), [2L])
}
