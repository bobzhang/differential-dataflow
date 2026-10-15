///|
#export_name("evaluate_envelopes")
pub fn evaluate_envelopes(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let seen : Array[(Int32, Int64, Int32, Int64, Int64)] = []
  let observe = fn(
    tag : Int32,
    time : Int64,
    updates : Array[(Int32, Int64, Int64)],
  ) {
    for (d, t, r) in updates {
      seen.push((tag, time, d, t, r))
    }
  }
  let p0 = source
    .consolidate_stream()
    .inspect_batch(fn(t, rows) { observe(0, t, rows) })
    .probe()
  let p1 = source
    .results_in(-3L, @differential.SummaryDomain::int64())
    .inspect_batch(fn(t, rows) { observe(1, t, rows) })
    .probe()
  let p2 = source
    .results_in(3L, @differential.SummaryDomain::int64())
    .delay(fn(t) { t + 2L })
    .inspect_batch(fn(t, rows) { observe(2, t, rows) })
    .probe()
  let p3 = source
    .join_function(
      fn(d) {
        [
          (d + 1, (d % 7).to_int64() * 5L, 2L),
          (d + 1, (d % 5).to_int64() * 7L, -1L),
        ]
      },
      multiply=fn(a, b) { a * b },
    )
    .inspect_batch(fn(t, rows) { observe(3, t, rows) })
    .probe()
  let nested = scope.nested(0L, @differential.SummaryDomain::int64())
  let p4 = nested
    .leave(nested.enter_at(source, fn(d, _) { d.to_int64() }))
    .inspect_batch(fn(t, rows) { observe(4, t, rows) })
    .probe()
  let builder = scope.operator()
  let incoming = builder.new_input(source)
  let (out, forwarded) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = builder.new_output()
  builder.build(fn(caps) {
    for cap in caps {
      cap.release()
    }
    fn() {
      incoming.for_each_batch(fn(cap, rows) {
        let cap = cap.delayed(out, cap.time())
        out.send_at(cap, rows)
        cap.release()
      })
    }
  })
  let p5 = forwarded.inspect_batch(fn(t, rows) { observe(5, t, rows) }).probe()
  let mut state = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0L..<12L {
    for _ in 0..<6 {
      state = state * 1664525U + 1013904223U
      let d = ((state >> 8) % 8U).reinterpret_as_int()
      input.update_at(
        d,
        epoch + 10L + (d % 3).to_int64(),
        (state % 5U).to_int64() - 2L,
      )
    }
    input.advance_to(epoch + 1L)
    input.flush()
    let _ = worker.run()
    for probe in [p0, p1, p2, p3, p4, p5] {
      guard !probe.less_than(epoch + 1L) else {
        abort("message frontier stalled")
      }
    }
    seen.sort()
    results.push(
      seen
      .map(fn(row) { "\{row.0},\{row.1},\{row.2},\{row.3},\{row.4}" })
      .join(";"),
    )
  }
  input.close()
  let _ = worker.run()
  for probe in [p0, p1, p2, p3, p4, p5] {
    guard probe.done() else { abort("message frontier did not close") }
  }
  seen.sort()
  results.push(
    seen
    .map(fn(row) { "\{row.0},\{row.1},\{row.2},\{row.3},\{row.4}" })
    .join(";"),
  )
  worker.dispose()
  results.join("/")
}
