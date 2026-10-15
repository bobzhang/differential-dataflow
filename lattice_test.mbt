///|
test "product timestamps are partially ordered and compact by meet of joins" {
  let a : @differential.Product[Int64, Int64] = Product(3, 7)
  let b : @differential.Product[Int64, Int64] = Product(4, 6)
  assert_false(@differential.Lattice::less_equal(a, b))
  assert_false(@differential.Lattice::less_equal(b, a))
  assert_eq(@differential.Lattice::join(a, b), Product(4, 7))
  assert_eq(@differential.Lattice::meet(a, b), Product(3, 6))
  let frontier = @differential.Antichain([
    @differential.Product(4L, 8L),
    Product(5L, 3L),
    Product(6L, 9L),
  ])
  assert_eq(frontier.to_array().length(), 2)
  let advanced = @differential.advance_by(a, frontier)
  assert_eq(advanced, Product(4, 7))
  for x in 0L..<10L {
    for y in 0L..<10L {
      let query = @differential.Product(x, y)
      if frontier.less_equal(query) {
        assert_eq(
          @differential.Lattice::less_equal(a, query),
          @differential.Lattice::less_equal(advanced, query),
        )
      }
    }
  }
}

///|
test "frontier dominance and empty frontier semantics" {
  let a = @differential.Antichain([0L, 2L, 1L, 0L])
  assert_eq(a.to_array(), [0L])
  let b = @differential.Antichain([3L])
  let done : @differential.Antichain[Int64] = Antichain([])
  assert_true(a.precedes(b))
  assert_false(b.precedes(a))
  assert_true(b.precedes(done))
  assert_false(done.precedes(b))
  assert_eq(@differential.advance_by(2L, done), 2L)
  let copy = a.to_array()
  copy[0] = 99L
  assert_true(a.less_equal(1L))
}
