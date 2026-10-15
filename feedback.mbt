///|
/// A feedback edge shifts timestamps by a path summary. Connect exactly once before execution.
/// Individual summaries may move time backward; cycles must still admit convergent
/// reachability summaries. Summary functions must satisfy the domain laws.
pub struct Feedback[D, T, R, S] {
  priv scope : Scope[T, S]
  priv output : Channel[D, T, R]
  priv summary : S
  priv mut connected : Bool
}

///|
pub fn[D, T : Lattice, R, S] Scope::feedback(
  self : Scope[T, S],
  summary : S,
) -> (Feedback[D, T, R, S], Collection[D, T, R]) {
  let output = Channel(
    self.worker.scheduler,
    Antichain([self.minimum]),
    context=self.context,
  )
  (
    { scope: self, output, summary, connected: false, },
    { worker: self.worker, channel: output, },
  )
}

///|
/// Overflowing timestamp advancement drops the record, matching Timely's feedback operator.
pub fn[D, T : Lattice, R, S] Feedback::connect(
  self : Feedback[D, T, R, S],
  source : Collection[D, T, R],
) -> Unit {
  guard !self.connected else { abort("feedback is already connected") }
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.scope.context) else {
    abort("feedback collection belongs to a different scope")
  }
  let input : Mailbox[D, T, R] = Mailbox()
  let output = self.output
  let domain = self.scope.domain
  let summary = self.summary
  input.task = self.scope.worker.register(fn() {
    for frame in input.drain() {
      if frame is Records(envelope, updates) {
        guard domain.results_in(summary, envelope) is Some(envelope) else {
          continue
        }
        let result = []
        for (data, time, diff) in updates {
          if domain.results_in(summary, time) is Some(at) {
            result.push((data, at, diff))
          }
        }
        output.data_at(envelope, result)
      }
    }
  })
  source.channel.subscribe(input)
  let (_, port) = input.counter.unwrap()
  self.scope.progress.graph.connect(port, output.port, summary)
  self.connected = true
}
