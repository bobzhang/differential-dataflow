///|
test "buffered inputs publish progress only after flush and close" {
  let batches = []
  let frontiers = []
  let input : @differential.InputSession[String, Int64, Int64] = InputSession(
    0,
    buffer_limit=2,
    deliver=fn(data, frontier) {
      batches.push(data)
      frontiers.push(frontier.to_array())
      frontier.clear()
    },
  )
  input.insert("a")
  input.advance_to(1)
  input.remove("a")
  assert_eq(input.frontier().to_array(), [0L])
  assert_eq(input.time(), 1L)
  input.update_at("b", 3, 2)
  assert_eq(batches[1], [("a", 0L, 1L), ("a", 1L, -1L)])
  assert_eq(frontiers[1], [0L])
  input.flush()
  assert_eq(batches[2], [("b", 3L, 2L)])
  assert_eq(frontiers[2], [1L])
  input.advance_to(4)
  input.insert("c")
  input.close()
  assert_eq(batches[3], [("c", 4L, 1L)])
  assert_true(frontiers[3].is_empty())
  assert_true(input.frontier().is_empty())
}

///|
test "panic input update in past" {
  let input : @differential.InputSession[Int32, Int64, Int64] = InputSession(
    2,
    deliver=fn(_, _) {  },
  )
  input.update_at(1, 1, 1)
}

///|
test "panic input incomparable time" {
  let input : @differential.InputSession[
    Int32,
    @differential.Product[Int64, Int64],
    Int64,
  ] = InputSession(Product(1, 2), deliver=fn(_, _) {  })
  input.advance_to(Product(2, 1))
}

///|
test "panic closed input" {
  let input : @differential.InputSession[Int32, Int64, Int64] = InputSession(
    0,
    deliver=fn(_, _) {  },
  )
  input.close()
  input.insert(1)
}
