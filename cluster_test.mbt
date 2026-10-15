///|
test "serialized cluster preserves 64 bit times and drains exchange counts" {
  let cluster = @differential.ClusterWorker(0, 1, exchange=fn(value) { [value] })
  let scope = cluster.scope(
    9007199254740993L,
    @differential.SummaryDomain::int64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let exchanged = scope.exchange(
    values,
    fn(x) { x.to_uint64() },
    data_codec=@differential.WireCodec::json(),
    time_codec=@differential.WireCodec::json(),
    diff_codec=@differential.WireCodec::json(),
  )
  let seen = []
  let probe = exchanged.inspect(fn(d, t, r) { seen.push((d, t, r)) })
  input.update(7, 9007199254740995L)
  input.advance_to(9007199254740994L)
  input.flush()
  assert_true(cluster.run() is Quiescent(_))
  assert_eq(seen, [(7, 9007199254740993L, 9007199254740995L)])
  assert_eq(probe.frontier().to_array(), [9007199254740994L])
  input.close()
  assert_true(cluster.run() is Quiescent(_))
  assert_true(probe.done())
  cluster.dispose()
}

///|
test "cluster rejects replayed rounds and becomes terminal on transport failure" {
  let first = Ref(None)
  let cluster = @differential.ClusterWorker(0, 1, exchange=fn(value) {
    match first.val {
      None => {
        first.val = Some(value)
        [value]
      }
      Some(value) => [value]
    }
  })
  let rejected = try {
    let _ = cluster.run()
    false
  } catch {
    _ => true
  }
  assert_true(rejected)
  let closed = try {
    let _ = cluster.run()
    false
  } catch {
    _ => true
  }
  assert_true(closed)
  cluster.dispose()
}
