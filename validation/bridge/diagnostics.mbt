///|
#export_name("evaluate_diagnostics")
pub fn evaluate_diagnostics(seed : Int32) -> String {
  let created = Ref(0)
  let shares = Ref(0)
  let resident = Ref(0)
  let logger : @differential.Logger[@differential.DifferentialEvent] = Logger(
    clock=fn() { Duration(0UL) },
    publish=fn(_, events) {
      for (_, event) in events {
        match event {
          BatchCreated(e) => {
            created.val += e.length
            resident.val += e.length
          }
          BatchDropped(e) => resident.val -= e.length
          TraceShare(e) => shares.val += e.diff
          MergeProgress(e) =>
            if e.complete is Some(n) {
              resident.val += n - e.length1 - e.length2
            }
          _ => ()
        }
        guard shares.val >= 0 && resident.val >= 0 else {
          abort("negative log balance")
        }
      }
    },
  )
  let (writer, reader) : (
    @differential.TraceWriter[(Int32, Int32), UInt64, Int64],
    @differential.TraceAgent[(Int32, Int32), UInt64, Int64],
  ) = @differential.shared_spine(0UL, logger=TraceLogger(logger, operator=7))
  let pins = []
  let mut state = seed.reinterpret_as_uint()
  let rows = []
  for epoch in 0UL..<24UL {
    let updates = []
    for _ in 0..<12 {
      state = state * 1664525U + 1013904223U
      let index = ((state >> 8) % 36U).reinterpret_as_int()
      updates.push(((index / 6, index % 6), epoch, (state % 5U).to_int64() - 2))
    }
    if (state >> 16) % 3U == 0 {
      pins.push(reader.clone())
    }
    if state % 5U == 0 && !pins.is_empty() {
      pins.remove(0).release()
    }
    writer.insert(
      Batch(updates, lower=Antichain([epoch]), upper=Antichain([epoch + 1])),
    )
    let frontier = @differential.Antichain([
      if epoch >= 2 {
        epoch - 2
      } else {
        0UL
      },
    ])
    reader.set_logical_compaction(frontier)
    reader.set_physical_compaction(frontier)
    for pin in pins {
      pin.set_logical_compaction(frontier)
      pin.set_physical_compaction(frontier)
    }
    logger.flush()
    rows.push("\{created.val},\{shares.val}")
  }
  writer.close()
  reader.release()
  for pin in pins {
    pin.release()
  }
  logger.flush()
  guard shares.val == 0 && resident.val == 0 else {
    abort("logs retain released storage")
  }
  rows.push("\{shares.val},\{resident.val}")
  rows.join("/")
}
