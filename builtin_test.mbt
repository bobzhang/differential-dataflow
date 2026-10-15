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
