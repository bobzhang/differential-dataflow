///|
test "batcher drops canceled future capabilities and drains consumed chunks" {
  let batcher : @differential.Batcher[Int32, Int64, Int64] = Batcher(0L)
  let chunk = [(100, 5L, 1L), (200, 7L, 1L)]
  batcher.push(chunk)
  assert_true(chunk.is_empty())
  batcher.push([(100, 5L, -1L)])
  let (chain, description) = batcher.seal(Antichain([3L]))
  assert_true(chain.is_empty())
  assert_eq(batcher.frontier().to_array(), [7L])
  assert_eq(description.since().to_array(), [0L])
  batcher.push([(300, 4L, 2L)])
  assert_eq(batcher.frontier().to_array(), [7L])
  let (chain, description) = batcher.seal(Antichain([]))
  let batch = @differential.BatchBuilder::seal(chain, description)
  assert_true(chain.is_empty())
  assert_eq(batch.to_array(), [(200, 7L, 1L), (300, 4L, 2L)])
  assert_true(batcher.frontier().is_empty())
}

///|
test "ordered builder consolidates across chunks and transfers immutable storage" {
  let builder : @differential.BatchBuilder[Int32, Int64, Int64] = BatchBuilder(
    capacity=16,
  )
  builder.push([(1, 0L, 2L), (1, 0L, -1L)])
  builder.push([(1, 0L, -1L), (2, 1L, 4L)])
  let batch = builder.done(
    Description(Antichain([0L]), Antichain([2L]), Antichain([0L])),
  )
  assert_eq(batch.to_array(), [(2, 1L, 4L)])
}

///|
test "fueled batch merger compacts groups incrementally and releases sources" {
  let left = @differential.Batch(
    [(1, 0L, 2L), (2, 0L, 3L), (3, 1L, 1L)],
    lower=Antichain([0L]),
    upper=Antichain([2L]),
  )
  let right = @differential.Batch(
    [(1, 2L, -2L), (2, 2L, -1L), (4, 3L, 7L)],
    lower=Antichain([2L]),
    upper=Antichain([4L]),
  )
  let merger = left.begin_merge(right, Antichain([3L]))
  assert_eq(merger.work(0), 0)
  assert_false(merger.is_complete())
  assert_eq(merger.work(1), -1)
  assert_false(merger.is_complete())
  while !merger.is_complete() {
    let _ = merger.work(1)
  }
  assert_eq(merger.work(1), 1)
  let merged = merger.done()
  assert_eq(merged.to_array(), [(2, 3L, 2L), (3, 3L, 1L), (4, 3L, 7L)])
  assert_eq(merged.description().lower().to_array(), [0L])
  assert_eq(merged.description().upper().to_array(), [4L])
  assert_eq(merged.description().since().to_array(), [3L])
  assert_eq(left.to_array().length(), 3)
  assert_eq(right.to_array().length(), 3)
}

///|
test "panic premature batch merger completion" {
  let left = @differential.Batch(
    [(1, 0L, 1L)],
    lower=Antichain([0L]),
    upper=Antichain([1L]),
  )
  let right = @differential.Batch::empty(
    lower=Antichain([1L]),
    upper=Antichain([2L]),
  )
  let _ = left.begin_merge(right, Antichain([0L])).done()
}

///|
test "panic late batcher input" {
  let batcher : @differential.Batcher[Int32, Int64, Int64] = Batcher(0L)
  let _ = batcher.seal(Antichain([3L]))
  batcher.push([(1, 2L, 1L)])
}
