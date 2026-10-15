///|
fn next_word(state : Ref[UInt32]) -> UInt64 {
  state.val = state.val * 1664525U + 1013904223U
  let high = state.val.to_uint64()
  state.val = state.val * 1664525U + 1013904223U
  (high << 32) | state.val.to_uint64()
}

///|
#export_name("evaluate_numeric")
pub fn evaluate_numeric(seed : Int32) -> String {
  let state = Ref(seed.reinterpret_as_uint())
  let results = []
  for _ in 0..<64 {
    let ah = next_word(state)
    let al = next_word(state)
    let bh = next_word(state)
    let bl = next_word(state)
    let a = @differential.Int128::from_words(ah.reinterpret_as_int64(), al)
    let b = @differential.Int128::from_words(bh.reinterpret_as_int64(), bl)
    let u = @differential.UInt128::from_words(ah, al)
    let v = @differential.UInt128::from_words(bh, bl)
    let checked = match a.checked_add(b) {
      Some(sum) => sum.to_string()
      None => "_"
    }
    let checked_u = match u.checked_add(v) {
      Some(sum) => sum.to_string()
      None => "_"
    }
    let duration_a = @differential.Duration(
      ah,
      nanoseconds=(al % 1000000000UL).to_uint(),
    )
    let duration_b = @differential.Duration(
      bh,
      nanoseconds=(bl % 1000000000UL).to_uint(),
    )
    let duration = match duration_a.checked_add(duration_b) {
      None => "_"
      Some(sum) => "\{sum.seconds()},\{sum.nanoseconds()}"
    }
    results.push(
      "\{a.plus(b).to_string()},\{a.multiply(b).to_string()},\{checked},\{u.plus(v).to_string()},\{u.multiply(v).to_string()},\{checked_u},\{duration}",
    )
  }
  results.join(";")
}
