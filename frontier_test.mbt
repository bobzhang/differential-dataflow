///|
test "change batches cancel signed updates and drain once" {
  let batch : @differential.ChangeBatch[String] = ChangeBatch()
  batch.update_all([("a", 3), ("b", -1), ("a", -3), ("b", 4)])
  assert_true(batch.is_dirty())
  assert_eq(batch.to_array(), [("b", 3L)])
  assert_false(batch.is_dirty())
  assert_eq(batch.drain(), [("b", 3L)])
  assert_true(batch.is_empty())
  batch.update("b", -3)
  assert_eq(batch.to_array(), [("b", -3L)])
  batch.clear()
  assert_true(batch.is_empty())
}

///|
test "mutable product frontier reveals hidden timestamps after retraction" {
  let counts : @differential.MutableAntichain[
    @differential.Product[Int64, Int64],
  ] = MutableAntichain()
  assert_eq(
    counts.update_all([
      (Product(0, 0), 1),
      (Product(2, 3), 7),
      (Product(3, 2), 2),
    ]),
    [(Product(0, 0), 1L)],
  )
  assert_eq(counts.update_all([(Product(0, 0), -1)]), [
    (Product(0, 0), -1L),
    (Product(2, 3), 1L),
    (Product(3, 2), 1L),
  ])
  let snapshot = counts.frontier()
  snapshot.clear()
  assert_eq(counts.frontier().to_array().length(), 2)
  assert_true(counts.update_all([(Product(2, 3), -6)]).is_empty())
  assert_eq(counts.count_for(Product(2, 3)), 1L)
  assert_eq(
    counts.update_all([(Product(2, 3), -1), (Product(3, 2), -2)]).length(),
    2,
  )
  assert_true(counts.frontier().is_empty())
}

///|
test "random signed timestamp counts against independent minimal-set oracle" {
  for seed in 1..<33 {
    let state : @differential.MutableAntichain[
      @differential.Product[Int64, Int64],
    ] = MutableAntichain()
    let counts = Array::make(25, 0L)
    let mut random = seed.reinterpret_as_uint()
    for _ in 0..<80 {
      let updates = []
      for _ in 0..<3 {
        random = random * 1664525U + 1013904223U
        let index = ((random >> 8) % 25U).reinterpret_as_int()
        let delta = if random % 3U == 0U { -1L } else { 1L }
        counts[index] += delta
        updates.push(
          (
            @differential.Product(
              (index / 5).to_int64(),
              (index % 5).to_int64(),
            ),
            delta,
          ),
        )
      }
      let before = state.frontier().to_array()
      let actual_delta = state.update_all(updates)
      let expected = []
      for index in 0..<25 {
        if counts[index] > 0 {
          let x = index / 5
          let y = index % 5
          let mut minimal = true
          for other in 0..<25 {
            if other != index &&
              counts[other] > 0 &&
              other / 5 <= x &&
              other % 5 <= y {
              minimal = false
            }
          }
          if minimal {
            expected.push(@differential.Product(x.to_int64(), y.to_int64()))
          }
        }
      }
      assert_eq(state.frontier().to_array(), expected)
      let delta : @differential.ChangeBatch[@differential.Product[Int64, Int64]] = ChangeBatch()
      delta.update_all(before.map(fn(t) { (t, -1L) }))
      delta.update_all(expected.map(fn(t) { (t, 1L) }))
      assert_eq(actual_delta, delta.to_array())
    }
  }
}
