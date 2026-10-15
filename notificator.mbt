///|
/// Timestamp notifications retain output capabilities until all input frontiers pass.
/// Handles returned by drain_ready belong to the caller and must be released.
pub struct Notificator[T, S] {
  priv pending : Array[(Capability[T, S], Int64)]
}

///|
pub fn[T, S] Notificator::Notificator() -> Notificator[T, S] {
  { pending: [], }
}

///|
/// Transfer this capability into the notification queue. Equal timestamps at the
/// same output port coalesce, with their request count returned by drain_ready.
pub fn[T : Lattice, S] Notificator::request(
  self : Notificator[T, S],
  capability : Capability[T, S],
) -> Unit {
  capability.check()
  for i in 0..<self.pending.length() {
    let (old, count) = self.pending[i]
    if old.time == capability.time &&
      old.port == capability.port &&
      old.owner.same(capability.owner) {
      self.pending[i] = (old, count + 1)
      capability.release()
      return
    }
  }
  self.pending.push((capability.clone(), 1))
  capability.release()
}

///|
pub fn[T : Lattice, S] Notificator::drain_ready(
  self : Notificator[T, S],
  frontiers : Array[Antichain[T]],
) -> Array[(Capability[T, S], Int64)] {
  let ready = []
  let retained = []
  for request in self.pending {
    if frontiers
      .iter()
      .any(fn(frontier) { frontier.less_equal(request.0.time) }) {
      retained.push(request)
    } else {
      ready.push(request)
    }
  }
  self.pending.clear()
  for request in retained {
    self.pending.push(request)
  }
  ready.sort_by(fn(a, b) { Compare::compare(a.0.time, b.0.time) })
  ready
}

///|
pub fn[T : Lattice, S] Notificator::release(self : Notificator[T, S]) -> Unit {
  for (capability, _) in self.pending {
    capability.release()
  }
  self.pending.clear()
}
