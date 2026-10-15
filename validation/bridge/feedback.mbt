///|
#export_name("evaluate_feedback")
pub fn evaluate_feedback(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let (feedback, looped) = scope.feedback((seed % 3 + 1).to_int64())
  let all = values.concat(looped)
  feedback.connect(
    all.map(fn(x) { x + 1 }).filter(fn(x) { x < 12 }).consolidate(),
  )
  let observed : Array[(Int32, Int64, Int64)] = []
  let probe = all
    .consolidate()
    .inspect(fn(d, t, r) { observed.push((d, t, r)) })
  let mut random = seed.reinterpret_as_uint()
  let result = []
  for epoch in 0L..<4L {
    for _ in 0..<8 {
      random = random * 1664525U + 1013904223U
      input.update(
        ((random >> 8) % 8U).reinterpret_as_int(),
        (random % 5U).to_int64() - 2,
      )
    }
    input.advance_to((epoch + 1) * 64)
    input.flush()
    guard worker.run(max_steps=10000) is Quiescent(_) &&
      !probe.less_than(input.time()) else {
      abort("feedback progress stalled")
    }
    result.push(
      @differential.consolidate_updates(observed)
      .map(fn(u) { "\{u.0},\{u.1},\{u.2}" })
      .join(";"),
    )
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("feedback failed to close") }
  worker.dispose()
  result.join("/")
}
