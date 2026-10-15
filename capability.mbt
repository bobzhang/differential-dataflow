///|
/// A counted right to produce at a port. Explicit release replaces Rust Drop.
pub struct Capability[T, S] {
  priv owner : CapabilityOwner[T, S]
  priv port : Int32
  priv mut time : T
  priv mut live : Bool
}

///|
pub fn[T : Lattice, S] ProgressTracker::capability(
  self : ProgressTracker[T, S],
  port : Int32,
  time : T,
) -> Capability[T, S] {
  self.update(port, time, 1)
  { owner: Tracker(self), port, time, live: true, }
}

///|
fn[T, S] Capability::check(self : Capability[T, S]) -> Unit {
  guard self.live else { abort("capability was released or transferred") }
}

///|
pub fn[T, S] Capability::time(self : Capability[T, S]) -> T {
  self.check()
  self.time
}

///|
pub fn[T, S] Capability::is_live(self : Capability[T, S]) -> Bool {
  self.live
}

///|
pub fn[T : Lattice, S] Capability::clone(
  self : Capability[T, S],
) -> Capability[T, S] {
  self.check()
  self.owner.capability(self.port, self.time)
}

///|
pub fn[T : Lattice, S] Capability::release(self : Capability[T, S]) -> Unit {
  if self.live {
    self.owner.update(self.port, self.time, -1)
    self.live = false
  }
}

///|
pub fn[T : Lattice, S] Capability::try_delayed(
  self : Capability[T, S],
  time : T,
) -> Capability[T, S]? {
  self.check()
  if self.time.less_equal(time) {
    Some(self.owner.capability(self.port, time))
  } else {
    None
  }
}

///|
pub fn[T : Lattice, S] Capability::delayed(
  self : Capability[T, S],
  time : T,
) -> Capability[T, S] {
  guard self.try_delayed(time) is Some(capability) else {
    abort("capability cannot move backward or sideways")
  }
  capability
}

///|
pub fn[T : Lattice, S] Capability::try_downgrade(
  self : Capability[T, S],
  time : T,
) -> Bool {
  self.check()
  if !self.time.less_equal(time) {
    return false
  }
  self.owner.update(self.port, time, 1)
  self.owner.update(self.port, self.time, -1)
  self.time = time
  true
}

///|
pub fn[T : Lattice, S] Capability::downgrade(
  self : Capability[T, S],
  time : T,
) -> Unit {
  guard self.try_downgrade(time) else {
    abort("capability cannot move backward or sideways")
  }
}

///|
pub fn[T, S] Capability::valid_for(
  self : Capability[T, S],
  tracker : ProgressTracker[T, S],
  port : Int32,
) -> Bool {
  let same = match self.owner {
    Tracker(owner) => physical_equal(owner, tracker)
    Scoped(_) => false
  }
  self.live && self.port == port && same
}

///|
/// Minimal capabilities for one output port. Insertion transfers the input handle.
pub struct CapabilitySet[T, S] {
  priv capabilities : Array[Capability[T, S]]
  priv owner : CapabilityOwner[T, S]
  priv port : Int32
}

///|
pub fn[T : Lattice, S] CapabilitySet::CapabilitySet(
  capability : Capability[T, S],
) -> CapabilitySet[T, S] {
  capability.check()
  let result = {
    capabilities: [],
    owner: capability.owner,
    port: capability.port,
  }
  result.insert(capability)
  result
}

///|
pub fn[T : Lattice, S] CapabilitySet::insert(
  self : CapabilitySet[T, S],
  capability : Capability[T, S],
) -> Unit {
  capability.check()
  guard capability.live &&
    capability.port == self.port &&
    capability.owner.same(self.owner) else {
    abort("capability set requires one output port")
  }
  if self.capabilities
    .iter()
    .any(fn(old) { old.time.less_equal(capability.time) }) {
    capability.release()
    return
  }
  let retained = []
  for old in self.capabilities {
    if capability.time.less_equal(old.time) {
      old.release()
    } else {
      retained.push(old)
    }
  }
  retained.push(capability.clone())
  capability.release()
  self.capabilities.clear()
  for cap in retained {
    self.capabilities.push(cap)
  }
}

///|
pub fn[T : Lattice, S] CapabilitySet::times(
  self : CapabilitySet[T, S],
) -> Array[T] {
  let times = self.capabilities.map(fn(cap) { cap.time })
  times.sort()
  times
}

///|
pub fn[T : Lattice, S] CapabilitySet::try_delayed(
  self : CapabilitySet[T, S],
  time : T,
) -> Capability[T, S]? {
  for cap in self.capabilities {
    if cap.time.less_equal(time) {
      return Some(cap.delayed(time))
    }
  }
  None
}

///|
/// All requested times must be reachable. Validation happens before any release.
pub fn[T : Lattice, S] CapabilitySet::try_downgrade(
  self : CapabilitySet[T, S],
  times : Array[T],
) -> Bool {
  let frontier = Antichain(times)
  for time in frontier.elements {
    if !self.capabilities.iter().any(fn(cap) { cap.time.less_equal(time) }) {
      return false
    }
  }
  let next = frontier.elements.map(fn(time) { self.try_delayed(time).unwrap() })
  self.release()
  for cap in next {
    self.capabilities.push(cap)
  }
  true
}

///|
pub fn[T : Lattice, S] CapabilitySet::release(
  self : CapabilitySet[T, S],
) -> Unit {
  for cap in self.capabilities {
    cap.release()
  }
  self.capabilities.clear()
}

///|
priv enum CapabilityOwner[T, S] {
  Tracker(ProgressTracker[T, S])
  Scoped(ScopeProgress[T, S])
}

///|
fn[T, S] CapabilityOwner::same(
  self : CapabilityOwner[T, S],
  other : CapabilityOwner[T, S],
) -> Bool {
  match (self, other) {
    (Tracker(a), Tracker(b)) => physical_equal(a, b)
    (Scoped(a), Scoped(b)) => physical_equal(a, b)
    _ => false
  }
}

///|
fn[T : Lattice, S] CapabilityOwner::update(
  self : CapabilityOwner[T, S],
  port : Int32,
  time : T,
  diff : Int64,
) -> Unit {
  match self {
    Tracker(tracker) => tracker.update(port, time, diff)
    Scoped(progress) => progress.pending.update((port, time), diff)
  }
}

///|
fn[T : Lattice, S] CapabilityOwner::capability(
  self : CapabilityOwner[T, S],
  port : Int32,
  time : T,
) -> Capability[T, S] {
  self.update(port, time, 1)
  { owner: self, port, time, live: true, }
}
