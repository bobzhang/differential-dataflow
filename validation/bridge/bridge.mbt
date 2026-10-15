///|
#export_name("evaluate")
pub fn evaluate(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let frontier : @differential.MutableAntichain[
    @differential.Product[Int64, Int64],
  ] = MutableAntichain()
  let result = []
  for _ in 0..<40 {
    let updates = []
    for _ in 0..<3 {
      random = random * 1664525U + 1013904223U
      let index = ((random >> 8) % 25U).to_int64()
      let delta = if random % 3U == 0U { -1L } else { 1L }
      updates.push((@differential.Product(index / 5, index % 5), delta))
    }
    let changes = frontier
      .update_all(updates)
      .map(fn(u) { "\{u.0.outer},\{u.0.inner},\{u.1}" })
      .join(";")
    let minimal = frontier
      .frontier()
      .to_array()
      .map(fn(t) { "\{t.outer},\{t.inner}" })
      .join(";")
    let time = @differential.advance_by(
      @differential.Product((seed % 5).to_int64(), (seed / 5 % 5).to_int64()),
      frontier.frontier(),
    )
    result.push("\{changes}|\{minimal}|\{time.outer},\{time.inner}")
  }
  result.join("/")
}
