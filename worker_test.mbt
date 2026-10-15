///|
test "scheduled collection pipeline preserves timestamps and progress" {
  let worker = @differential.Worker()
  let (input, collection) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let updates = []
  let probe = collection
    .map(fn(x) { x * 2 })
    .filter(fn(x) { x > 2 })
    .consolidate()
    .inspect(fn(data, time, diff) { updates.push((data, time, diff)) })
  input.insert(1)
  input.insert(2)
  input.insert(2)
  input.remove(2)
  input.update_at(3, 2, 4)
  input.advance_to(1)
  input.flush()
  assert_true(probe.less_than(1))
  assert_true(worker.run() is Quiescent(_))
  assert_eq(updates, [(4, 0L, 1L)])
  assert_false(probe.less_than(1))
  assert_true(probe.less_equal(1))
  input.advance_to(3)
  input.flush()
  assert_true(worker.run() is Quiescent(_))
  assert_eq(updates, [(4, 0L, 1L), (6, 2L, 4L)])
  input.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  worker.dispose()
}

///|
test "fanout, cross weight transformation, and bounded scheduler runs" {
  let worker = @differential.Worker()
  let (input, collection) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let normal = []
  let negative = []
  let scaled = []
  let p = collection.inspect(fn(d, _, r) { normal.push((d, r)) })
  let q = collection.negate().inspect(fn(d, _, r) { negative.push((d, r)) })
  let r = collection
    .explode(fn(d) { [(d + 1, fn(w) { w.to_int() * 3 })] })
    .inspect(fn(d, _, w) { scaled.push((d, w)) })
  input.insert(5)
  input.close()
  assert_true(worker.run(max_steps=0) is StepLimit(0))
  assert_true(worker.run(max_steps=1) is StepLimit(1))
  assert_true(worker.run() is Quiescent(_))
  assert_eq(normal, [(5, 1L)])
  assert_eq(negative, [(5, -1L)])
  assert_eq(scaled, [(6, 3)])
  assert_true(p.done() && q.done() && r.done())
}

///|
test "empty collection retains input capability until closed" {
  let worker = @differential.Worker()
  let (input, collection) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let probe = collection.probe()
  assert_true(worker.run() is Quiescent(_))
  assert_false(probe.done())
  input.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
}

///|
test "panic graph mutation after execution" {
  let worker = @differential.Worker()
  let (_, collection) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = worker.input(0)
  let _ = worker.run()
  let _ = collection.map(fn(x) { x })
}
