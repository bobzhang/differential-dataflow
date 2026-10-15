///|
priv enum ReplayPacket[D, T, R] {
  Records(Array[(D, T, R)])
  Statement(CaptureProgress[T])
  Counts(Array[(T, Int64)])
  Frontier(Int32, Antichain[T])
}

///|
priv struct ReplayAccounting[T] {
  mut progress : Antichain[T]
  mut reported : Antichain[T]
  counts : MutableAntichain[T]
  mut statements : Array[CaptureProgress[T]]
}

///|
fn[T : Lattice] ReplayAccounting::ReplayAccounting(
  minimum : T,
) -> ReplayAccounting[T] {
  {
    progress: Antichain([minimum]),
    reported: Antichain([minimum]),
    counts: MutableAntichain(),
    statements: [],
  }
}

///|
fn[T : Lattice] ReplayAccounting::advance(
  self : ReplayAccounting[T],
) -> Antichain[T]? {
  for ;; {
    let mut found = -1
    for index, statement in self.statements {
      if statement.lower.precedes(self.progress) {
        found = index
        break
      }
    }
    if found < 0 {
      break
    }
    let statement = self.statements[found]
    let _ = self.counts.update_all(
      statement.counts.filter(fn(c) { self.progress.less_equal(c.0) }),
    )
    self.progress = self.progress.join(statement.upper)
    self.statements = self.statements.filter(fn(s) {
      !s.upper.precedes(self.progress)
    })
  }
  let frontier = Antichain(
    self.progress.elements + self.counts.frontier().elements,
  )
  if frontier.elements == self.reported.elements {
    return None
  }
  guard self.reported.precedes(frontier) else {
    abort("capture count frontier moved backward")
  }
  self.reported = frontier
  Some(frontier)
}

///|
// The same stages as upstream capture::source: route records, deduplicate them,
// route timestamp counts, then broadcast compact progress frontiers. Record
// payloads are emitted immediately, and retained only until the global frontier.
fn[D : Compare, T : Lattice, R : Compare, S] Scope::partitioned_replay(
  self : Scope[T, S],
  inbox : ReplayQueue[D, T, R],
  build_source : (Activator) -> () -> CaptureMessage[D, T, R]?,
  send : (Int32, ReplayPacket[D, T, R]) -> Unit,
  hash : (D) -> UInt64,
  time_hash : (T) -> UInt64,
  peer : Int32,
  peers : Int32,
  budget : Int32,
) -> (CaptureHandle, Collection[D, T, R]) {
  guard budget > 0 else { abort("replay turn budget must be positive") }
  let output : Channel[D, T, R] = Channel(
    self.worker.scheduler,
    Antichain([self.minimum]),
    context=self.context,
  )
  output.hold(self.minimum, 1)
  let reported = Ref(Antichain([self.minimum]))
  let frontiers = Array::makei(peers, fn(_) { Antichain([self.minimum]) })
  let pending : Ref[Array[(D, T, R)]] = Ref([])
  let accounting : ReplayAccounting[T] = ReplayAccounting(self.minimum)
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
          return false
        }
        let emitted = []
        let deltas = ChangeBatch()
        // Bound packet processing, including bookkeeping, on each activation.
        for _ in 0..<budget {
          guard inbox.pop() is Some(packet) else { break }
          match packet {
            Records(records) =>
              for (data, time, diff) in records {
                if !reported.val.less_equal(time) {
                  continue
                }
                let mut duplicate = false
                for (prior, at, weight) in pending.val {
                  if data == prior && time == at {
                    guard diff == weight else {
                      abort(
                        "capture source received conflicting differences for one data/time",
                      )
                    }
                    duplicate = true
                    break
                  }
                }
                if !duplicate {
                  pending.val.push((data, time, diff))
                  emitted.push((data, time, diff))
                  deltas.update(time, -1L)
                }
              }
            Statement(statement) => accounting.statements.push(statement)
            Counts(counts) => {
              let _ = accounting.counts.update_all(counts)
            }
            Frontier(source, frontier) =>
              frontiers[source] = frontiers[source].join(frontier)
          }
        }
        output.data(emitted)
        let counts = Array::makei(peers, fn(_) { [] })
        for (time, diff) in deltas.drain() {
          counts[(time_hash(time) % peers.to_uint64()).to_int()].push(
            (time, diff),
          )
        }
        for destination, counts in counts {
          if !counts.is_empty() {
            send(destination, Counts(counts))
          }
        }
        if accounting.advance() is Some(frontier) {
          for destination in 0..<peers {
            send(destination, Frontier(peer, frontier))
          }
        }
        let global = Antichain([])
        for frontier in frontiers {
          for time in frontier.elements {
            let _ = global.insert(time)
          }
        }
        if global.elements != reported.val.elements {
          guard reported.val.precedes(global) else {
            abort("capture source frontier moved backward")
          }
          for time in global.elements {
            output.hold(time, 1L)
          }
          for time in reported.val.elements {
            output.hold(time, -1L)
          }
          reported.val = global
          pending.val = pending.val.filter(fn(u) { global.less_equal(u.1) })
        }
        if global.is_empty() {
          complete.val = true
          return false
        }
        for _ in 0..<budget {
          guard poll() is Some(message) else {
            if !inbox.is_empty() {
              activator.activate()
            }
            return true
          }
          match message {
            Updates(rows) => {
              let buckets = Array::makei(peers, fn(_) { [] })
              for row in rows {
                buckets[(hash(row.0) % peers.to_uint64()).to_int()].push(row)
              }
              for destination, rows in buckets {
                if !rows.is_empty() {
                  send(destination, Records(rows))
                }
              }
            }
            Progress(progress) => {
              let counts = Array::makei(peers, fn(_) { [] })
              for count in progress.counts {
                counts[(time_hash(count.0) % peers.to_uint64()).to_int()].push(
                  count,
                )
              }
              for destination in 0..<peers {
                send(
                  destination,
                  Statement(
                    CaptureProgress(
                      progress.lower,
                      progress.upper,
                      counts[destination],
                    ),
                  ),
                )
              }
            }
          }
        }
        activator.activate()
        true
      }
    },
    on_shutdown=fn() {
      for time in reported.val.elements {
        output.hold(time, -1L)
      }
      reported.val = Antichain([])
      pending.val.clear()
      accounting.counts.clear()
      accounting.statements.clear()
      inbox.clear()
      frontiers.clear()
      if !complete.val {
        cancelled.val = true
      }
    },
  )
  (handle, { worker: self.worker, channel: output, })
}
