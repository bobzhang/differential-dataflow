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
