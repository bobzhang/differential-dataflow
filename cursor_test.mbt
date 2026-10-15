///|
test "trace cursor seeks ordered keys and values and sums equal updates" {
  let trace : @differential.Trace[(Int32, Int32), Int64, Int64] = Trace(0)
  trace.insert(
    Batch(
      [
        ((1, 10), 0L, 1L),
        ((1, 10), 1L, 2L),
        ((1, 20), 1L, 1L),
        ((3, 30), 0L, 1L),
      ],
      lower=Antichain([0L]),
      upper=Antichain([2L]),
    ),
  )
  let cursor = trace.cursor()
  assert_eq(cursor.key(), Some(1))
  assert_eq(cursor.val(), Some(10))
  assert_eq(cursor.times(), [(0L, 1L), (1L, 2L)])
  let mut weight = 0L
  cursor.map_times(fn(_, diff) { weight += diff })
  assert_eq(weight, 3L)
  cursor.seek_val(11)
  assert_eq(cursor.val(), Some(20))
  cursor.step_val()
  assert_false(cursor.val_valid())
  assert_true(cursor.times().is_empty())
  cursor.rewind_vals()
  assert_eq(cursor.val(), Some(10))
  cursor.seek_key(2)
  assert_eq(cursor.key(), Some(3))
  assert_eq(cursor.val(), Some(30))
  cursor.seek_key(0)
  assert_eq(cursor.key(), Some(3))
  cursor.step_key()
  assert_false(cursor.key_valid())
  assert_false(cursor.val_valid())
  cursor.rewind_keys()
  trace.set_logical_compaction(Antichain([1L]))
  assert_eq(cursor.times(), [(0L, 1L), (1L, 2L)])
  assert_eq(trace.cursor().times(), [(1L, 3L)])
}

///|
test "empty trace cursor and vanished key after consolidation" {
  let trace : @differential.Trace[(Int32, Int32), Int64, Int64] = Trace(0)
  let empty = trace.cursor()
  assert_false(empty.key_valid())
  empty.step_key()
  empty.step_val()
  empty.seek_key(10)
  empty.seek_val(10)
  assert_true(empty.times().is_empty())
  trace.insert(
    Batch(
      [((1, 1), 0L, 1L), ((1, 1), 0L, -1L), ((2, 2), 0L, 1L)],
      lower=Antichain([0L]),
      upper=Antichain([1L]),
    ),
  )
  assert_eq(trace.cursor().key(), Some(2))
  assert_eq(trace.cursor_through(Antichain([0L])).unwrap().key(), None)
}
