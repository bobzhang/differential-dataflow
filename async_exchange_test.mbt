///|
test "asynchronous cluster polling yields without completing input progress" {
  let request : Ref[String?] = Ref(None)
  let waits = Ref(0)
  let submissions = Ref(0)
  let adapter = @differential.AsyncExchange(
    start=fn(message) {
      guard request.val is None else {
        abort("overlapping collective requests")
      }
      request.val = Some(message)
      waits.val = 2
      submissions.val += 1
    },
    poll=fn() {
      if waits.val > 0 {
        waits.val -= 1
        return None
      }
      let message = request.val.unwrap()
      request.val = None
      Some([message])
    },
  )
  let cluster = @differential.ClusterWorker(0, 1, async_exchange=adapter)
  let scope = cluster.scope(
    0L,
    @differential.SummaryDomain::int64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let (input, data) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let seen = []
  let probe = data.inspect(fn(d, _, _) { seen.push(d) })
  input.insert(7)
  input.advance_to(1L)
  input.flush()
  assert_eq(cluster.run(), StepLimit(0))
  assert_eq(submissions.val, 1)
  assert_eq(cluster.poll(), Pending)
  assert_eq(cluster.poll(), Pending)
  assert_true(probe.less_than(1L))
  assert_eq(seen, [])
  for attempts = 0; ; attempts = attempts + 1 {
    guard attempts < 100 else { abort("asynchronous cluster stalled") }
    if cluster.poll() is Quiescent {
      break
    }
  }
  assert_false(probe.less_than(1L))
  assert_eq(seen, [7])
  input.close()
  for attempts = 0; ; attempts = attempts + 1 {
    guard attempts < 100 else { abort("asynchronous cluster did not close") }
    if cluster.run() is Quiescent(_) {
      break
    }
  }
  assert_true(probe.done())
  assert_true(request.val is None)
  cluster.dispose()
}
