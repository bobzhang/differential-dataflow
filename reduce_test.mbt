///|
test "distinct and count retract old results as weights change" {
  let worker = @differential.Worker()
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let distinct = []
  let counts = []
  let p = values.distinct().inspect(fn(d, t, r) { distinct.push((d, t, r)) })
  let q = values.count().inspect(fn(d, t, r) { counts.push((d, t, r)) })
  input.update(1, 2)
  input.advance_to(1)
  input.flush()
  let _ = worker.run()
  input.update(1, -3)
  input.advance_to(2)
  input.flush()
  let _ = worker.run()
  input.update(1, 1)
  input.close()
  let _ = worker.run()
  assert_eq(distinct, [(1, 0L, 1L), (1, 2L, -1L)])
  assert_eq(counts, [
    ((1, 2L), 0L, 1L),
    ((1, -1L), 1L, 1L),
    ((1, 2L), 1L, -1L),
    ((1, -1L), 2L, -1L),
  ])
  assert_true(p.done() && q.done())
}

///|
test "partial order distinct introduces correction at synthetic join timestamp" {
  let worker = @differential.Worker()
  let (input, values) : (
    @differential.InputSession[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = worker.input(Product(0, 0))
  let updates = []
  let _ = values.distinct().inspect(fn(d, t, r) { updates.push((d, t, r)) })
  input.update_at(1, Product(1, 0), 1)
  input.update_at(1, Product(0, 1), 1)
  input.close()
  let _ = worker.run()
  assert_eq(updates, [
    (1, Product(0L, 1L), 1L),
    (1, Product(1L, 0L), 1L),
    (1, Product(1L, 1L), -1L),
  ])
}

///|
test "grouped min reduction ignores absent values after retraction" {
  let worker = @differential.Worker()
  let (input, pairs) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = worker.input(0)
  let updates = []
  let _ = pairs
    .reduce(fn(_, values) { [(values[0].0, 1L)] })
    .inspect(fn(d, t, r) { updates.push((d, t, r)) })
  input.insert((1, 3))
  input.insert((1, 5))
  input.advance_to(1)
  input.flush()
  let _ = worker.run()
  input.remove((1, 3))
  input.close()
  let _ = worker.run()
  assert_eq(updates, [((1, 3), 0L, 1L), ((1, 3), 1L, -1L), ((1, 5), 1L, 1L)])
}

///|
test "random product distinct snapshots match independent count recomputation" {
  for seed in 1..<17 {
    let worker = @differential.Worker()
    let (input, values) : (
      @differential.InputSession[
        Int32,
        @differential.Product[Int64, Int64],
        Int64,
      ],
      @differential.Collection[
        Int32,
        @differential.Product[Int64, Int64],
        Int64,
      ],
    ) = worker.input(Product(0, 0))
    let output = []
    let _ = values.distinct().inspect(fn(d, t, r) { output.push((d, t, r)) })
    let history = []
    let mut random = seed.reinterpret_as_uint()
    for _ in 0..<24 {
      random = random * 1664525U + 1013904223U
      let key = ((random >> 8) % 3U).reinterpret_as_int()
      let x = ((random >> 12) % 5U).to_int64()
      let y = ((random >> 18) % 5U).to_int64()
      let diff = (random % 5U).to_int64() - 2L
      input.update_at(key, Product(x, y), diff)
      history.push((key, x, y, diff))
    }
    input.close()
    let _ = worker.run()
    for x in 0L..<5L {
      for y in 0L..<5L {
        for key in 0..<3 {
          let mut count = 0L
          for (k, at_x, at_y, diff) in history {
            if k == key && at_x <= x && at_y <= y {
              count += diff
            }
          }
          let mut actual = 0L
          for (k, time, diff) in output {
            if k == key && time.outer <= x && time.inner <= y {
              actual += diff
            }
          }
          assert_eq(actual, if count == 0 { 0L } else { 1L })
        }
      }
    }
    worker.dispose()
  }
}

///|
test "reduce does not mutate a cached callback result" {
  let worker = @differential.Worker()
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = worker.input(0)
  let cached = [(42, 1L)]
  let updates = []
  let _ = values
    .reduce(fn(_, _) { cached })
    .inspect(fn(d, t, r) { updates.push((d, t, r)) })
  input.insert((1, 3))
  input.advance_to(1)
  input.flush()
  let _ = worker.run()
  input.insert((1, 4))
  input.close()
  let _ = worker.run()
  assert_eq(cached, [(42, 1L)])
  assert_eq(updates, [((1, 42), 0L, 1L)])
}
