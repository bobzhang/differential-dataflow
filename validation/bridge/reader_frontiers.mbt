///|
fn reader_frontier_text(
  f : @differential.Antichain[@differential.Product[UInt64, UInt64]],
) -> String {
  let values = f.to_array()
  values.sort()
  values.map(fn(t) { "\{t.outer},\{t.inner}" }).join(";")
}

///|
#export_name("evaluate_reader_frontiers")
pub fn evaluate_reader_frontiers(seed : Int32) -> String {
  let (writer, a) : (
    @differential.TraceWriter[
      (Int32, Int32),
      @differential.Product[UInt64, UInt64],
      Int64,
    ],
    @differential.TraceAgent[
      (Int32, Int32),
      @differential.Product[UInt64, UInt64],
      Int64,
    ],
  ) = @differential.shared_spine(Product(0UL, 0UL))
  let b = a.clone()
  let mut state = seed.reinterpret_as_uint()
  let output = []
  for _ in 0..<32 {
    let f = []
    let g = []
    for _ in 0..<2 {
      state = state * 1664525U + 1013904223U
      f.push(
        @differential.Product(
          ((state >> 8) % 9U).to_uint64(),
          ((state >> 16) % 9U).to_uint64(),
        ),
      )
      state = state * 1664525U + 1013904223U
      g.push(
        @differential.Product(
          ((state >> 8) % 9U).to_uint64(),
          ((state >> 16) % 9U).to_uint64(),
        ),
      )
    }
    let target = if (state >> 24) % 2U == 0U { a } else { b }
    target.set_logical_compaction(Antichain(f))
    target.set_physical_compaction(Antichain(g))
    output.push(
      [
        reader_frontier_text(a.logical_compaction()),
        reader_frontier_text(a.physical_compaction()),
        reader_frontier_text(b.logical_compaction()),
        reader_frontier_text(b.physical_compaction()),
      ].join("|"),
    )
  }
  a.set_logical_compaction(Antichain([]))
  a.set_logical_compaction(Antichain([Product(0UL, 0UL)]))
  guard a.logical_compaction().is_empty() else {
    abort("closed compaction frontier reopened")
  }
  writer.close()
  a.release()
  b.release()
  output.join("/")
}
