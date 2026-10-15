///|
#export_name("evaluate_cursors")
pub fn evaluate_cursors(seed : Int32) -> String {
  cursors_case(seed, false)
}

///|
#export_name("evaluate_columnar_cursors")
pub fn evaluate_columnar_cursors(seed : Int32) -> String {
  cursors_case(seed, true)
}

///|
fn cursors_case(seed : Int32, columnar : Bool) -> String {
  let mut random = seed.reinterpret_as_uint()
  let batches = []
  for epoch in 0L..<8L {
    let updates = []
    for _ in 0..<32 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 64U).reinterpret_as_int()
      updates.push(
        ((index / 8, index % 8), epoch, (random % 5U).to_int64() - 2),
      )
    }
    updates.push(((9, 9), epoch, 1L))
    let batch = @differential.Batch(
      updates,
      lower=Antichain([epoch]),
      upper=Antichain([epoch + 1]),
    )
    let batch = if columnar { batch.columnar().batch() } else { batch }
    batches.push(batch.view())
  }
  let cursor = @differential.Cursor(batches)
  let output = []
  for _ in 0..<128 {
    random = random * 1664525U + 1013904223U
    let target = ((random >> 8) % 10U).reinterpret_as_int()
    match random % 6U {
      0U => cursor.step_key()
      1U => cursor.step_val()
      2U => cursor.seek_key(target)
      3U => if cursor.key_valid() { cursor.seek_val(target) }
      4U => cursor.rewind_keys()
      _ => cursor.rewind_vals()
    }
    let key = cursor.key().unwrap_or(-1)
    let value = cursor.val().unwrap_or(-1)
    let times = cursor.times()
    times.sort()
    output.push(
      "\{key},\{value}|" + times.map(fn(x) { "\{x.0},\{x.1}" }).join(";"),
    )
  }
  output.join("/")
}
