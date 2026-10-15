///|
priv struct DataflowState {
  id : Int32
  coordinated : Bool
  mut cancelled : Bool
  tasks : Set[Int32]
  scopes : Map[Int32, () -> Unit]
}

///|
/// The next root scope's identity. Nested scopes share their root's identity.
pub fn Worker::next_dataflow_index(self : Worker) -> Int32 {
  self.next_dataflow
}

///|
/// Currently installed root scopes, in creation order.
pub fn Worker::installed_dataflows(self : Worker) -> Array[Int32] {
  self.dataflows.keys().collect()
}

///|
pub fn Worker::has_dataflows(self : Worker) -> Bool {
  !self.dataflows.is_empty()
}

///|
pub fn[T, S] Scope::dataflow_index(self : Scope[T, S]) -> Int32 {
  self.progress.family.id
}

///|
/// Cancel a local root dataflow and every nested scope. Pending records are
/// discarded; other dataflows and independently owned trace readers survive.
/// Cancelled probes retain their last observed frontier, as in Timely.
/// Unknown or already completed identities are harmless. Coordinated dataflows
/// must be cancelled through their group or cluster, never one peer alone.
pub fn Worker::drop_dataflow(self : Worker, id : Int32) -> Unit {
  guard self.scheduler.active && !self.scheduler.stepping && !self.gate.val else {
    abort("drop dataflows only on an idle active worker")
  }
  if self.dataflows.get(id) is Some(family) {
    guard !family.coordinated else {
      abort("coordinated dataflow requires group or cluster cancellation")
    }
    self.cancel_dataflow(family)
  }
}

///|
fn Worker::cancel_dataflow(self : Worker, family : DataflowState) -> Unit {
  self.scheduler.stepping = true
  self.gate.val = true
  family.cancelled = true
  // Finalizers close trace writers and unregister imports while their scopes
  // still exist. Surviving imports in other dataflows receive terminal progress.
  self.retire_completed(cancel=family.tasks)
  let scopes = family.scopes.to_array()
  for (_, cancel) in scopes {
    cancel()
  }
  family.scopes.clear()
  family.tasks.clear()
  self.dataflows.remove(family.id)
  self.network.reclaim_completed()
  self.scheduler.stepping = false
  self.gate.val = false
}

///|
/// Cancel corresponding root dataflows on every cooperative worker. IDs for
/// group-built root scopes match across peers; nested scopes share that ID.
pub fn WorkerGroup::drop_dataflow(self : WorkerGroup, id : Int32) -> Unit {
  for worker in self.workers {
    guard worker.scheduler.active &&
      !worker.scheduler.stepping &&
      !worker.gate.val else {
      abort("drop group dataflows only while all workers are idle")
    }
  }
  for worker in self.workers {
    if worker.dataflows.get(id) is Some(family) {
      worker.cancel_dataflow(family)
    }
  }
}

///|
pub fn[T, S] ScopeGroup::dataflow_index(self : ScopeGroup[T, S]) -> Int32 {
  self.scopes[0].dataflow_index()
}

///|
pub fn ClusterWorker::next_dataflow_index(self : ClusterWorker) -> Int32 {
  self.worker.next_dataflow_index()
}

///|
pub fn ClusterWorker::installed_dataflows(self : ClusterWorker) -> Array[Int32] {
  self.worker.installed_dataflows()
}

///|
pub fn[T, S] DistributedScope::dataflow_index(
  self : DistributedScope[T, S],
) -> Int32 {
  self.scope.dataflow_index()
}

///|
/// Request collective cancellation. Any peer may request it; the next run round
/// cancels that root and all nested scopes on every peer before delivering that
/// round's records. All peers must continue entering run until it is quiescent.
/// Local inputs remain usable until the collective decision is applied.
pub fn ClusterWorker::drop_dataflow(self : ClusterWorker, id : Int32) -> Unit {
  guard !self.state.closed &&
    !self.state.running &&
    self.worker.scheduler.active &&
    !self.worker.scheduler.stepping &&
    !self.worker.gate.val else {
    abort("request cancellation only on an idle active cluster")
  }
  if self.worker.dataflows.contains(id) {
    self.state.cancellations.add(id)
  }
}
