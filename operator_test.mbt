///|
test "scoped output capabilities hold progress and enforce port identity" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (output, cap, values) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Capability[Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.source()
  let (other, other_cap, _) : (
    @differential.Output[Int32, Int64, Int64, Int64],
    @differential.Capability[Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.source()
  assert_true(!other.accepts(cap))
  assert_true(!output.accepts(other_cap))
  other_cap.release()
  let seen = []
  let probe = values.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  let later = cap.delayed(5)
  output.send(cap, [(7, 1L)])
  cap.release()
  let _ = worker.run()
  assert_eq(probe.frontier().to_array(), [5L])
  assert_true(!output.accepts(cap))
  output.send(later, [(8, 2L)])
  later.release()
  let _ = worker.run()
  assert_eq(seen, [(7, 0L, 1L), (8, 5L, 2L)])
  assert_true(probe.done())
  worker.dispose()
}

///|
test "custom unary uses notifications to finalize weighted timestamp totals" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let result : @differential.Collection[Int64, Int64, Int64] = scope.unary(
    values,
    fn(output, initial) {
      initial.release()
      let notifications = @differential.Notificator()
      let totals : Map[Int64, Int64] = Map([])
      fn(event) {
        match event {
          Data(cap, records) => {
            let time = cap.time()
            let mut sum = totals.get(time).unwrap_or(0)
            for (value, diff) in records {
              sum += value.to_int64() * diff
            }
            totals[time] = sum
            notifications.request(cap.clone())
          }
          Progress(frontier) =>
            for (cap, _) in notifications.drain_ready([frontier]) {
              output.send(cap, [(totals.get(cap.time()).unwrap(), 1L)])
              totals.remove(cap.time())
              cap.release()
            }
        }
      }
    },
  )
  let seen = []
  let probe = result.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update(3, 2)
  input.flush()
  let _ = worker.run()
  assert_true(seen.is_empty())
  input.update(5, -1)
  input.advance_to(1)
  input.flush()
  let _ = worker.run()
  assert_eq(seen, [(1L, 0L, 1L)])
  assert_eq(probe.frontier().to_array(), [1L])
  input.close()
  let _ = worker.run()
  assert_true(probe.done())
  worker.dispose()
}

///|
test "notifications require all incomparable input frontiers to pass" {
  let graph = @differential.ProgressGraph(
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let port = graph.add_port()
  let tracker = @differential.ProgressTracker(graph.compile().unwrap())
  let notifications = @differential.Notificator()
  let cap = tracker.capability(port, Product(1L, 1L))
  notifications.request(cap.clone())
  notifications.request(cap)
  assert_true(!cap.is_live())
  assert_true(
    notifications
    .drain_ready([Antichain([Product(2L, 0L)]), Antichain([Product(0L, 1L)])])
    .is_empty(),
  )
  let ready = notifications.drain_ready([
    Antichain([Product(2L, 0L)]),
    Antichain([Product(0L, 2L)]),
  ])
  assert_eq(ready.length(), 1)
  assert_eq(ready[0].1, 2L)
  assert_eq(ready[0].0.time(), Product(1L, 1L))
  ready[0].0.release()
  let _ = tracker.propagate()
  assert_true(tracker.frontier(port).is_empty())
}
