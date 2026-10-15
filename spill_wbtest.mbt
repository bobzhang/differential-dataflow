///|
test "page readers load lazily cache one page and retain the spill policy" {
  let policy : SpillPolicy[(Int32, Int32), Int64, Int64] = SpillPolicy(
    0L,
    store=BytesStore(fn(bytes) { BytesSource(fn() { bytes }) }),
    codec=WireCodec::json(),
    chunk_size=4,
  )
  let batch = Batch(
    Array::makei(12, fn(i) { ((i, 0), 0L, 1L) }),
    lower=Antichain([0L]),
    upper=Antichain([1L]),
  ).spill(policy)
  let reader = batch.updates.reader()
  assert_eq(policy.stats().fetched_chunks, 0L)
  assert_eq(reader[0], ((0, 0), 0L, 1L))
  assert_eq(reader[3], ((3, 0), 0L, 1L))
  assert_eq(policy.stats().fetched_chunks, 1L)
  let _ = reader[4]
  let _ = reader[0]
  assert_eq(policy.stats().fetched_chunks, 3L)
  assert_true(batch.compact(Antichain([1L])).updates is Paged(_, _, _))
  let empty : Batch[(Int32, Int32), Int64, Int64] = Batch::empty(
    lower=Antichain([1L]),
    upper=Antichain([2L]),
  )
  assert_true(batch.merge(empty, Antichain([0L])).updates is Paged(_, _, _))
}

///|
test "paged product timestamps compact at incomparable frontiers" {
  let codec : WireCodec[Array[((Int32, Int32), Product[Int64, Int64], Int64)]] = WireCodec(
    encode=fn(rows) {
      Json(rows.map(fn(row) { (row.0, (row.1.outer, row.1.inner), row.2) }))
    },
    decode=fn(json) {
      let rows : Array[((Int32, Int32), (Int64, Int64), Int64)] = @json.from_json(
        json,
      ) catch {
        _ => return None
      }
      Some(rows.map(fn(row) { (row.0, Product(row.1.0, row.1.1), row.2) }))
    },
  )
  let policy = SpillPolicy(
    0L,
    codec~,
    store=BytesStore(fn(bytes) { BytesSource(fn() { bytes }) }),
    chunk_size=3,
  )
  let batch = ColumnarBatch(
    Array::makei(32, fn(i) {
      (
        (i % 3, i % 2),
        Product((i / 4 % 4).to_int64(), (i % 4).to_int64()),
        if i % 3 == 0 {
          -1L
        } else {
          1L
        },
      )
    }),
    lower=Antichain([Product(0L, 0L)]),
    upper=Antichain([Product(4L, 0L), Product(0L, 4L)]),
  ).batch()
  let frontier = Antichain([Product(1L, 2L), Product(2L, 1L)])
  assert_eq(
    batch.spill(policy).compact(frontier).to_array(),
    batch.compact(frontier).to_array(),
  )
}
