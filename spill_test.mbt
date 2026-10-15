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

///|
test "binary columnar spill stores real Rust-format pages and preserves merge views" {
  let stored = []
  let loads = Ref(0)
  let codec = @differential.ColumnarCodec(
    @differential.ColumnCodec::int32(),
    @differential.ColumnCodec::int32(),
    @differential.ColumnCodec::uint64(),
    @differential.ColumnCodec::int64(),
  )
  let policy = codec.spill_policy(
    3L,
    chunk_size=3,
    store=BytesStore(fn(bytes) {
      stored.push(bytes)
      BytesSource(fn() {
        loads.val += 1
        bytes
      })
    }),
  )
  let batch = @differential.ColumnarBatch(
    Array::makei(10, fn(i) { ((i / 3, i % 3), 0UL, i.to_int64() + 1L) }),
    lower=Antichain([0UL]),
    upper=Antichain([1UL]),
  ).batch()
  let paged = batch.spill(policy)
  assert_eq((stored.length(), loads.val), (3, 0))
  assert_eq(policy.stats().resident_records, 3L)
  assert_eq(policy.stats().spilled_records, 7L)
  let decoded = []
  for bytes in stored {
    let trie = codec.decode(bytes[:]).unwrap()
    for (k, v, t, r) in trie.iter() {
      decoded.push(((k, v), t, r))
    }
    assert_eq(codec.encode(trie), bytes)
  }
  assert_eq(decoded, batch.to_array()[3:].to_owned())
  assert_eq(loads.val, 0)
  let view = paged.view()
  assert_eq(view.get(6), Some(((2, 0), 0UL, 7L)))
  assert_eq(loads.val, 1)
  assert_eq(view.get(7), Some(((2, 1), 0UL, 8L)))
  assert_eq(loads.val, 1)
  let old = view.cursor()
  old.seek_key(2)
  assert_eq(old.times(), [(0UL, 7L)])
  let compacted = paged.compact(Antichain([5UL]))
  assert_eq(compacted.to_array(), batch.compact(Antichain([5UL])).to_array())
  assert_eq(old.times(), [(0UL, 7L)])
  assert_true(policy.stats().fetched_chunks > 0L)
}
