///|
test "columnar tries retain raw leaves and consolidate into exact nested ranges" {
  let rows = [
    (2, 7, 3UL, 4L),
    (1, 5, 2UL, 1L),
    (1, 5, 1UL, 2L),
    (1, 6, 4UL, 3L),
    (1, 5, 2UL, -1L),
    (2, 7, 3UL, 2L),
  ]
  let raw = @differential.UpdatesTyped(rows)
  rows.clear()
  assert_eq(raw.length(), 6)
  let trie = raw.consolidate()
  assert_eq(trie.iter().to_array(), [
    (1, 5, 1UL, 2L),
    (1, 6, 4UL, 3L),
    (2, 7, 3UL, 6L),
  ])
  let (keys, vals, times, diffs) = trie.columns()
  assert_eq(keys.values(), [1, 2])
  assert_eq(keys.offsets(), [2])
  assert_eq(vals.values(), [5, 6, 7])
  assert_eq(vals.offsets(), [2, 3])
  assert_eq(times.values(), [1UL, 4UL, 3UL])
  assert_eq(times.offsets(), [1, 2, 3])
  assert_eq(diffs.values(), [2L, 3L, 6L])
  assert_eq(diffs.offsets(), [1, 2, 3])
  assert_eq(trie.vals_bounds(0, 1), (0, 2))
  assert_eq(trie.times_bounds(1, 3), (1, 3))
  let copied = keys.values()
  copied[0] = 100
  assert_eq(keys.get(0), 1)
  let builder = @differential.UpdatesBuilder()
  for index in 0..<trie.length() {
    let leaf = trie.split_at(index).1.split_at(1).0
    builder.meld(leaf)
  }
  assert_eq(builder.done().iter().to_array(), trie.iter().to_array())
  assert_eq(trie.suffix_chunk((0, 1, 1)).iter().to_array(), [
    (1, 6, 4UL, 3L),
    (2, 7, 3UL, 6L),
  ])
}

///|
test "columnar iteration skips empty ancestors and preserves multi-difference leaves" {
  let trie = @differential.UpdatesTyped::from_columns(
    ColumnLists([1, 2, 3], [0, 3, 3]),
    ColumnLists([10, 11, 12], [0, 2, 3]),
    ColumnLists([0UL, 1UL, 2UL], [0, 2, 3]),
    ColumnLists([5L, -2L, 7L], [0, 2, 3]),
  )
  assert_eq(trie.iter().to_array(), [
    (2, 11, 1UL, 5L),
    (2, 11, 1UL, -2L),
    (3, 12, 2UL, 7L),
  ])
  assert_eq(trie.consolidate().iter().to_array(), [
    (2, 11, 1UL, 3L),
    (3, 12, 2UL, 7L),
  ])
  let cancelled = @differential.UpdatesTyped::from_columns(
    ColumnLists([1, 2], [2]),
    ColumnLists([10, 11], [1, 2]),
    ColumnLists([0UL, 1UL, 2UL], [2, 3]),
    ColumnLists([9L], [0, 1, 1]),
  ).filter_zero()
  assert_eq(cancelled.iter().to_array(), [(1, 10, 1UL, 9L)])
  let (k, v, t, d) = cancelled.columns()
  assert_eq(
    (k.values(), v.values(), t.values(), d.values()),
    ([1], [10], [1UL], [9L]),
  )
}

///|
test "partial merge cancels a boundary and returns only the surviving suffix" {
  let left = @differential.UpdatesTyped([(1, 1, 0UL, 2L), (2, 1, 0UL, 3L)]).consolidate()
  let right = @differential.UpdatesTyped([(1, 1, 0UL, -2L), (3, 1, 0UL, 5L)]).consolidate()
  let (merged, a, b) = left.merge_pair(right)
  assert_eq(merged.iter().to_array(), [(2, 1, 0UL, 3L)])
  assert_true(a is None)
  assert_eq(b.unwrap().iter().to_array(), [(3, 1, 0UL, 5L)])
  assert_eq(left.iter().to_array(), [(1, 1, 0UL, 2L), (2, 1, 0UL, 3L)])
  let builder = @differential.UpdatesBuilder()
  builder.meld(merged)
  builder.meld(b.unwrap())
  assert_eq(builder.done().iter().to_array(), [(2, 1, 0UL, 3L), (3, 1, 0UL, 5L)])
}

///|
test "chunk extraction uses partial-order frontiers and integrates with trace cursors" {
  let rows = [
    (1, 0, @differential.Product(0UL, 2UL), 1L),
    (1, 0, Product(1UL, 1UL), 2L),
    (1, 1, Product(2UL, 0UL), 3L),
    (2, 0, Product(2UL, 2UL), 4L),
  ]
  let trie = @differential.UpdatesTyped(rows).consolidate()
  let upper = @differential.Antichain([
    @differential.Product(1UL, 2UL),
    Product(2UL, 1UL),
  ])
  let (ready, kept, frontier) = trie.extract(upper)
  assert_eq(ready.length(), 3)
  assert_eq(kept.iter().to_array(), [(2, 0, Product(2UL, 2UL), 4L)])
  assert_eq(frontier.to_array(), [Product(2UL, 2UL)])
  let shipped = []
  let retained = []
  let combined = @differential.Antichain([])
  let (a, b) = trie.split_at(2)
  @differential.extract_update_chunks(
    [a, b].iter(),
    upper,
    combined,
    ship=fn(c) { shipped.push(c.length()) },
    kept=fn(c) { retained.push(c.length()) },
  )
  assert_eq(shipped, [2, 1])
  assert_eq(retained, [1])
  assert_eq(combined.to_array(), frontier.to_array())
  let batch = ready.batch(
    Description(
      Antichain([Product(0UL, 0UL)]),
      upper,
      Antichain([Product(0UL, 0UL)]),
    ),
  )
  assert_eq(
    batch.columnar().updates().iter().to_array(),
    ready.iter().to_array(),
  )
  let cursor = @differential.Cursor([batch.view()])
  assert_eq(cursor.key(), Some(1))
  assert_eq(cursor.val(), Some(0))
  let seen = []
  cursor.map_times(fn(t, r) { seen.push((t, r)) })
  assert_eq(seen, [(Product(0UL, 2UL), 1L), (Product(1UL, 1UL), 2L)])
}
