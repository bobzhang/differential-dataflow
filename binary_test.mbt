///|
test "weighted join, semijoin and antijoin handle retractions" {
  let worker = @differential.Worker()
  let (left_input, left) : (
    @differential.InputSession[(Int32, String), Int64, Int64],
    @differential.Collection[(Int32, String), Int64, Int64],
  ) = worker.input(0)
  let (right_input, right) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let semi = []
  let anti = []
  let p = left
    .semijoin(right)
    .consolidate()
    .inspect(fn(d, t, r) { semi.push((d, t, r)) })
  let q = left
    .antijoin(right)
    .consolidate()
    .inspect(fn(d, t, r) { anti.push((d, t, r)) })
  left_input.update((1, "a"), 3)
  left_input.insert((2, "b"))
  right_input.insert(1)
  left_input.advance_to(1)
  left_input.flush()
  let _ = worker.run()
  assert_true(p.less_than(1))
  right_input.advance_to(1)
  right_input.flush()
  let _ = worker.run()
  assert_eq(semi, [((1, "a"), 0L, 3L)])
  assert_eq(anti, [((2, "b"), 0L, 1L)])
  right_input.remove(1)
  left_input.advance_to(2)
  right_input.advance_to(2)
  left_input.flush()
  right_input.flush()
  let _ = worker.run()
  assert_eq(semi, [((1, "a"), 0L, 3L), ((1, "a"), 1L, -3L)])
  assert_eq(anti, [((2, "b"), 0L, 1L), ((1, "a"), 1L, 3L)])
  left_input.close()
  right_input.close()
  let _ = worker.run()
  assert_true(p.done() && q.done())
}

///|
test "product join uses lattice timestamp join and retains closed-side history" {
  let worker = @differential.Worker()
  let (a, left) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = worker.input(Product(0, 0))
  let (b, right) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = worker.input(Product(0, 0))
  let updates = []
  let probe = left.join(right).inspect(fn(d, t, r) { updates.push((d, t, r)) })
  a.update_at((1, 10), Product(3, 1), 2)
  a.close()
  let _ = worker.run()
  b.update_at((1, 20), Product(1, 4), 3)
  b.flush()
  let _ = worker.run()
  assert_eq(updates, [((1, (10, 20)), Product(3L, 4L), 6L)])
  b.update_at((1, 20), Product(2, 5), -1)
  b.close()
  let _ = worker.run()
  assert_eq(updates[1], ((1, (10, 20)), Product(3L, 5L), -2L))
  assert_true(probe.done())
}

///|
test "randomized two input joins agree with full multiset recomputation each epoch" {
  for seed in 1..<17 {
    let worker = @differential.Worker()
    let (a, left) : (
      @differential.InputSession[(Int32, Int32), Int64, Int64],
      @differential.Collection[(Int32, Int32), Int64, Int64],
    ) = worker.input(0)
    let (b, right) : (
      @differential.InputSession[(Int32, Int32), Int64, Int64],
      @differential.Collection[(Int32, Int32), Int64, Int64],
    ) = worker.input(0)
    let observed : Map[(Int32, Int32, Int32), Int64] = Map([])
    let probe = left
      .join(right)
      .consolidate()
      .inspect(fn(d, _, diff) {
        let key = (d.0, d.1.0, d.1.1)
        observed[key] = observed.get(key).unwrap_or(0) + diff
      })
    let left_counts = Array::make(20, 0L)
    let right_counts = Array::make(20, 0L)
    let mut random = seed.reinterpret_as_uint()
    for epoch in 0L..<30L {
      for side in 0..<2 {
        for _ in 0..<4 {
          random = random * 1664525U + 1013904223U
          let index = ((random >> 8) % 20U).reinterpret_as_int()
          let diff = (random % 5U).to_int64() - 2L
          let data = (index / 5, index % 5)
          if side == 0 {
            a.update(data, diff)
            left_counts[index] += diff
          } else {
            b.update(data, diff)
            right_counts[index] += diff
          }
        }
      }
      a.advance_to(epoch + 1)
      b.advance_to(epoch + 1)
      a.flush()
      b.flush()
      assert_true(worker.run() is Quiescent(_))
      assert_false(probe.less_than(epoch + 1))
      for key in 0..<4 {
        for v in 0..<5 {
          for w in 0..<5 {
            assert_eq(
              observed.get((key, v, w)).unwrap_or(0),
              left_counts[key * 5 + v] * right_counts[key * 5 + w],
            )
          }
        }
      }
    }
    a.close()
    b.close()
    let _ = worker.run()
    assert_true(probe.done())
    worker.dispose()
  }
}

///|
test "self join includes each ordered pair exactly once" {
  let worker = @differential.Worker()
  let (input, collection) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = worker.input(0)
  let updates = []
  let _ = collection
    .join(collection)
    .consolidate()
    .inspect(fn(d, t, r) { updates.push((d, t, r)) })
  input.insert((1, 10))
  input.insert((1, 20))
  input.close()
  let _ = worker.run()
  assert_eq(updates, [
    ((1, (10, 10)), 0L, 1L),
    ((1, (10, 20)), 0L, 1L),
    ((1, (20, 10)), 0L, 1L),
    ((1, (20, 20)), 0L, 1L),
  ])
}
