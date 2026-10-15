///|
#export_name("evaluate_capture_async")
pub fn evaluate_capture_async(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let messages : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  let mut retry = false
  let capture = scope.capture_to(
    source,
    CaptureWriter(
      poll=fn(message) {
        if message is Updates(_) {
          retry = !retry
          if retry {
            return Some(Duration(0UL))
          }
        }
        messages.push(message)
        None
      },
      done=fn() { true },
    ),
  )
  let inbox : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  let (handle, replay) = scope.replay_from(
    fn(_) { fn() { inbox.pop() } },
    messages_per_turn=1,
  )
  let observed : Map[Int32, Int64] = Map([])
  let probe = replay.inspect(fn(d, _, r) {
    observed[d] = observed.get(d).unwrap_or(0L) + r
  })
  let mut random = seed.reinterpret_as_uint()
  let output = []
  for epoch in 0L..<24L {
    for _ in 0..<12 {
      random = random * 1664525U + 1013904223U
      input.update(
        ((random >> 8) % 16U).reinterpret_as_int(),
        (random % 5U).to_int64() - 2L,
      )
    }
    input.advance_to(epoch + 1)
    input.flush()
    let _ = worker.run()
    for message in messages {
      inbox.push(message)
      inbox.push(message)
    }
    messages.clear()
    handle.activate()
    let _ = worker.run()
    guard !probe.less_than(epoch + 1) else { abort("replay failed to advance") }
    let rows = observed.to_array().filter(fn(row) { row.1 != 0L })
    rows.sort()
    output.push(rows.map(fn(row) { "\{row.0},\{row.1}" }).join(";"))
  }
  input.close()
  let _ = worker.run()
  for message in messages {
    inbox.push(message)
  }
  handle.activate()
  let _ = worker.run()
  guard capture.is_complete() && handle.is_complete() && probe.done() else {
    abort("capture/replay failed to close")
  }
  worker.dispose()
  output.join("/")
}
