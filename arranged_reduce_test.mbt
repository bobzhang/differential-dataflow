///|
test "arranged reductions resurrect canceled keys without replaying pinned history" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let index = source.arrange_by_key()
  let pinned = index.trace()
  let seen = []
  let calls = Ref(0)
  let reduced = index.reduce_arranged(fn(_, values) {
    calls.val += 1
    [(values[0].0, 1L)]
  })
  index.release()
  let probe = reduced
    .as_collection()
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  reduced.release()
  for epoch in 0L..<4L {
    input.update((0, 7), if epoch % 2 == 0 { 1L } else { -1L })
    input.advance_to(epoch + 1)
    input.flush()
    let _ = worker.run()
    assert_true(!probe.less_than(epoch + 1))
  }
  assert_eq(seen, [
    ((0, 7), 0L, 1L),
    ((0, 7), 1L, -1L),
    ((0, 7), 2L, 1L),
    ((0, 7), 3L, -1L),
  ])
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_true(calls.val > 0)
  pinned.release()
  worker.dispose()
}

///|
test "unchanged keys do not rerun reduction logic as frontiers advance" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let index = source.arrange_by_key()
  let calls = Ref(0)
  let probe = index
    .reduce(fn(_, values) {
      calls.val += 1
      [(values[0].0, 1L)]
    })
    .probe()
  index.release()
  input.insert((1, 2))
  input.advance_to(1)
  input.flush()
  let _ = worker.run()
  let count = calls.val
  assert_true(count > 0)
  for epoch in 2L..<100L {
    input.advance_to(epoch)
    input.flush()
    let _ = worker.run()
    assert_true(!probe.less_than(epoch))
    assert_eq(calls.val, count)
  }
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}
