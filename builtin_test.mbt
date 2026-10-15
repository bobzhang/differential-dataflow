///|
test "built-in timestamp summaries detect overflow on all backends" {
  let a = @differential.SummaryDomain::int32()
  assert_eq(a.results_in(1, 2147483647), None)
  assert_eq(a.results_in(-1, -2147483648), None)
  assert_eq(a.followed_by(3, 4), Some(7))
  let b = @differential.SummaryDomain::uint32()
  assert_eq(b.results_in(1U, 4294967295U), None)
  assert_eq(b.results_in(2U, 3U), Some(5U))
  let c = @differential.SummaryDomain::uint64()
  assert_eq(c.results_in(1UL, 18446744073709551615UL), None)
  assert_eq(c.results_in(2UL, 3UL), Some(5UL))
  assert_eq(@differential.SummaryDomain::unit().results_in((), ()), Some(()))
  assert_eq(@differential.advance_by(3, Antichain([5])), 5)
  assert_eq(@differential.advance_by(3U, Antichain([5U])), 5U)
  assert_eq(@differential.advance_by(3UL, Antichain([5UL])), 5UL)
  assert_eq(@differential.advance_by((), Antichain([()])), ())
}

///|
test "pair differences independently accumulate counts and totals" {
  assert_eq(
    @differential.consolidate([
      (1, (2L, 9L)),
      (1, (-2L, -9L)),
      (2, (1L, 3L)),
      (2, (1L, 7L)),
    ]),
    [(2, (2L, 10L))],
  )
  assert_eq(@differential.consolidate([(1, 2U), (1, 3U)]), [(1, 5U)])
  assert_eq(@differential.consolidate([(1, 2UL), (1, 3UL)]), [(1, 5UL)])
}

///|
test "small integer summaries reject overflow while differences wrap" {
  let byte = @differential.SummaryDomain::byte()
  for a in 0..<256 {
    for b in 0..<256 {
      let expected = if a + b > 255 { None } else { Some((a + b).to_byte()) }
      assert_eq(byte.results_in(a.to_byte(), b.to_byte()), expected)
    }
  }
  let signed = @differential.SummaryDomain::int16()
  assert_eq(signed.results_in(32767, 1), None)
  assert_eq(signed.results_in(-32768, -1), None)
  assert_eq(signed.results_in(-32768, 32767), Some(-1))
  let unsigned = @differential.SummaryDomain::uint16()
  assert_eq(unsigned.results_in(65535, 1), None)
  assert_eq(unsigned.results_in(65534, 1), Some(65535))
  let updates : Array[(Int32, Int16)] = [(0, 32767), (0, 1)]
  assert_eq(@differential.consolidate(updates), [(0, -32768)])
}

///|
test "vector differences pad unequal lengths without aliasing inputs" {
  let source = [1L, 2L]
  let a = @differential.VectorDiff(source)
  source[0] = 99L
  let b = @differential.VectorDiff([3L, -2L, 5L])
  let sum = a.plus(b)
  assert_eq(sum.to_array(), [4L, 0L, 5L])
  let copy = sum.to_array()
  copy[0] = 99L
  assert_eq(sum.to_array(), [4L, 0L, 5L])
  assert_eq(a.to_array(), [1L, 2L])
  assert_true(sum.plus(sum.negate()).is_zero())
  assert_eq(a.scale(3L, fn(x, scalar) { x * scalar }).to_array(), [3L, 6L])
  assert_eq(@differential.consolidate([(0, sum), (0, sum.negate())]), [])
  assert_eq(@differential.Present.multiply(7L), 7L)
  assert_eq(
    @differential.consolidate([(0, (1L, 2L, 3L, 4L)), (0, (-1L, -2L, -3L, -4L))]),
    [],
  )
  assert_eq(@differential.consolidate([(0, (1L, 2L, 3L)), (0, (2L, 3L, 4L))]), [
    (0, (3L, 5L, 7L)),
  ])
}
