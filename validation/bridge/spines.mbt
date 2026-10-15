///|
#export_name("evaluate_spines")
pub fn evaluate_spines(seed : Int32) -> String {
  spines_case(seed, false)
}

///|
#export_name("evaluate_columnar_spines")
pub fn evaluate_columnar_spines(seed : Int32) -> String {
  spines_case(seed, true)
}

///|
fn spines_case(seed : Int32, columnar : Bool) -> String {
  let spine : @differential.Spine[(Int32, Int32), Int64, Int64] = Spine(0L)
  spine.set_exert_logic(fn(_) { Some(1) })
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for epoch in 0L..<32L {
    let updates = []
    for _ in 0..<12 {
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
    let earliest = Int64::max(0L, epoch - 3)
    spine.set_logical_compaction(Antichain([earliest]))
    spine.set_physical_compaction(Antichain([Int64::max(0L, epoch - 2)]))
    spine.insert(if columnar { batch.columnar().batch() } else { batch })
    spine.exert()
    spine.exert()
    let snapshots = []
    for query in earliest..<(epoch + 1) {
      let cursor = spine.cursor()
      let records = []
      while cursor.key() is Some(key) {
        while cursor.val() is Some(value) {
          let mut sum = 0L
          cursor.map_times(fn(time, diff) { if time <= query { sum += diff } })
          if sum != 0L {
            records.push("\{key},\{value},\{sum}")
          }
          cursor.step_val()
        }
        cursor.step_key()
      }
      snapshots.push(records.join(";"))
    }
    output.push(snapshots.join("|"))
  }
  spine.close()
  guard spine.upper().is_empty() else { abort("spine did not close") }
  output.join("/")
}
