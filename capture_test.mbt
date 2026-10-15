///|
test "capture and replay survive reordered duplicated messages" {
  let producer = @differential.Worker()
  let (input, values) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = producer.input(0)
  let messages = []
  let captured = values.capture(fn(message) { messages.push(message) })
  for epoch in 0L..<8L {
    input.update(1, epoch + 1)
    input.update(2, -1)
    input.advance_to(epoch + 1)
    input.flush()
    let _ = producer.run()
  }
  input.close()
  let _ = producer.run()
  assert_true(captured.done())
  producer.dispose()
  for seed in 1U..<33U {
    let delivery = messages + messages
    let mut random = seed
    for index in 1..<delivery.length() {
      random = random * 1664525U + 1013904223U
      let other = (random % (index + 1).reinterpret_as_uint()).reinterpret_as_int()
      let temporary = delivery[index]
      delivery[index] = delivery[other]
      delivery[other] = temporary
    }
    let consumer = @differential.Worker()
    let scope = consumer.scope(0L, @differential.SummaryDomain::int64())
    let (replay, stream) : (
      @differential.ReplayInput[Int32, Int64, Int64],
      @differential.Collection[Int32, Int64, Int64],
    ) = scope.replay()
    let observed = []
    let probe = stream.inspect(fn(d, t, r) { observed.push((d, t, r)) })
    for message in delivery {
      replay.push(message)
      let _ = consumer.run()
    }
    assert_true(probe.done())
    let expected = []
    for epoch in 0L..<8L {
      expected.push((1, epoch, epoch + 1))
      expected.push((2, epoch, -1L))
    }
    assert_eq(
      @differential.consolidate_updates(observed),
      @differential.consolidate_updates(expected),
    )
    consumer.dispose()
  }
}

///|
test "replay waits for advertised records and deduplicates within one message" {
  let replay : @differential.Replayer[Int32, Int64, Int64] = Replayer(0)
  assert_true(
    replay.push(
      Progress(CaptureProgress(Antichain([0L]), Antichain([]), [(0L, 1L)])),
    )
    is None,
  )
  assert_eq(replay.frontier().to_array(), [0L])
  let result = replay.push(Updates([(1, 0L, 1L), (1, 0L, 1L)])).unwrap()
  assert_eq(result.0, [(1, 0L, 1L)])
  assert_true(result.1.is_empty())
  assert_true(replay.push(Updates([(1, 0L, 1L)])) is None)
}
