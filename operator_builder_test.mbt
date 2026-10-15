///|
test "heterogeneous operator routes data with distinct output summaries" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (numbers, ns) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (words, ws) : (
    @differential.InputSession[String, Int64, Int64],
    @differential.Collection[String, Int64, Int64],
  ) = scope.input()
  let builder = scope.operator()
  let n = builder.new_input(ns)
  let (numeric, numeric_stream) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  let (text, text_stream) : (
    @differential.Output[String, Int64, Int64, Int64],
    @differential.Collection[String, Int64, Int64],
  ) = builder.new_output()
  let w = builder.new_input(ws)
  builder.set_connection(n, numeric, [2L])
  builder.set_connection(n, text, [])
  builder.set_connection(w, numeric, [])
  builder.build(fn(initial) {
    try! assert_eq(initial.length(), 2)
    for cap in initial {
      cap.release()
    }
    fn() {
      n.for_each(fn(cap, records) {
        try! assert_true(cap.try_delayed(numeric, cap.time() + 1) is None)
        try! assert_true(cap.try_delayed(text, cap.time() + 9) is None)
        let delayed = cap.delayed(numeric, cap.time() + 2)
        numeric.send(delayed, records)
        delayed.release()
      })
      w.for_each(fn(cap, records) {
        try! assert_true(cap.try_delayed(numeric, cap.time()) is None)
        let retained = cap.delayed(text, cap.time())
        text.send(retained, records)
        retained.release()
      })
    }
  })
  let n_seen = []
  let w_seen = []
  let np = numeric_stream.inspect(fn(d, t, r) { n_seen.push((d, t, r)) })
  let wp = text_stream.inspect(fn(d, t, r) { w_seen.push((d, t, r)) })
  numbers.insert(7)
  numbers.advance_to(1)
  numbers.flush()
  let _ = worker.run()
  assert_eq(n_seen, [(7, 2L, 1L)])
  assert_eq(np.frontier().to_array(), [3L])
  assert_eq(wp.frontier().to_array(), [0L])
  words.insert("hello")
  words.close()
  let _ = worker.run()
  assert_eq(w_seen, [("hello", 0L, 1L)])
  assert_true(wp.done())
  assert_true(!np.done())
  numbers.close()
  let _ = worker.run()
  assert_true(np.done())
  worker.dispose()
}

///|
test "operator input capabilities allow multiple incomparable path summaries" {
  let worker = @differential.Worker()
  let scope = worker.scope(
    @differential.Product(0L, 0L),
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let (input, stream) : (
    @differential.InputSession[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = scope.input()
  let builder = scope.operator()
  let source = builder.new_input(stream)
  let (output, result) : (
    @differential.Output[
      Int32,
      @differential.Product[Int64, Int64],
      Int64,
      @differential.Product[Int64, Int64],
    ],
    @differential.Collection[Int32, @differential.Product[Int64, Int64], Int64],
  ) = builder.new_output()
  builder.set_connection(source, output, [Product(1L, 0L), Product(0L, 2L)])
  builder.build(fn(initial) {
    for cap in initial {
      cap.release()
    }
    fn() {
      source.for_each(fn(cap, records) {
        try! assert_true(cap.try_delayed(output, Product(0L, 1L)) is None)
        for time in [@differential.Product(1L, 0L), Product(0L, 2L)] {
          let cap = cap.delayed(output, time)
          output.send(cap, records)
          cap.release()
        }
      })
    }
  })
  let seen = []
  let probe = result.inspect(fn(_, t, _) { seen.push(t) })
  input.insert(3)
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  assert_eq(seen, [Product(1L, 0L), Product(0L, 2L)])
  worker.dispose()
}

///|
test "panic input capability cannot escape its borrowed callback" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let builder = scope.operator()
  let source = builder.new_input(values)
  let (output, _) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  builder.build(fn(initial) {
    for cap in initial {
      cap.release()
    }
    fn() {
      let borrowed = Ref(None)
      source.for_each(fn(cap, _) { borrowed.val = Some(cap) })
      if borrowed.val is Some(cap) {
        let _ = cap.delayed(output, 0L)
      }
    }
  })
  input.insert(1)
  input.close()
  let _ = worker.run()
}

///|
test "panic unfinished operator builder cannot run" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let _ = scope.operator()
  let _ = worker.run()
}
