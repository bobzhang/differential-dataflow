///|
test "128 bit differences wrap while timestamp summaries reject overflow" {
  let max_signed = @differential.Int128::from_words(
    9223372036854775807L, 18446744073709551615UL,
  )
  let min_signed = @differential.Int128::from_words(-9223372036854775808L, 0UL)
  let one = @differential.Int128(1)
  assert_eq(max_signed.to_string(), "170141183460469231731687303715884105727")
  assert_eq(min_signed.to_string(), "-170141183460469231731687303715884105728")
  assert_eq(max_signed.plus(one), min_signed)
  assert_eq(min_signed.negate(), min_signed)
  assert_eq(max_signed.checked_add(one), None)
  assert_eq(min_signed.checked_add(one.negate()), None)
  assert_eq(@differential.Int128(-1).to_words(), (-1L, 18446744073709551615UL))
  let max_unsigned = @differential.UInt128::from_words(
    18446744073709551615UL, 18446744073709551615UL,
  )
  assert_eq(max_unsigned.to_string(), "340282366920938463463374607431768211455")
  assert_true(max_unsigned.plus(UInt128(1)).is_zero())
  assert_eq(max_unsigned.multiply(max_unsigned), UInt128(1))
  assert_eq(
    @differential.SummaryDomain::uint128().results_in(UInt128(1), max_unsigned),
    None,
  )
  assert_eq(
    @differential.SummaryDomain::int128().results_in(one, max_signed),
    None,
  )
  assert_eq(
    @differential.consolidate([(0, max_signed), (0, max_signed.negate())]),
    [],
  )
}

///|
test "duration normalization and nanosecond carry match Rust limits" {
  let normalized = @differential.Duration(2UL, nanoseconds=2500000000U)
  assert_eq(normalized.seconds(), 4UL)
  assert_eq(normalized.nanoseconds(), 500000000U)
  let max = @differential.Duration(
    18446744073709551615UL,
    nanoseconds=999999999U,
  )
  let tick = @differential.Duration(0UL, nanoseconds=1U)
  assert_eq(max.checked_add(tick), None)
  let a = @differential.Duration(1UL, nanoseconds=900000000U)
  let b = @differential.Duration(2UL, nanoseconds=100000001U)
  assert_eq(a.checked_add(b), Some(Duration(4UL, nanoseconds=1U)))
  assert_eq(
    @differential.SummaryDomain::duration().results_in(a, b),
    a.checked_add(b),
  )
  assert_eq(@differential.advance_by(a, Antichain([b])), b)
}
