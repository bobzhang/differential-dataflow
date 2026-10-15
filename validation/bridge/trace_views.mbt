///|
#export_name("evaluate_trace_views")
pub fn evaluate_trace_views(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let batches = []
  let metadata = []
  for epoch in 0L..<8L {
    let updates = []
    for _ in 0..<32 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 64U).reinterpret_as_int()
      updates.push(
        ((index / 8, index % 8), epoch, (random % 5U).to_int64() - 2),
      )
    }
    let batch = @differential.Batch(
      updates,
      lower=Antichain([epoch]),
      upper=Antichain([epoch + 1]),
    )
    let entered = batch
      .view()
      .frontier(Antichain([3L]), Antichain([6L]))
      .map_times_at(fn(time) { @differential.Product(time, 0L) }, fn(
        data,
        time,
      ) {
        Product(time, ((data.0 + data.1) % 5).to_int64())
      })
    let lo = entered.description().lower().to_array()[0]
    let hi = entered.description().upper().to_array()[0]
    let since = entered.description().since().to_array()[0]
    metadata.push(
      "\{entered.length()},\{lo.outer},\{lo.inner},\{hi.outer},\{hi.inner},\{since.outer},\{since.inner}",
    )
    batches.push(entered)
  }
  let cursor = @differential.Cursor(batches)
  let records = []
  while cursor.key() is Some(key) {
    while cursor.val() is Some(value) {
      let times = cursor.times()
      times.sort()
      records.push(
        "\{key},\{value}|" +
        times.map(fn(x) { "\{x.0.outer},\{x.0.inner},\{x.1}" }).join(";"),
      )
      cursor.step_val()
    }
    cursor.step_key()
  }
  metadata.join("/") + "#" + records.join("/")
}
