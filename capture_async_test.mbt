///|
test "capture retries updates and final progress then waits for durable completion" {
  let now = Ref(@differential.Duration(0UL))
  let worker = @differential.Worker(clock=fn() { now.val })
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let accepted : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  let committed = Ref(false)
  let mut update_calls = 0
  let mut progress_calls = 0
  let writer = @differential.CaptureWriter(
    poll=fn(message) {
      match message {
        Updates(updates) => {
          update_calls += 1
          if update_calls == 1 {
            // Mutating a borrowed poll argument must not corrupt the queued retry.
            updates.clear()
            return Some(Duration(1UL))
          }
        }
        Progress(_) => {
          progress_calls += 1
          if progress_calls == 1 {
            return Some(Duration(2UL))
          }
        }
      }
      accepted.push(message)
      None
    },
    done=fn() { committed.val },
  )
  let capture = scope.capture_to(source, writer)
  input.insert(7)
  input.insert(7)
  input.close()
  let _ = worker.run()
  assert_true(accepted.is_empty())
  assert_false(capture.is_complete())
  assert_eq(worker.next_activation(), Some(Duration(1UL)))
  now.val = Duration(1UL)
  let _ = worker.run()
  assert_eq(accepted.length(), 1)
  assert_eq(worker.next_activation(), Some(Duration(2UL)))
  now.val = Duration(3UL)
  let _ = worker.run()
  assert_eq(accepted.length(), 2)
  assert_false(capture.is_complete())
  assert_true(worker.next_activation() is None)
  committed.val = true
  capture.activate()
  let _ = worker.run()
  assert_true(capture.is_complete())
  assert_false(capture.is_cancelled())
  let replay : @differential.Replayer[Int32, Int64, Int64] = Replayer(0L)
  let seen = []
  for message in accepted {
    if replay.push(message) is Some((updates, _)) {
      for update in updates {
        seen.push(update)
      }
    }
  }
  assert_eq(seen, [(7, 0L, 2L)])
  assert_true(replay.frontier().is_empty())
  worker.dispose()
  assert_false(capture.is_cancelled())
}

///|
test "capture cancellation discards pending retries" {
  let worker = @differential.Worker(clock=fn() { Duration(0UL) })
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let mut polls = 0
  let handle = scope.capture_to(
    source,
    CaptureWriter(
      poll=fn(_) {
        polls += 1
        Some(Duration(10UL))
      },
      done=fn() { false },
    ),
  )
  input.insert(1)
  input.close()
  let _ = worker.run()
  assert_eq(polls, 1)
  handle.cancel()
  let _ = worker.run()
  assert_eq(polls, 1)
  assert_true(handle.is_cancelled())
  assert_false(handle.is_complete())
  assert_true(worker.next_activation() is None)
  worker.dispose()
}

///|
test "external replay waits for arrivals and completes only on terminal protocol progress" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let inbox : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  let wake : Ref[@differential.Activator?] = Ref(None)
  let (handle, stream) = scope.replay_from(
    fn(activator) {
      wake.val = Some(activator)
      fn() { inbox.pop() }
    },
    messages_per_turn=1,
  )
  let seen = []
  let probe = stream.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let _ = worker.run()
  assert_false(handle.is_complete())
  assert_true(probe.less_than(1L))
  inbox.push(
    Progress(CaptureProgress(Antichain([0L]), Antichain([1L]), [(0L, 1L)])),
  )
  wake.val.unwrap().activate()
  let _ = worker.run()
  assert_true(seen.is_empty())
  assert_true(probe.less_than(1L))
  inbox.push(Updates([(9, 0L, 3L), (9, 0L, 3L)]))
  handle.activate()
  let _ = worker.run()
  assert_eq(seen, [(9, 0L, 3L)])
  assert_false(probe.less_than(1L))
  inbox.push(Progress(CaptureProgress(Antichain([1L]), Antichain([]), [])))
  handle.activate()
  let _ = worker.run()
  assert_true(handle.is_complete())
  assert_true(probe.done())
  worker.dispose()
}

///|
test "external replay cancellation releases an idle source capability" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (handle, stream) : (
    @differential.CaptureHandle,
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.replay_from(fn(_) { fn() { None } })
  let probe = stream.probe()
  let _ = worker.run()
  handle.cancel()
  let _ = worker.run()
  assert_true(probe.done())
  assert_true(handle.is_cancelled())
  assert_false(handle.is_complete())
  worker.dispose()
}

///|
test "activated replay emits unique records before progress is sealed" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let inbox : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = [
    Updates([(7, 0L, 3L), (7, 0L, 3L)]),
  ]
  let (handle, stream) = scope.replay_from(fn(_) { fn() { inbox.pop() } })
  let seen = []
  let probe = stream.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let _ = worker.run()
  assert_eq(seen, [(7, 0L, 3L)])
  assert_true(probe.less_than(1L))
  inbox.push(
    Progress(CaptureProgress(Antichain([0L]), Antichain([]), [(0L, 1L)])),
  )
  handle.activate()
  let _ = worker.run()
  assert_true(handle.is_complete())
  assert_true(probe.done())
  worker.dispose()
}

///|
test "panic source replay rejects conflicting weights for one data and time" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let inbox : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = [
    Updates([(7, 0L, 1L), (7, 0L, 2L)]),
  ]
  let _ = scope.replay_from(fn(_) { fn() { inbox.pop() } })
  let _ = worker.run()
}
