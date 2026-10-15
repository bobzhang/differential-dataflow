///|
test "delay schedules by message capability rather than future record time" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let seen = []
  let probe = source
    .delay(fn(t) { t + 3L })
    .inspect_batch(fn(envelope, rows) {
      for row in rows {
        seen.push((envelope, row))
      }
    })
    .probe()
  input.update_at(7, 10L, 2L)
  input.advance_to(3L)
  input.flush()
  let _ = worker.run()
  assert_eq(seen, [])
  assert_eq(probe.frontier().to_array(), [3L])
  input.advance_to(4L)
  input.flush()
  let _ = worker.run()
  assert_eq(seen, [(3L, (7, 13L, 2L))])
  assert_eq(probe.frontier().to_array(), [4L])
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "batch inspection owns copies and results_in retains message capabilities" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (output, capability, source) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Capability[Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.source()
  let seen = []
  let closed = Ref(false)
  let probe = source
    .results_in(-2L, @differential.SummaryDomain::int64())
    .consolidate_stream()
    .inspect_container(fn(event) {
      match event {
        Records(envelope, rows) => {
          for row in rows {
            seen.push((envelope, row))
          }
          rows.clear()
        }
        Frontier(frontier) => if frontier.is_empty() { closed.val = true }
      }
    })
    .probe()
  output.send_at(capability, [(7, 10L, 2L), (7, 10L, -1L), (8, 12L, 0L)])
  capability.release()
  let _ = worker.run()
  assert_eq(seen, [(0L, (7, 8L, 1L))])
  assert_true(probe.done() && closed.val)
  worker.dispose()
}

///|
test "overflowed results_in timestamps are discarded without retaining progress" {
  let worker = @differential.Worker()
  let (input, source) : (
    @differential.InputSession[Int32, UInt64, Int64],
    @differential.Collection[Int32, UInt64, Int64],
  ) = worker.input(0UL)
  let seen = []
  let probe = source
    .results_in(1UL, @differential.SummaryDomain::uint64())
    .inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update_at(1, 18446744073709551615UL, 1L)
  input.update_at(2, 10UL, 1L)
  input.close()
  let _ = worker.run()
  assert_eq(seen, [(2, 11UL, 1L)])
  assert_true(probe.done())
  worker.dispose()
}
