///|
/// Exact distinct update counts in a sealed interval of the capture protocol.
pub struct CaptureProgress[T] {
  priv lower : Antichain[T]
  priv upper : Antichain[T]
  priv counts : Array[(T, Int64)]
}

///|
pub fn[T : Lattice] CaptureProgress::CaptureProgress(
  lower : Antichain[T],
  upper : Antichain[T],
  counts : Array[(T, Int64)],
) -> CaptureProgress[T] {
  guard lower.precedes(upper) else {
    abort("capture interval cannot move backward")
  }
  let times = []
  for (time, count) in counts {
    guard count > 0 &&
      lower.less_equal(time) &&
      !upper.less_equal(time) &&
      !times.contains(time) else {
      abort("invalid capture count")
    }
    times.push(time)
  }
  {
    lower: Antichain(lower.elements),
    upper: Antichain(upper.elements),
    counts: counts.copy(),
  }
}

///|
pub fn[T : Lattice] CaptureProgress::lower(
  self : CaptureProgress[T],
) -> Antichain[T] {
  Antichain(self.lower.elements)
}

///|
pub fn[T : Lattice] CaptureProgress::upper(
  self : CaptureProgress[T],
) -> Antichain[T] {
  Antichain(self.upper.elements)
}

///|
pub fn[T] CaptureProgress::counts(
  self : CaptureProgress[T],
) -> Array[(T, Int64)] {
  self.counts.copy()
}

///|
pub(all) enum CaptureMessage[D, T, R] {
  Updates(Array[(D, T, R)])
  Progress(CaptureProgress[T])
}

///|
/// Capture consolidated updates and their exact counts. The callback owns each
/// update array. Store both update and progress messages to permit replay.
pub fn[D : Compare, T : Lattice, R : Semigroup] Collection::capture(
  self : Collection[D, T, R],
  emit : (CaptureMessage[D, T, R]) -> Unit,
) -> Probe[T] {
  let state = Ref(Antichain(self.channel.frontier.val.elements))
  let pending : Ref[Array[(D, T, R)]] = Ref([])
  let input : Mailbox[D, T, R] = Mailbox()
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(_, updates) =>
          for update in updates {
            pending.val.push(update)
          }
        Progress(frontier) => {
          if state.val.elements == frontier.elements {
            continue
          }
          let ready = []
          let retained = []
          for update in pending.val {
            if frontier.less_equal(update.1) {
              retained.push(update)
            } else {
              ready.push(update)
            }
          }
          pending.val = retained
          let updates = consolidate_updates(ready)
          let counts : ChangeBatch[T] = ChangeBatch()
          for (_, time, _) in updates {
            counts.update(time, 1)
          }
          let progress = CaptureProgress(state.val, frontier, counts.drain())
          state.val = Antichain(frontier.elements)
          if !updates.is_empty() {
            emit(Updates(updates))
          }
          emit(Progress(progress))
        }
      }
    }
  })
  self.channel.subscribe(input)
  { state, }
}
