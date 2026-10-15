///|
// The fixture drives readiness eagerly. Embedding applications instead schedule
// the next Pending poll through their host event loop.
fn drive(
  cluster : @differential.ClusterWorker,
  max_rounds~ : Int32 = 100000,
) -> @differential.RunResult raise {
  let mut completed = 0
  let mut pending = 0
  while completed < max_rounds {
    match cluster.poll() {
      Pending => {
        pending += 1
        guard pending < 10000000 else {
          abort("asynchronous test transport stalled")
        }
      }
      Progress => completed += 1
      Quiescent => return Quiescent(completed + 1)
    }
  }
  StepLimit(completed)
}
