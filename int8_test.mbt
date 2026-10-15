///|
test "signed byte arithmetic exhaustively checks wrapping and overflow boundaries" {
  let domain = @differential.SummaryDomain::int8()
  for a in -128..<128 {
    let x = @differential.Int8(a)
    assert_eq(x.to_int(), a)
    assert_eq(x.negate().to_int(), if a == -128 { -128 } else { -a })
    for b in -128..<128 {
      let y = @differential.Int8(b)
      let sum = a + b
      let product = a * b
      assert_eq(x.plus(y).to_int(), ((sum & 255) ^ 128) - 128)
      assert_eq(x.multiply(y).to_int(), ((product & 255) ^ 128) - 128)
      assert_eq(x.less_equal(y), a <= b)
      assert_eq(x.join(y).to_int(), if a > b { a } else { b })
      assert_eq(x.meet(y).to_int(), if a < b { a } else { b })
      let checked = if sum < -128 || sum > 127 {
        None
      } else {
        Some(@differential.Int8(sum))
      }
      assert_eq(domain.results_in(x, y), checked)
      assert_eq(domain.followed_by(x, y), checked)
    }
  }
  assert_eq(@differential.Int8(255).to_int(), -1)
  assert_eq(@differential.Int8(256).to_int(), 0)
}

///|
test "wrapping signed and singleton difference adapters preserve cancellation" {
  let a = @differential.Wrapping(@differential.Int8(127))
  let one = @differential.Wrapping::one()
  assert_eq(a.plus(one).value().to_int(), -128)
  assert_eq(a.multiply(Wrapping(Int8(2))).value().to_int(), -2)
  assert_true(a.plus(a.negate()).is_zero())
  let value = @differential.SingletonDiff(7L)
  assert_eq(value.scale(3, fn(a, b) { a * b.to_int64() }).value(), 21L)
  assert_true(value.plus(value.negate()).is_zero())
  assert_eq(@differential.SingletonDiff::zero().value(), 0L)
}
