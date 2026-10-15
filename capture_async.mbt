///|
/// Nonblocking capture writer. poll returns a retry delay, or None when the
/// message is accepted. done reports that all accepted writes are committed.
pub struct CaptureWriter[D, T, R] {
  priv poll : (CaptureMessage[D, T, R]) -> Duration?
  priv done : () -> Bool
}

///|
pub fn[D, T, R] CaptureWriter::CaptureWriter(
  poll~ : (CaptureMessage[D, T, R]) -> Duration?,
  done~ : () -> Bool,
) -> CaptureWriter[D, T, R] {
  { poll, done, }
}

///|
/// Wake or cancel an externally driven capture/replay operator. Cancellation
/// discards uncommitted work; is_complete means normal protocol completion.
pub struct CaptureHandle {
  priv activator : Activator
  priv complete : Ref[Bool]
  priv cancelled : Ref[Bool]
}

///|
pub fn CaptureHandle::activate(self : CaptureHandle) -> Unit {
  self.activator.activate()
}

///|
pub fn CaptureHandle::cancel(self : CaptureHandle) -> Unit {
  if !self.complete.val {
    self.cancelled.val = true
    self.activator.activate()
  }
}

///|
pub fn CaptureHandle::is_complete(self : CaptureHandle) -> Bool {
  self.complete.val
}

///|
pub fn CaptureHandle::is_cancelled(self : CaptureHandle) -> Bool {
  self.cancelled.val
}

///|
/// Capture sealed, consolidated intervals through a retryable writer. Input
/// continues to drain while writes are pending, as in upstream. A nonzero retry
/// delay requires the worker's monotonic host clock. Wake the handle when done()
/// changes asynchronously after all queued messages have been accepted.
pub fn[D : Compare, T : Lattice, R : Semigroup, S] Scope::capture_to(
  self : Scope[T, S],
  source : Collection[D, T, R],
  writer : CaptureWriter[D, T, R],
) -> CaptureHandle {
  let builder = self.operator()
  let input = builder.new_input(source)
  let activator = builder.activator()
  let complete = Ref(false)
  let cancelled = Ref(false)
  let handle = { activator, complete, cancelled, }
  let writer_ref = Ref(Some(writer))
  let pending : Ref[Array[(D, T, R)]] = Ref([])
  let queue : Array[CaptureMessage[D, T, R]] = []
  let frontier = Ref(Antichain([self.minimum]))
  builder.build_reschedule(
    fn(_) {
      fn() {
        input.for_each(fn(cap, records) {
          if !cancelled.val {
            for (data, diff) in records {
              pending.val.push((data, cap.time(), diff))
            }
          }
        })
        if cancelled.val {
          writer_ref.val = None
          pending.val.clear()
          queue.clear()
          return false
        }
        let next = input.frontier()
        if next.elements != frontier.val.elements {
          let ready = []
          let retained = []
          for update in pending.val {
            if next.less_equal(update.1) {
              retained.push(update)
            } else {
              ready.push(update)
            }
          }
          pending.val = retained
          let updates = consolidate_updates(ready)
          let counts : ChangeBatch[T] = ChangeBatch()
          for (_, time, _) in updates {
            counts.update(time, 1L)
          }
          if !updates.is_empty() {
            queue.push(Updates(updates))
          }
          queue.push(
            Progress(CaptureProgress(frontier.val, next, counts.drain())),
          )
          frontier.val = next
        }
        let writer = writer_ref.val.unwrap()
        let mut accepted = 0
        let mut retry : Duration? = None
        while accepted < queue.length() {
          if (writer.poll)(
              match queue[accepted] {
                Updates(updates) => Updates(updates.copy())
                Progress(progress) => Progress(progress)
              },
            )
            is Some(delay) {
            retry = Some(delay)
            break
          }
          accepted += 1
        }
        if accepted > 0 {
          let retained = queue[accepted:].to_owned()
          queue.clear()
          for message in retained {
            queue.push(message)
          }
        }
        if retry is Some(delay) {
          activator.activate_after(delay)
          return true
        }
        let unfinished = !(writer.done)() || !queue.is_empty()
        complete.val = frontier.val.is_empty() && !unfinished
        unfinished
      }
    },
    on_shutdown=fn() {
      pending.val.clear()
      queue.clear()
      writer_ref.val = None
      if !complete.val {
        cancelled.val = true
      }
    },
  )
  handle
}

///|
/// Poll an external message source in bounded turns. None means temporarily
/// empty, not EOF: normal completion requires the terminal capture progress
/// statement. The source builder receives an activator for future arrivals.
pub fn[D : Compare, T : Lattice, R : Compare, S] Scope::replay_from(
  self : Scope[T, S],
  build_source : (Activator) -> () -> CaptureMessage[D, T, R]?,
  messages_per_turn~ : Int32 = 1024,
) -> (CaptureHandle, Collection[D, T, R]) {
  guard messages_per_turn > 0 else {
    abort("replay turn budget must be positive")
  }
  let (replay, collection) : (ReplayInput[D, T, R], Collection[D, T, R]) = self.replay()
  let builder = self.operator()
  let activator = builder.activator()
  let complete = Ref(false)
  let cancelled = Ref(false)
  let handle = { activator, complete, cancelled, }
  let poll = build_source(activator)
  builder.build_reschedule(
    fn(_) {
      fn() {
        if cancelled.val {
          replay.cancel()
          return false
        }
        for _ in 0..<messages_per_turn {
          guard poll() is Some(message) else { return true }
          replay.push(message)
          if replay.replayer.frontier().is_empty() {
            complete.val = true
            return false
          }
        }
        activator.activate()
        true
      }
    },
    on_shutdown=fn() {
      replay.cancel()
      if !complete.val {
        cancelled.val = true
      }
    },
  )
  (handle, collection)
}
