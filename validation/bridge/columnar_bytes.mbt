///|
fn[K : Eq, V : Eq, T : Eq, R : Eq] encoded_columnar(
  codec : @differential.ColumnarCodec[K, V, T, R],
  trie : @differential.UpdatesTyped[K, V, T, R],
) -> String {
  let bytes = codec.encode(trie)
  guard codec.decode(bytes[:]) is Some(decoded) &&
    decoded.iter().to_array() == trie.iter().to_array() else {
    abort("columnar bytes did not round trip")
  }
  guard codec.encode(decoded) == bytes else {
    abort("columnar framing changed on decode")
  }
  bytes
  .iter()
  .map(fn(b) {
    let s = b.to_uint().to_string(radix=16)
    if s.length() == 1 {
      "0" + s
    } else {
      s
    }
  })
  .to_array()
  .join("")
}

///|
#export_name("evaluate_columnar_bytes")
pub fn evaluate_columnar_bytes(seed : Int32) -> String {
  let mut state = seed.reinterpret_as_uint()
  let strings = []
  let numbers = []
  let nested = []
  let small = []
  let words = ["", "a", "long", "月", "🦀", "\u{FEFF}x", "null\u0000byte"]
  let count = if seed % 8 == 0 { 0 } else { 65 + seed % 8 }
  for i in 0..<count {
    state = state * 1664525U + 1013904223U
    let time = (state.to_uint64() << 32) | (0xffffffffU - state).to_uint64()
    strings.push(
      (
        state % 13U,
        words[((state >> 8) % 7U).reinterpret_as_int()],
        @differential.Product(time, i.to_uint64()),
        state.to_int64() - 2147483648L,
      ),
    )
    numbers.push(
      (state % 7U, state % 5U, time % 9UL, (state % 5U).to_int64() - 2L),
    )
    nested.push(
      (
        state % 2U != 0U,
        Array::makei(i % 4, fn(j) {
          (state + j.reinterpret_as_uint()).to_uint16()
        }),
        @differential.Duration(time, nanoseconds=state % 1000000000U),
        state.reinterpret_as_int(),
      ),
    )
    small.push(
      (
        (),
        (
          @differential.Int8(state.reinterpret_as_int()),
          Int16::from_int((state >> 8).reinterpret_as_int()),
        ),
        time,
        -state.to_int64(),
      ),
    )
  }
  let u64 = @differential.ColumnCodec::uint64()
  let u32 = @differential.ColumnCodec::uint32()
  let i64 = @differential.ColumnCodec::int64()
  [
    encoded_columnar(
      ColumnarCodec(
        u32,
        @differential.ColumnCodec::string(),
        @differential.ColumnCodec::product(u64, u64),
        i64,
      ),
      UpdatesTyped(strings),
    ),
    encoded_columnar(
      ColumnarCodec(u32, u32, u64, i64),
      @differential.UpdatesTyped(numbers).consolidate(),
    ),
    encoded_columnar(
      ColumnarCodec(
        @differential.ColumnCodec::bool(),
        @differential.ColumnCodec::vector(@differential.ColumnCodec::uint16()),
        @differential.ColumnCodec::duration(),
        @differential.ColumnCodec::int32(),
      ),
      UpdatesTyped(nested),
    ),
    encoded_columnar(
      ColumnarCodec(
        @differential.ColumnCodec::unit(),
        @differential.ColumnCodec::pair(
          @differential.ColumnCodec::int8(),
          @differential.ColumnCodec::int16(),
        ),
        u64,
        i64,
      ),
      UpdatesTyped(small),
    ),
  ].join("|")
}
