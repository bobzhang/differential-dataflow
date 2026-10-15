///|
#export_name("evaluate_stream_reduce")
pub fn evaluate_stream_reduce(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(
    @differential.Product(0L, 0L),
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let (output, initial, source) : (
    @differential.Output[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
      @differential.Product[Int64, Int64],
    ],
    @differential.Capability[
      @differential.Product[Int64, Int64],
      @differential.Product[Int64, Int64],
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = scope.source()
  let capabilities = @differential.CapabilitySet(initial)
  let seen = []
  let probe = source
    .reduce(fn(_, values) {
      [(values.iter().fold(init=0L, fn(sum, x) { sum + x.1 }), 1L)]
    })
    .inspect(fn(data, time, diff) { seen.push((data.1, time, diff)) })
  let mut random = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0L..<24L {
    for side in 0..<2 {
      let time = if side == 0 {
        @differential.Product(epoch, epoch + 1)
      } else {
        Product(epoch + 1, epoch)
      }
      let capability = capabilities.try_delayed(time).unwrap()
      for _ in 0..<3 {
        random = random * 1664525U + 1013904223U
        let value = ((random >> 8) % 4U).reinterpret_as_int()
        output.send(capability, [((0, value), (random % 5U).to_int64() - 2L)])
      }
      capability.release()
    }
    let frontier = @differential.Antichain([
      @differential.Product(epoch + 2, epoch),
      Product(epoch, epoch + 2),
    ])
    guard capabilities.try_downgrade(frontier.to_array()) else {
      abort("invalid capability transition")
    }
    guard worker.run() is Quiescent(_) && frontier.precedes(probe.frontier()) else {
      abort("reduction progress stalled")
    }
    let completed = @differential.consolidate_updates(
      seen.filter(fn(x) { !frontier.less_equal(x.1) }),
    )
    results.push(
      completed
      .map(fn(x) { "\{x.0},\{x.1.outer},\{x.1.inner},\{x.2}" })
      .join(";"),
    )
  }
  capabilities.release()
  let _ = worker.run()
  guard probe.done() else { abort("reduction did not close") }
  worker.dispose()
  results.join("/")
}
