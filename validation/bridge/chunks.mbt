///|
fn chunk_text(
  chunk : @differential.UpdatesTyped[
    Int32,
    Int32,
    @differential.Product[UInt64, UInt64],
    Int64,
  ],
) -> String {
  chunk
  .iter()
  .map(fn(row) { "\{row.0},\{row.1},\{row.2.outer},\{row.2.inner},\{row.3}" })
  .to_array()
  .join(";")
}

///|
#export_name("evaluate_chunks")
pub fn evaluate_chunks(seed : Int32) -> String {
  let mut state = seed.reinterpret_as_uint()
  let cases = []
  for case in 0..<16 {
    let inputs = []
    for side in 0..<2 {
      let raw = []
      for _ in 0..<24 {
        state = state * 1664525U + 1013904223U
        let x = ((state >> 8) % 256U).reinterpret_as_int()
        if (case + side + seed) % 11 != 0 {
          raw.push(
            (
              x / 64,
              x / 16 % 4,
              @differential.Product(
                (x / 4 % 4).to_uint64(),
                (x % 4).to_uint64(),
              ),
              (state % 5U).to_int64() - 2,
            ),
          )
        }
      }
      inputs.push(@differential.UpdatesTyped(raw).consolidate())
    }
    let left = inputs[0]
    let right = inputs[1]
    let (head, a, b) = left.merge_pair(right)
    let builder = @differential.UpdatesBuilder()
    builder.meld(head)
    if a is Some(c) {
      builder.meld(c)
    }
    if b is Some(c) {
      builder.meld(c)
    }
    let full = builder.done()
    let count = (state % (full.length() + 3).reinterpret_as_uint()).reinterpret_as_int()
    let (first, second) = full.split_at(count)
    let upper = @differential.Antichain([
      @differential.Product(1UL, 3UL),
      Product(3UL, 1UL),
    ])
    let (ready, kept, frontier) = full.extract(upper)
    let times = frontier.to_array()
    times.sort()
    let frontier_text = times.map(fn(t) { "\{t.outer},\{t.inner}" }).join(";")
    cases.push(
      [
        chunk_text(left),
        chunk_text(right),
        chunk_text(head),
        a.map(chunk_text).unwrap_or(""),
        b.map(chunk_text).unwrap_or(""),
        chunk_text(full),
        chunk_text(first),
        chunk_text(second),
        chunk_text(ready),
        chunk_text(kept),
        frontier_text,
      ].join("|"),
    )
  }
  cases.join("/")
}
