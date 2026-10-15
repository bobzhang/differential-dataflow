///|
#export_name("evaluate_dynamic")
pub fn evaluate_dynamic(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let index = source.arrange_by_key(fueled=true, columnar=true)
  let trace = index.trace()
  let queries : Array[(Map[(Int32, Int32), Int64], @differential.Probe[Int64])] = []
  let mut random = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0..<16 {
    for _ in 0..<6 {
      random = random * 1664525U + 1013904223U
      let key = ((random >> 8) % 16U).reinterpret_as_int()
      input.update((key / 4, key % 4), (random % 5U).to_int64() - 2L)
    }
    input.advance_to(epoch.to_int64() + 1)
    input.flush()
    let _ = worker.run()
    let target = worker.scope(0L, @differential.SummaryDomain::int64())
    let observed : Map[(Int32, Int32), Int64] = Map([])
    let probe = trace
      .import_into(target)
      .map(fn(data) { (data.0, data.1 + epoch) })
      .consolidate()
      .inspect(fn(data, _, diff) {
        observed[data] = observed.get(data).unwrap_or(0L) + diff
      })
    queries.push((observed, probe))
    let _ = worker.run()
    let snapshots = []
    for (observed, probe) in queries {
      guard !probe.less_than(epoch.to_int64() + 1) else {
        abort("dynamic import stalled")
      }
      let records = observed.to_array().filter(fn(record) { record.1 != 0L })
      records.sort()
      snapshots.push(
        records.map(fn(r) { "\{r.0.0},\{r.0.1},\{r.1}" }).join(";"),
      )
    }
    results.push(snapshots.join("|"))
  }
  input.close()
  let _ = worker.run()
  guard queries.iter().all(fn(query) { query.1.done() }) else {
    abort("dynamic import did not close")
  }
  trace.release()
  index.release()
  worker.dispose()
  results.join("/")
}
