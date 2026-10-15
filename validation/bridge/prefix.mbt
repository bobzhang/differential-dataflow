///|
#export_name("evaluate_prefix")
pub fn evaluate_prefix(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[((UInt64, Int32), Int64), Int64, Int64],
    @differential.Collection[((UInt64, Int32), Int64), Int64, Int64],
  ) = scope.input()
  let (queries, locations) : (
    @differential.InputSession[(UInt64, Int32), Int64, Int64],
    @differential.Collection[(UInt64, Int32), Int64, Int64],
  ) = scope.input()
  let results : Map[(Int32, UInt64, Int32, Int64), Int64] = Map([])
  let streams = [
    scope.prefix_sum_at(source, locations, 0L, fn(_, a, b) { a + b }),
    scope.prefix_sum(source, 0L, fn(_, a, b) { a + b }),
  ]
  let probes = Array::makei(streams.length(), fn(op) {
    streams[op].inspect(fn(data, _, diff) {
      let key = (op, data.0.0, data.0.1, data.1)
      results[key] = results.get(key).unwrap_or(0L) + diff
    })
  })
  let positions = [0UL, 1UL, 3UL, 7UL, 10UL, 31UL, 1UL << 32, 1UL << 63]
  let targets = [
    0UL,
    1UL,
    2UL,
    4UL,
    8UL,
    32UL,
    1UL << 63,
    0xffff_ffff_ffff_ffffUL,
  ]
  let values = Array::make(16, 0L)
  let requests = Array::make(16, 0L)
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for epoch in 0L..<12L {
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 16U).reinterpret_as_int()
      let value = values[index]
      let key = (positions[index % 8], index / 8)
      if value != 0L {
        input.remove((key, value))
      }
      values[index] = if value == 0L {
        (random % 9U).to_int64() + 1L
      } else {
        0L
      }
      if values[index] != 0L {
        input.insert((key, values[index]))
      }
    }
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 16U).reinterpret_as_int()
      let next = if requests[index] == 0L {
        (random % 2U).to_int64() + 1L
      } else {
        0L
      }
      queries.update((targets[index % 8], index / 8), next - requests[index])
      requests[index] = next
    }
    input.advance_to(epoch + 1)
    queries.advance_to(epoch + 1)
    input.flush()
    queries.flush()
    guard worker.run(max_steps=100000) is Quiescent(_) &&
      probes.iter().all(fn(p) { !p.less_than(epoch + 1) }) else {
      abort("prefix convergence")
    }
    let snapshot = results.to_array().filter(fn(x) { x.1 != 0L })
    snapshot.sort()
    output.push(
      snapshot
      .map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.0.3},\{x.1}" })
      .join(";"),
    )
  }
  input.close()
  queries.close()
  guard worker.run() is Quiescent(_) && probes.iter().all(fn(p) { p.done() }) else {
    abort("prefix closure")
  }
  worker.dispose()
  output.join("/")
}
