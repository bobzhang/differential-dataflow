///|
test "Rust columnar schemas preserve Unicode, wide values, groups and offsets" {
  let codec = @differential.ColumnarCodec(
    @differential.ColumnCodec::uint64(),
    @differential.ColumnCodec::string(),
    @differential.ColumnCodec::product(
      @differential.ColumnCodec::uint64(),
      @differential.ColumnCodec::uint64(),
    ),
    @differential.ColumnCodec::int64(),
  )
  let rows = [
    (
      0xffffffffffffffffUL,
      "\u{FEFF}hello\u0000月🦀",
      @differential.Product(9007199254740993UL, 4UL),
      -9223372036854775807L - 1L,
    ),
    (3UL, "", Product(2UL, 3UL), 9223372036854775807L),
  ]
  let trie = @differential.UpdatesTyped(rows)
  let bytes = codec.encode(trie)
  let decoded = codec.decode(bytes[:]).unwrap()
  assert_eq(decoded.iter().to_array(), rows)
  assert_eq(codec.encode(decoded), bytes)
  assert_true(codec.decode(bytes[:], max_values=1) is None)
  let empty = codec.encode(UpdatesTyped([]))
  assert_true(codec.decode(empty[:], max_values=0).unwrap().is_empty())
}

///|
test "columnar decoding rejects truncation, bad offsets, hostile counts and invalid UTF-8" {
  let codec = @differential.ColumnarCodec(
    @differential.ColumnCodec::uint32(),
    @differential.ColumnCodec::string(),
    @differential.ColumnCodec::uint64(),
    @differential.ColumnCodec::int64(),
  )
  let bytes = codec.encode(
    UpdatesTyped([(1U, "ABCD", 2UL, 3L), (2U, "EFGH", 3UL, -1L)]),
  )
  for cut in 0..<bytes.length() {
    assert_true(codec.decode(bytes[:cut]) is None)
  }
  assert_true(codec.decode((bytes + b"\x00")[:]) is None)
  for position in [0, 7, 32, 40, 72] {
    let changed = bytes.to_array()
    for i in 0..<8 {
      changed[position + i] = b'\xff'
    }
    assert_true(codec.decode(Bytes::from_array(changed[:])[:]) is None)
  }
  let changed = bytes.to_array()
  let index = bytes.find(b"ABCD"[:]).unwrap()
  changed[index] = b'\xff'
  assert_true(codec.decode(Bytes::from_array(changed[:])[:]) is None)
  // Mutations that remain structurally valid are allowed; none may abort while
  // reading an out-of-bounds offset or constructing inconsistent trie groups.
  for i in 0..<bytes.length() {
    let changed = bytes.to_array()
    changed[i] = (changed[i].to_uint() ^ 128U).to_byte()
    let _ = codec.decode(Bytes::from_array(changed[:])[:], max_values=100)
  }
}

///|
test "packed booleans, vectors, unit and duration match their owned values" {
  let codec = @differential.ColumnarCodec(
    @differential.ColumnCodec::bool(),
    @differential.ColumnCodec::vector(@differential.ColumnCodec::unit()),
    @differential.ColumnCodec::duration(),
    @differential.ColumnCodec::int32(),
  )
  for count in [0, 1, 63, 64, 65, 127, 128, 129] {
    let rows = Array::makei(count, fn(i) {
      (
        i % 3 != 0,
        Array::make(i % 4, ()),
        @differential.Duration(i.to_uint64(), nanoseconds=999999999U),
        i - 64,
      )
    })
    let bytes = codec.encode(UpdatesTyped(rows))
    let decoded = codec.decode(bytes[:]).unwrap()
    assert_eq(decoded.iter().to_array(), rows)
    assert_eq(codec.encode(decoded), bytes)
  }
}

///|
test "floating column schemas preserve NaN payloads and negative zero bits" {
  let codec = @differential.ColumnarCodec(
    @differential.ColumnCodec::unit(),
    @differential.ColumnCodec::unit(),
    @differential.ColumnCodec::uint64(),
    @differential.ColumnCodec::double(),
  )
  let bits = [
    0UL, 0x8000000000000000UL, 0x7ff8000000000001UL, 0xfff0000000000000UL,
  ]
  let rows = bits.map(fn(bits) { ((), (), 0UL, bits.reinterpret_as_double()) })
  let bytes = codec.encode(UpdatesTyped(rows))
  let decoded = codec.decode(bytes[:]).unwrap()
  assert_eq(
    decoded.iter().map(fn(row) { row.3.reinterpret_as_uint64() }).to_array(),
    bits,
  )
}
