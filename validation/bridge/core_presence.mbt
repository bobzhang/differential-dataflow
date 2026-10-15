///|
#export_name("evaluate_core_presence")
pub fn evaluate_core_presence(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(
    @differential.Product(0L, 0L),
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let (input, source) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = scope.input()
  let logic = fn(
    _ : Int32,
    values : Array[(Int32, Int64)],
    previous : Array[(Int32, @differential.Present)],
  ) {
    values
    .filter(fn(value) { !previous.iter().any(fn(old) { old.0 == value.0 }) })
    .map(fn(value) { (value.0, @differential.Present) })
  }
  let result = if seed % 3 == 0 {
    source.reduce_core(logic)
  } else {
    let index = source.arrange_by_key(columnar=seed % 3 == 1)
    let result = index.reduce_core(logic)
    index.release()
    result
  }
  let observed = []
  let probe = result
    .as_collection()
    .inspect(fn(d, t, _) { observed.push((d, t)) })
  result.release()
  let mut random = seed.reinterpret_as_uint()
  for _ in 0..<48 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 375U).reinterpret_as_int()
    input.update_at(
      (index / 125, index % 5),
      Product((index / 25 % 5).to_int64(), (index / 5 % 5).to_int64()),
      (random % 3U).to_int64() + 1L,
    )
  }
  input.close()
  let _ = worker.run()
  guard probe.done() else { abort("semigroup reduction did not close") }
  worker.dispose()
  let rows = []
  for x in 0L..<5L {
    for y in 0L..<5L {
      let present : Set[(Int32, Int32)] = Set([])
      for (data, time) in observed {
        if time.outer <= x && time.inner <= y {
          present.add(data)
        }
      }
      let values = present.to_array()
      values.sort()
      rows.push(values.map(fn(pair) { "\{pair.0},\{pair.1}" }).join(";"))
    }
  }
  rows.join("/")
}
