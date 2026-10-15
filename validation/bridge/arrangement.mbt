///|
#export_name("evaluate_arrangement")
pub fn evaluate_arrangement(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let arranged = values.arrange_by_key()
  let fast = arranged.trace()
  let slow = arranged.trace()
  arranged.release()
  let probe = arranged.as_collection().probe()
  let mut random = seed.reinterpret_as_uint()
  let result = []
  for epoch in 0L..<16L {
    for _ in 0..<6 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 12U).reinterpret_as_int()
      input.update((index / 4, index % 4), (random % 5U).to_int64() - 2)
    }
    input.advance_to(epoch + 1)
    input.flush()
    guard worker.run() is Quiescent(_) && !probe.less_than(epoch + 1) else {
      abort("arrangement progress stalled")
    }
    let past = epoch / 4 * 4
    fast.set_logical_compaction(Antichain([epoch]))
    fast.set_physical_compaction(Antichain([epoch + 1]))
    slow.set_logical_compaction(Antichain([past]))
    slow.set_physical_compaction(Antichain([past]))
    result.push(
      [past, epoch]
      .map(fn(query) {
        slow.snapshot(query).map(fn(x) { "\{x.0.0},\{x.0.1},\{x.1}" }).join(";")
      })
      .join("|"),
    )
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("arrangement failed to close") }
  fast.release()
  slow.release()
  worker.dispose()
  result.join("/")
}
