///|
test "spilled batches preserve columns snapshots and merge cancellation" {
  let store = @differential.BytesStore(fn(bytes) { BytesSource(fn() { bytes }) })
  let policy : @differential.SpillPolicy[(Int32, Int32), Int64, Int64] = SpillPolicy(
    3L,
    store~,
    codec=@differential.WireCodec::json(),
    chunk_size=3,
  )
  let a = @differential.ColumnarBatch(
    Array::makei(32, fn(i) { ((i / 8, i % 8), 0L, 1L) }),
    lower=Antichain([0L]),
    upper=Antichain([1L]),
  ).batch()
  let b = @differential.Batch(
    Array::makei(32, fn(i) {
      ((i / 8, i % 8), 1L, if i % 2 == 0 { -1L } else { 2L })
    }),
    lower=Antichain([1L]),
    upper=Antichain([2L]),
  )
  let paged = a.spill(policy)
  assert_eq(policy.stats().resident_records, 3L)
  assert_eq(policy.stats().spilled_records, 29L)
  assert_eq(policy.stats().spilled_chunks, 10L)
  assert_eq(policy.stats().fetched_chunks, 0L)
  assert_eq(paged.length(), 32)
  assert_eq(paged.description().upper().to_array(), [1L])
  assert_eq(policy.stats().fetched_chunks, 0L)
  assert_eq(paged.to_array(), a.to_array())
  let old = paged.view().cursor()
  let merged = paged.merge(b, Antichain([1L]))
  assert_eq(merged.to_array(), a.merge(b, Antichain([1L])).to_array())
  assert_eq(
    merged.compact(Antichain([9L])).to_array(),
    a.merge(b, Antichain([9L])).to_array(),
  )
  old.seek_key(3)
  old.seek_val(7)
  assert_eq(old.times(), [(0L, 1L)])
  let before = policy.stats()
  let _ = paged.spill(policy)
  assert_eq(policy.stats(), before)
}

///|
test "panic spill store corruption is detected before decoding" {
  let policy : @differential.SpillPolicy[(Int32, Int32), Int64, Int64] = SpillPolicy(
    0L,
    store=BytesStore(fn(_) { BytesSource(fn() { b"damaged" }) }),
    codec=@differential.WireCodec::json(),
  )
  let batch = @differential.Batch(
    [((1, 2), 0L, 1L)],
    lower=Antichain([0L]),
    upper=Antichain([1L]),
  ).spill(policy)
  let _ = batch.to_array()
}

///|
test "panic negative spill budget" {
  let _ : @differential.SpillPolicy[Int32, Int64, Int64] = SpillPolicy(
    -1L,
    store=BytesStore(fn(bytes) { BytesSource(fn() { bytes }) }),
    codec=@differential.WireCodec::json(),
  )
}
