///|
test "capture codec preserves exact large integers and custom product timestamps" {
  let codec : @differential.WireCodec[
    @differential.CaptureMessage[
      String,
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ] = @differential.CaptureMessage::codec(
    @differential.WireCodec::json(),
    @differential.WireCodec::product(
      @differential.WireCodec::json(),
      @differential.WireCodec::json(),
    ),
    @differential.WireCodec::json(),
  )
  let update : @differential.CaptureMessage[
    String,
    @differential.Product[Int64, Int64],
    Int64,
  ] = Updates([
    (
      "large\u0000数据",
      Product(9007199254740993L, 17L),
      -9223372036854775808L,
    ),
  ])
  let encoded = codec.to_json(update)
  assert_eq(codec.to_json(codec.from_json(encoded).unwrap()), encoded)
  let progress : @differential.CaptureMessage[
    String,
    @differential.Product[Int64, Int64],
    Int64,
  ] = Progress(
    CaptureProgress(
      Antichain([Product(0L, 0L)]),
      Antichain([Product(9007199254740994L, 17L)]),
      [(Product(9007199254740993L, 17L), 1L)],
    ),
  )
  let encoded = codec.to_json(progress)
  assert_eq(codec.to_json(codec.from_json(encoded).unwrap()), encoded)
}

///|
test "capture codec rejects corrupt envelopes and invalid progress without aborting" {
  let codec : @differential.WireCodec[
    @differential.CaptureMessage[Int32, Int64, Int64],
  ] = @differential.CaptureMessage::codec(
    @differential.WireCodec::json(),
    @differential.WireCodec::json(),
    @differential.WireCodec::json(),
  )
  let invalid : Array[Json] = [
    [],
    ["moon-differential-capture/2", "updates", []],
    ["moon-differential-capture/1", "updates", [[1, "0"]]],
    ["moon-differential-capture/1", "updates", [[1, "bad", "1"]]],
    ["moon-differential-capture/1", "progress", ["2"], ["1"], []],
    ["moon-differential-capture/1", "progress", ["0"], ["1"], [["0", "0"]]],
    ["moon-differential-capture/1", "progress", ["0"], ["1"], [["0", "-1"]]],
    ["moon-differential-capture/1", "progress", ["0"], ["1"], [["1", "1"]]],
    [
      "moon-differential-capture/1",
      "progress",
      ["0"],
      ["1"],
      [["0", "1"], ["0", "1"]],
    ],
  ]
  for json in invalid {
    assert_true(codec.from_json(json) is None)
  }
}
