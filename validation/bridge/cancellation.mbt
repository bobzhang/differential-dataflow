///|
#export_name("evaluate_cancellation")
pub fn evaluate_cancellation(seed : Int32) -> String {
  let worker = @differential.Worker()
  let (sibling, values) : (
    @differential.InputSession[Int64, Int64, Int64],
    @differential.Collection[Int64, Int64, Int64],
  ) = worker.scope(0L, @differential.SummaryDomain::int64()).input()
  let sum = Ref(0L)
  let live = values.inspect(fn(d, _, r) { sum.val += d * r })
  let results = []
  let mut random = seed.reinterpret_as_uint()
  for epoch in 0L..<16L {
    let id = worker.next_dataflow_index()
    let scope = worker.scope(0L, @differential.SummaryDomain::int64())
    let (input, values) : (
      @differential.InputSession[Int64, Int64, Int64],
      @differential.Collection[Int64, Int64, Int64],
    ) = scope.input()
    let nested = scope.nested(0L, @differential.SummaryDomain::int64())
    let observed = Ref(0L)
    let probe = nested
      .leave(nested.enter(values).map(fn(d) { d * 2L }))
      .inspect(fn(d, _, r) { observed.val += d * r })
    random = random * 1664525U + 1013904223U
    let value = ((random >> 8) % 100U).to_int64()
    input.insert(value)
    input.advance_to(1L)
    input.flush()
    let _ = worker.run()
    guard !probe.less_than(1L) else { abort("cancellation fixture stalled") }
    input.insert(999L)
    input.flush()
    worker.drop_dataflow(id)
    input.close()
    sibling.insert(value)
    sibling.advance_to(epoch + 1L)
    sibling.flush()
    let _ = worker.run()
    guard !live.less_than(epoch + 1L) else {
      abort("sibling stalled after cancellation")
    }
    results.push(
      "\{observed.val},\{sum.val},\{probe.done()},\{worker.installed_dataflows().contains(id)}",
    )
  }
  sibling.close()
  let _ = worker.run()
  guard live.done() else { abort("sibling did not close") }
  worker.dispose()
  results.join("/")
}
