///|
/// Schema for a Rust columnar value container. Slices are the component columns
/// in upstream AsBytes order; all integers use little-endian encoding. Custom
/// structs/enums can supply their own schema without changing trie framing.
pub struct ColumnCodec[A] {
  priv slices : Int32
  priv encode : (Array[A]) -> Array[Bytes]
  priv decode : (Array[BytesView], Int32) -> Array[A]?
}

///|
pub fn[A] ColumnCodec::ColumnCodec(
  slices~ : Int32,
  encode~ : (Array[A]) -> Array[Bytes],
  decode~ : (Array[BytesView], Int32) -> Array[A]?,
) -> ColumnCodec[A] {
  guard slices > 0 && slices <= 1024 else {
    abort("invalid column schema slice count")
  }
  { slices, encode, decode, }
}

///|
fn column_read_uint(bytes : BytesView, offset : Int32, width : Int32) -> UInt64 {
  let mut value = 0UL
  for i in 0..<width {
    value = value | (bytes[offset + i].to_uint64() << (8 * i))
  }
  value
}

///|
fn column_uints(values : Array[UInt64], width : Int32) -> Bytes {
  Bytes::makei(values.length() * width, fn(i) {
    (values[i / width] >> (8 * (i % width))).to_byte()
  })
}

///|
fn column_number(width : Int32) -> ColumnCodec[UInt64] {
  ColumnCodec(slices=1, encode=fn(values) { [column_uints(values, width)] }, decode=fn(
    slices,
    count,
  ) {
    guard slices.length() == 1 &&
      count >= 0 &&
      count <= slices[0].length() / width &&
      slices[0].length() % width == 0 &&
      slices[0].length() / width == count else {
      return None
    }
    Some(
      Array::makei(count, fn(i) {
        column_read_uint(slices[0], i * width, width)
      }),
    )
  })
}

///|
/// Adapt a storage schema through checked owned-value conversions.
pub fn[A, B] ColumnCodec::map(
  self : ColumnCodec[A],
  encode : (B) -> A,
  decode : (A) -> B?,
) -> ColumnCodec[B] {
  ColumnCodec(
    slices=self.slices,
    encode=fn(values) { (self.encode)(values.map(encode)) },
    decode=fn(slices, count) {
      guard (self.decode)(slices, count) is Some(values) else { return None }
      let result = []
      for value in values {
        guard decode(value) is Some(value) else { return None }
        result.push(value)
      }
      Some(result)
    },
  )
}

///|
pub fn ColumnCodec::uint64() -> ColumnCodec[UInt64] {
  column_number(8)
}

///|
pub fn ColumnCodec::int64() -> ColumnCodec[Int64] {
  column_number(8).map(fn(x) { x.reinterpret_as_uint64() }, fn(x) {
    Some(x.reinterpret_as_int64())
  })
}

///|
pub fn ColumnCodec::uint32() -> ColumnCodec[UInt32] {
  column_number(4).map(fn(x) { x.to_uint64() }, fn(x) { Some(x.to_uint()) })
}

///|
pub fn ColumnCodec::int32() -> ColumnCodec[Int32] {
  ColumnCodec::uint32().map(fn(x) { x.reinterpret_as_uint() }, fn(x) {
    Some(x.reinterpret_as_int())
  })
}

///|
pub fn ColumnCodec::uint16() -> ColumnCodec[UInt16] {
  column_number(2).map(fn(x) { x.to_uint64() }, fn(x) { Some(x.to_uint16()) })
}

///|
pub fn ColumnCodec::byte() -> ColumnCodec[Byte] {
  column_number(1).map(fn(x) { x.to_uint64() }, fn(x) { Some(x.to_byte()) })
}

///|
pub fn ColumnCodec::double() -> ColumnCodec[Double] {
  column_number(8).map(fn(x) { x.reinterpret_as_uint64() }, fn(x) {
    Some(x.reinterpret_as_double())
  })
}

///|
pub fn ColumnCodec::unit() -> ColumnCodec[Unit] {
  ColumnCodec(
    slices=1,
    encode=fn(values) { [column_uints([values.length().to_uint64()], 8)] },
    decode=fn(slices, count) {
      guard slices.length() == 1 &&
        slices[0].length() == 8 &&
        column_read_uint(slices[0], 0, 8) == count.to_uint64() else {
        return None
      }
      Some(Array::make(count, ()))
    },
  )
}

///|
pub fn[A, B] ColumnCodec::pair(
  left : ColumnCodec[A],
  right : ColumnCodec[B],
) -> ColumnCodec[(A, B)] {
  ColumnCodec(
    slices=left.slices + right.slices,
    encode=fn(values) {
      (left.encode)(values.map(fn(v) { v.0 })) +
      (right.encode)(values.map(fn(v) { v.1 }))
    },
    decode=fn(slices, count) {
      guard slices.length() == left.slices + right.slices &&
        (left.decode)(slices[:left.slices].to_owned(), count) is Some(a) &&
        (right.decode)(slices[left.slices:].to_owned(), count) is Some(b) &&
        a.length() == count &&
        b.length() == count else {
        return None
      }
      Some(Array::makei(count, fn(i) { (a[i], b[i]) }))
    },
  )
}

///|
pub fn[A, B] ColumnCodec::product(
  outer : ColumnCodec[A],
  inner : ColumnCodec[B],
) -> ColumnCodec[Product[A, B]] {
  ColumnCodec::pair(outer, inner).map(fn(v) { (v.outer, v.inner) }, fn(v) {
    Some(Product(v.0, v.1))
  })
}

///|
pub fn ColumnCodec::duration() -> ColumnCodec[Duration] {
  ColumnCodec::pair(ColumnCodec::uint64(), ColumnCodec::uint32()).map(
    fn(v) { (v.seconds(), v.nanoseconds()) },
    fn(v) {
      if v.1 < 1000000000U {
        Some(Duration(v.0, nanoseconds=v.1))
      } else {
        None
      }
    },
  )
}

///|
/// Rust Vec containers use a plain u64 end-offset column followed by the item
/// schema (unlike trie lists, whose offsets use the Strides representation).
pub fn[A] ColumnCodec::vector(item : ColumnCodec[A]) -> ColumnCodec[Array[A]] {
  ColumnCodec(
    slices=1 + item.slices,
    encode=fn(values) {
      let ends = []
      let flat = []
      for list in values {
        for value in list {
          flat.push(value)
        }
        ends.push(flat.length().to_uint64())
      }
      [column_uints(ends, 8)] + (item.encode)(flat)
    },
    decode=fn(slices, count) {
      guard slices.length() == 1 + item.slices &&
        slices[0].length() % 8 == 0 &&
        slices[0].length() / 8 == count else {
        return None
      }
      let ends = []
      let mut last = 0UL
      for i in 0..<count {
        let end = column_read_uint(slices[0], i * 8, 8)
        guard end >= last && end <= 10000000UL else { return None }
        ends.push(end.to_int())
        last = end
      }
      guard (item.decode)(slices[1:].to_owned(), last.to_int()) is Some(flat) &&
        flat.length() == last.to_int() else {
        return None
      }
      let result = []
      let mut lower = 0
      for upper in ends {
        result.push(flat[lower:upper].to_owned())
        lower = upper
      }
      Some(result)
    },
  )
}

///|
pub fn ColumnCodec::bytes() -> ColumnCodec[Bytes] {
  ColumnCodec::vector(ColumnCodec::byte()).map(fn(bytes) { bytes.to_array() }, fn(
    values,
  ) {
    Some(Bytes::from_array(values[:]))
  })
}

///|
pub fn ColumnCodec::string() -> ColumnCodec[String] {
  ColumnCodec::bytes().map(fn(value) { @utf8.encode(value[:]) }, fn(value) {
    let text = @utf8.decode(value[:], ignore_bom=false) catch {
      _ => return None
    }
    Some(text)
  })
}

///|
pub fn ColumnCodec::bool() -> ColumnCodec[Bool] {
  ColumnCodec(
    slices=2,
    encode=fn(values) {
      let words = []
      let mut tail = 0UL
      let mut bits = 0
      for value in values {
        if value {
          tail = tail | (1UL << bits)
        }
        bits += 1
        if bits == 64 {
          words.push(tail)
          tail = 0UL
          bits = 0
        }
      }
      [column_uints(words, 8), column_uints([tail, bits.to_uint64()], 8)]
    },
    decode=fn(slices, count) {
      guard slices.length() == 2 &&
        slices[0].length() % 8 == 0 &&
        slices[1].length() == 16 else {
        return None
      }
      let bits = column_read_uint(slices[1], 8, 8)
      guard bits < 64UL &&
        slices[0].length() / 8 == count / 64 &&
        bits.to_int() == count % 64 else {
        return None
      }
      let tail = column_read_uint(slices[1], 0, 8)
      Some(
        Array::makei(count, fn(i) {
          let word = if i / 64 == count / 64 {
            tail
          } else {
            column_read_uint(slices[0], i / 64 * 8, 8)
          }
          (word & (1UL << (i % 64))) != 0UL
        }),
      )
    },
  )
}

///|
fn[A] column_stash_encode(
  lists : ColumnLists[A],
  codec : ColumnCodec[A],
) -> Bytes {
  let mut stride = 0
  let mut run = 0
  for end in lists.ends {
    if run == 0 {
      stride = end
      run = 1
    } else if end.to_int64() == stride.to_int64() * (run + 1).to_int64() {
      run += 1
    } else {
      break
    }
  }
  let extra = lists.ends[run:].to_owned().map(fn(v) { v.to_uint64() })
  let slices = [
      column_uints([stride.to_uint64(), run.to_uint64()], 8),
      column_uints(extra, 8),
    ] +
    (codec.encode)(lists.values)
  guard slices.length() == codec.slices + 2 else {
    abort("custom column encoder returned wrong slice count")
  }
  let bytes = []
  let ends = [(slices.length() + 1).to_uint64() * 8UL]
  let mut position = ends[0]
  for slice in slices {
    ends.push(position + slice.length().to_uint64())
    position += (slice.length().to_uint64() + 7UL) / 8UL * 8UL
  }
  for byte in column_uints(ends, 8) {
    bytes.push(byte)
  }
  for slice in slices {
    for byte in slice {
      bytes.push(byte)
    }
    for _ in 0..<((8 - slice.length() % 8) % 8) {
      bytes.push(b'\x00')
    }
  }
  Bytes::from_array(bytes[:])
}

///|
fn[A] column_stash_decode(
  bytes : BytesView,
  codec : ColumnCodec[A],
  max_values : Int32,
) -> ColumnLists[A]? {
  let count = codec.slices + 2
  let header = (count + 1) * 8
  guard bytes.length() >= header &&
    bytes.length() % 8 == 0 &&
    column_read_uint(bytes, 0, 8) == header.to_uint64() else {
    return None
  }
  let slices = []
  let mut lower = header
  for i in 0..<count {
    let end = column_read_uint(bytes, (i + 1) * 8, 8)
    guard end >= lower.to_uint64() && end <= bytes.length().to_uint64() else {
      return None
    }
    let upper = end.to_int()
    slices.push(bytes[lower:upper])
    let aligned = (end + 7UL) / 8UL * 8UL
    guard aligned <= bytes.length().to_uint64() else { return None }
    lower = aligned.to_int()
  }
  guard lower == bytes.length() &&
    slices[0].length() == 16 &&
    slices[1].length() % 8 == 0 else {
    return None
  }
  let stride = column_read_uint(slices[0], 0, 8)
  let run = column_read_uint(slices[0], 8, 8)
  let extras = slices[1].length() / 8
  guard run <= max_values.to_uint64() && extras <= max_values - run.to_int() else {
    return None
  }
  guard run == 0UL || stride <= max_values.to_uint64() / run else {
    return None
  }
  let ends = Array::makei(run.to_int(), fn(i) {
    ((i + 1).to_uint64() * stride).to_int()
  })
  let mut previous = stride * run
  for i in 0..<extras {
    let end = column_read_uint(slices[1], i * 8, 8)
    guard previous <= end && end <= max_values.to_uint64() else { return None }
    ends.push(end.to_int())
    previous = end
  }
  guard (codec.decode)(slices[2:].to_owned(), previous.to_int()) is Some(values) &&
    values.length() == previous.to_int() else {
    return None
  }
  Some({ values, ends, })
}

///|
/// Pinned Rust Updates<U> framing: four little-endian u64 column lengths followed
/// by four indexed Stash encodings. Schemas must match the Rust value types.
pub struct ColumnarCodec[K, V, T, R] {
  priv key : ColumnCodec[K]
  priv val : ColumnCodec[V]
  priv time : ColumnCodec[T]
  priv diff : ColumnCodec[R]
}

///|
pub fn[K, V, T, R] ColumnarCodec::ColumnarCodec(
  key : ColumnCodec[K],
  val : ColumnCodec[V],
  time : ColumnCodec[T],
  diff : ColumnCodec[R],
) -> ColumnarCodec[K, V, T, R] {
  { key, val, time, diff, }
}

///|
pub fn[K, V, T, R] ColumnarCodec::encode(
  self : ColumnarCodec[K, V, T, R],
  updates : UpdatesTyped[K, V, T, R],
) -> Bytes {
  let columns = [
    column_stash_encode(updates.keys, self.key),
    column_stash_encode(updates.vals, self.val),
    column_stash_encode(updates.times, self.time),
    column_stash_encode(updates.diffs, self.diff),
  ]
  let bytes = column_uints(columns.map(fn(c) { c.length().to_uint64() }), 8).to_array()
  for column in columns {
    for byte in column {
      bytes.push(byte)
    }
  }
  Bytes::from_array(bytes[:])
}

///|
/// Decode owned columns, checking framing, offsets and parent/child counts.
/// max_values bounds each column's element/list counts, including zero-sized
/// elements. Decoded raw tries can be consolidated before chunk operations.
pub fn[K, V, T, R] ColumnarCodec::decode(
  self : ColumnarCodec[K, V, T, R],
  bytes : BytesView,
  max_values~ : Int32 = 10000000,
) -> UpdatesTyped[K, V, T, R]? {
  guard max_values >= 0 && bytes.length() >= 32 else { return None }
  let columns = []
  let mut lower = 32
  for i in 0..<4 {
    let length = column_read_uint(bytes, i * 8, 8)
    guard length <= (bytes.length() - lower).to_uint64() else { return None }
    let upper = lower + length.to_int()
    columns.push(bytes[lower:upper])
    lower = upper
  }
  guard lower == bytes.length() &&
    column_stash_decode(columns[0], self.key, max_values) is Some(keys) &&
    column_stash_decode(columns[1], self.val, max_values) is Some(vals) &&
    column_stash_decode(columns[2], self.time, max_values) is Some(times) &&
    column_stash_decode(columns[3], self.diff, max_values) is Some(diffs) &&
    keys.value_count() == vals.length() &&
    vals.value_count() == times.length() &&
    times.value_count() == diffs.length() else {
    return None
  }
  Some({ keys, vals, times, diffs, canonical: false, })
}

///|
pub fn ColumnCodec::int8() -> ColumnCodec[Int8] {
  ColumnCodec::byte().map(fn(v) { v.to_int().to_byte() }, fn(v) {
    Some(Int8(v.to_int()))
  })
}

///|
pub fn ColumnCodec::int16() -> ColumnCodec[Int16] {
  ColumnCodec::uint16().map(
    fn(v) { v.to_int().reinterpret_as_uint().to_uint16() },
    fn(v) { Some(Int16::from_int(v.to_int())) },
  )
}

///|
/// Page trace batches using the exact Rust columnar Updates<U> encoding. The
/// policy keeps the same high-water budget and one-page-per-reader cache.
pub fn[K : Compare, V : Compare, T : Compare, R : Semigroup] ColumnarCodec::spill_policy(
  self : ColumnarCodec[K, V, T, R],
  budget_records : Int64,
  store~ : BytesStore,
  chunk_size~ : Int32 = 8192,
) -> SpillPolicy[(K, V), T, R] {
  SpillPolicy::binary(
    budget_records,
    store~,
    chunk_size~,
    encode=fn(rows) {
      self.encode(
        UpdatesTyped::form(
          rows.iter().map(fn(row) { (row.0.0, row.0.1, row.1, row.2) }),
        ),
      )
    },
    decode=fn(bytes) {
      guard self.decode(bytes, max_values=chunk_size) is Some(trie) else {
        return None
      }
      Some(
        trie.iter().map(fn(row) { ((row.0, row.1), row.2, row.3) }).to_array(),
      )
    },
  )
}
