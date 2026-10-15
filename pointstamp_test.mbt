///|
test "runtime pointstamps normalize minimum coordinates and use product order" {
  let values = [1UL, 0UL, 0UL]
  let a = @differential.PointStamp(values)
  values[0] = 9UL
  assert_eq(a.to_array(), [1UL])
  let copy = a.to_array()
  copy[0] = 7UL
  let b = @differential.PointStamp([0UL, 2UL])
  assert_false(a.less_equal(b))
  assert_false(b.less_equal(a))
  assert_eq(a.join(b).to_array(), [1UL, 2UL])
  assert_eq(a.meet(b).to_array(), [])
  assert_true(@differential.PointStamp([0UL, 0UL]).less_equal(a))
  let signed = @differential.PointStamp([-9223372036854775808L])
  assert_eq(signed.to_array(), [])
  assert_eq(@differential.PointStamp([0L]).to_array(), [0L])
}

///|
test "runtime pointstamp summaries truncate compose and detect overflow" {
  let inner = @differential.SummaryDomain::uint64()
  let domain = @differential.SummaryDomain::pointstamp(inner)
  let actions = [0UL, 2UL]
  let first = @differential.PointStampSummary(actions, retain=1)
  actions[1] = 9UL
  let second = @differential.PointStampSummary([1UL, 3UL, 4UL])
  let input = @differential.PointStamp([5UL, 6UL, 7UL])
  let intermediate = domain.results_in(first, input).unwrap()
  assert_eq(intermediate.to_array(), [5UL, 2UL])
  let both = domain.followed_by(first, second).unwrap()
  assert_eq(both.retain(), Some(1))
  assert_eq(both.actions(), [1UL, 5UL, 4UL])
  assert_eq(
    domain.results_in(both, input),
    domain.results_in(second, intermediate),
  )
  assert_eq(
    domain.results_in(
      PointStampSummary([1UL]),
      PointStamp([18446744073709551615UL]),
    ),
    None,
  )
  assert_eq(inner.feedback_summary(3, 1UL).actions(), [0UL, 0UL, 1UL])
}

///|
test "dynamic leave discards nested coordinates while preserving outer progress" {
  let worker = @differential.Worker()
  let domain = @differential.SummaryDomain::product(
    @differential.SummaryDomain::uint64(),
    @differential.SummaryDomain::pointstamp(
      @differential.SummaryDomain::uint64(),
    ),
  )
  let scope = worker.scope(
    @differential.Product(0UL, @differential.PointStamp([])),
    domain,
  )
  let (output, cap, source) : (
    @differential.Output[
      Int32,
      @differential.Product[UInt64, @differential.PointStamp[UInt64]],
      Int64,
      @differential.Product[UInt64, @differential.PointStampSummary[UInt64]],
    ],
    @differential.Capability[
      @differential.Product[UInt64, @differential.PointStamp[UInt64]],
      @differential.Product[UInt64, @differential.PointStampSummary[UInt64]],
    ],
    @differential.Collection[
      Int32,
      @differential.Product[UInt64, @differential.PointStamp[UInt64]],
      Int64,
    ],
  ) = scope.source()
  let seen = []
  let probe = scope
    .leave_dynamic(source.enter_dynamic(3), 2)
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let at = cap.delayed(Product(7UL, PointStamp([2UL, 3UL, 4UL])))
  output.send(at, [(9, 1L)])
  cap.release()
  at.release()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(seen, [(9, Product(7UL, PointStamp([2UL])), 1L)])
  worker.dispose()
}

///|
test "dynamic timestamp codecs preserve wide coordinates and reject malformed summaries" {
  let scalar : @differential.WireCodec[UInt64] = @differential.WireCodec::json()
  let codec = @differential.WireCodec::pointstamp(scalar)
  let stamp = @differential.PointStamp([18446744073709551615UL, 0UL, 2UL])
  assert_eq(codec.from_json(codec.to_json(stamp)), Some(stamp))
  assert_eq(codec.from_json(["0", "0"]), Some(PointStamp([])))
  assert_eq(codec.from_json(["invalid"]), None)
  let codec = @differential.WireCodec::pointstamp_summary(scalar)
  for retain in [None, Some(0), Some(5)] {
    let summary = @differential.PointStampSummary([0UL, 2UL], retain?)
    assert_eq(codec.from_json(codec.to_json(summary)), Some(summary))
  }
  assert_eq(codec.from_json([-1, []]), None)
  assert_eq(codec.from_json([1.5, []]), None)
  assert_eq(codec.from_json([null, ["invalid"]]), None)
  assert_eq(codec.from_json([null]), None)
}
