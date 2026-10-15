///|
test "generic consolidation includes presence and signed cancellation" {
  let updates = [("x", 1L, 2L), ("x", 1L, -2L), ("x", 2L, 3L), ("y", 0L, 0L)]
  assert_eq(@differential.consolidate_updates(updates), [("x", 2L, 3L)])
  assert_eq(updates.length(), 4)
  let present : Array[(Int32, @differential.Present)] = [
    (2, Present),
    (1, Present),
    (2, Present),
  ]
  assert_eq(@differential.consolidate(present), [(1, Present), (2, Present)])
  let zero : Int64 = @differential.Monoid::zero()
  assert_eq(zero, 0L)
  assert_eq(@differential.Abelian::negate(3L), -3L)
}

///|
test "random signed consolidation against dense sums" {
  let mut random = 42U
  let counts = Array::make(200, 0L)
  let input = []
  for _ in 0..<20000 {
    random = random * 1664525U + 1013904223U
    let key = ((random >> 8) % 200U).reinterpret_as_int()
    let diff = (random % 7U).to_int64() - 3L
    counts[key] += diff
    input.push((key, diff))
  }
  assert_eq(
    @differential.consolidate(input),
    [
      for key in 0..<200 if counts[key] != 0 => (key, counts[key])
    ],
  )
}
