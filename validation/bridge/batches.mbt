///|
#export_name("evaluate_batches")
pub fn evaluate_batches(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let batcher : @differential.Batcher[
    (Int32, Int32),
    @differential.Product[Int64, Int64],
    Int64,
  ] = Batcher(Product(0L, 0L))
  let batches = []
  let output = []
  for epoch in 0L..<8L {
    for _ in 0..<3 {
      let updates = []
      for _ in 0..<16 {
        random = random * 1664525U + 1013904223U
        let index = ((random >> 8) % 256U).reinterpret_as_int()
        updates.push(
          (
            (index / 64, index / 16 % 4),
            @differential.Product(
              epoch + (index / 4 % 4).to_int64(),
              epoch + (index % 4).to_int64(),
            ),
            (random % 5U).to_int64() - 2,
          ),
        )
      }
      batcher.push(updates)
    }
    let (chain, description) = batcher.seal(
      Antichain([Product(epoch + 1, 0L), Product(0L, epoch + 1)]),
    )
    let batch = @differential.BatchBuilder::seal(chain, description)
    output.push(batch_records(batch) + "|" + batch_frontier(batcher.frontier()))
    batches.push(batch)
  }
  let (chain, description) = batcher.seal(Antichain([]))
  batches.push(@differential.BatchBuilder::seal(chain, description))
  let since = @differential.Antichain([
    @differential.Product(4L, 2L),
    Product(2L, 4L),
  ])
  let mut merged = batches[0]
  for i in 1..<batches.length() {
    let merger = merged.begin_merge(batches[i], since)
    while true {
      if merger.work(1) > 0 {
        break
      }
    }
    merged = merger.done()
  }
  output.push(
    batch_records(merged) + "|" + batch_frontier(merged.description().since()),
  )
  output.join("/")
}

///|
fn batch_records(
  batch : @differential.Batch[
    (Int32, Int32),
    @differential.Product[Int64, Int64],
    Int64,
  ],
) -> String {
  batch
  .to_array()
  .map(fn(u) { "\{u.0.0},\{u.0.1},\{u.1.outer},\{u.1.inner},\{u.2}" })
  .join(";")
}

///|
fn batch_frontier(
  frontier : @differential.Antichain[@differential.Product[Int64, Int64]],
) -> String {
  let values = frontier.to_array()
  values.sort()
  values.map(fn(t) { "\{t.outer},\{t.inner}" }).join(";")
}
