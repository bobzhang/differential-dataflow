///|
test "fueled joins yield while retaining unfinished output progress" {
  for counted in [false, true] {
    let worker = @differential.Worker()
    let scope = worker.scope(0L, @differential.SummaryDomain::int64())
    let (a, left) : (
      @differential.InputSession[(Int32, Int32), Int64, Int64],
      @differential.Collection[(Int32, Int32), Int64, Int64],
    ) = if counted { scope.input() } else { worker.input(0L) }
    let (b, right) : (
      @differential.InputSession[(Int32, Int32), Int64, Int64],
      @differential.Collection[(Int32, Int32), Int64, Int64],
    ) = if counted { scope.input() } else { worker.input(0L) }
    let left = left.arrange_by_key(columnar=true)
    let right = right.arrange_by_key(columnar=true)
    let mut pairs = 0
    let mut seen = 0
    let result = left.join_map(
      right,
      fn(_, v, w) {
        pairs += 1
        (v, w)
      },
      multiply=fn(a, b) { a * b },
      fuel=7,
    )
    let probe = result.inspect(fn(_, _, r) { seen += r.to_int() })
    left.release()
    right.release()
    for value in 0..<80 {
      a.insert((0, value))
      b.insert((0, value))
    }
    a.close()
    b.close()
    let mut turns = 0
    while worker.step() {
      assert_true(pairs - turns <= 7)
      turns = pairs
      if seen < 6400 {
        assert_false(probe.done())
      }
    }
    assert_eq(pairs, 6400)
    assert_eq(seen, 6400)
    assert_true(probe.done())
    worker.dispose()
  }
}

///|
test "fueled joins retain historical views across new batches and compaction" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (a, left) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (b, right) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let l = left.arrange_by_key(fueled=true)
  let r = right.arrange_by_key(fueled=true)
  let mut total = 0L
  let probe = l.join(r, fuel=1).inspect(fn(_, _, r) { total += r })
  l.release()
  r.release()
  for epoch in 0L..<32L {
    a.update((0, epoch.to_int()), 1L)
    b.update((0, epoch.to_int()), 1L)
    a.advance_to(epoch + 1)
    b.advance_to(epoch + 1)
    a.flush()
    b.flush()
    let _ = worker.run(max_steps=4)
  }
  a.close()
  b.close()
  let _ = worker.run()
  assert_eq(total, 1024L)
  assert_true(probe.done())
  worker.dispose()
}
