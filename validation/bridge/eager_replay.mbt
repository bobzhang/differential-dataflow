///|
#export_name("evaluate_eager_replay")
pub fn evaluate_eager_replay(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let row = (seed, 0L, (seed % 7 + 1).to_int64())
  let queue : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = [
    Updates([row, row]),
  ]
  let (handle, stream) = scope.replay_from(fn(_) { fn() { queue.pop() } })
  let mut count = 0
  let probe = stream.inspect(fn(_, _, _) { count += 1 })
  let output = []
  for phase in 0..<3 {
    if phase == 1 {
      queue.push(
        Progress(CaptureProgress(Antichain([0L]), Antichain([1L]), [(0L, 1L)])),
      )
    }
    if phase == 2 {
      queue.push(Progress(CaptureProgress(Antichain([1L]), Antichain([]), [])))
    }
    handle.activate()
    let _ = worker.run()
    output.push("\{count},\{probe.less_than(1L)},\{probe.done()}")
  }
  worker.dispose()
  output.join("/")
}
