///|
#export_name("evaluate_probes")
pub fn evaluate_probes(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0UL, @differential.SummaryDomain::uint64())
  let (a, left) : (
    @differential.InputSession[Int32, UInt64, Int64],
    @differential.Collection[Int32, UInt64, Int64],
  ) = scope.input()
  let (b, right) : (
    @differential.InputSession[Int32, UInt64, Int64],
    @differential.Collection[Int32, UInt64, Int64],
  ) = scope.input()
  let shared = @differential.Probe()
  let pa = left.probe_with(shared).probe()
  let pb = right.probe_with(shared).probe()
  let mut state = seed.reinterpret_as_uint()
  let mut ta = 0UL
  let mut tb = 0UL
  let rows = []
  let snapshot = fn() {
    shared.frontier().to_array().map(fn(t) { t.to_string() }).join(",")
  }
  for _ in 0..<12 {
    state = state * 1664525U + 1013904223U
    a.update(1, 1L)
    b.update(2, -1L)
    ta += ((state >> 8) % 3U + 1U).to_uint64()
    tb += ((state >> 16) % 3U + 1U).to_uint64()
    a.advance_to(ta)
    a.flush()
    b.advance_to(tb)
    b.flush()
    let _ = worker.run()
    guard !pa.less_than(ta) && !pb.less_than(tb) else {
      abort("shared probe stalled")
    }
    rows.push(snapshot())
  }
  a.close()
  let _ = worker.run()
  guard pa.done() else { abort("first probe did not close") }
  rows.push(snapshot())
  b.close()
  let _ = worker.run()
  guard pb.done() && shared.done() else { abort("shared probe did not close") }
  rows.push(snapshot())
  worker.dispose()
  rows.join("/")
}
