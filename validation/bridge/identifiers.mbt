///|
#export_name("evaluate_identifiers")
pub fn evaluate_identifiers(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let observed : Map[(Int32, Int32, UInt64), Int64] = Map([])
  let streams = [
    scope.identifiers(source),
    scope.identifiers_with(source, fn(round, value) {
      ((round + value) / 8).to_uint64()
    }),
  ]
  let probes = Array::makei(streams.length(), fn(op) {
    streams[op].inspect(fn(data, _, diff) {
      let key = (op, data.0, data.1)
      observed[key] = observed.get(key).unwrap_or(0L) + diff
    })
  })
  let weights = Array::make(12, 0L)
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for epoch in 0L..<12L {
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 12U).reinterpret_as_int()
      let next = if weights[index] == 0L {
        (random % 3U).to_int64() + 1L
      } else {
        0L
      }
      input.update(index, next - weights[index])
      weights[index] = next
    }
    input.advance_to(epoch + 1)
    input.flush()
    guard worker.run(max_steps=100000) is Quiescent(_) &&
      probes.iter().all(fn(p) { !p.less_than(epoch + 1) }) else {
      abort("identifiers convergence")
    }
    let rows = observed.to_array().filter(fn(x) { x.1 != 0L })
    rows.sort()
    output.push(
      rows.map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1}" }).join(";"),
    )
  }
  input.close()
  guard worker.run() is Quiescent(_) && probes.iter().all(fn(p) { p.done() }) else {
    abort("identifiers closure")
  }
  worker.dispose()
  let hashes = [
    @differential.rust_hash(@differential.Int8(-12)),
    @differential.rust_hash(Int16::from_int(-123)),
    @differential.rust_hash(-456),
    @differential.rust_hash(0xfedcba9876543210UL),
    @differential.rust_hash(
      @differential.UInt128::from_words(
        0x123456789abcdef0UL, 0xfedcba9876543210UL,
      ),
    ),
    @differential.rust_hash("🌙\u0000Moon"),
    @differential.rust_hash(b"\x00\xff"),
    @differential.rust_hash([1, -2, 3]),
    @differential.rust_hash(Some(42)),
    @differential.rust_hash((None : Int32?)),
    @differential.rust_hash(('🌙', true, ())),
  ]
  output.join("/") + "#" + hashes.map(fn(x) { x.to_string() }).join(",")
}
