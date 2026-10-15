///|
/// Explicit codecs make distributed data and timestamp serialization independent
/// of the execution backend. Decode must reject malformed values.
pub struct WireCodec[T] {
  priv encode : (T) -> Json
  priv decode : (Json) -> T?
}

///|
pub fn[T] WireCodec::WireCodec(
  encode~ : (T) -> Json,
  decode~ : (Json) -> T?,
) -> WireCodec[T] {
  { encode, decode, }
}

///|
/// Core JSON encoding preserves 64-bit integers as decimal strings.
pub fn[T : ToJson + @json.FromJson] WireCodec::json() -> WireCodec[T] {
  {
    encode: fn(value) { Json(value) },
    decode: fn(value) { Some(@json.from_json(value)) catch { _ => None } },
  }
}

///|
pub fn[A, B] WireCodec::product(
  a : WireCodec[A],
  b : WireCodec[B],
) -> WireCodec[Product[A, B]] {
  WireCodec(
    encode=fn(value) { [(a.encode)(value.outer), (b.encode)(value.inner)] },
    decode=fn(value) {
      guard value is [x, y] &&
        (a.decode)(x) is Some(x) &&
        (b.decode)(y) is Some(y) else {
        return None
      }
      Some(Product(x, y))
    },
  )
}

///|
pub suberror ClusterError {
  ClusterError(String)
} derive(Debug)

///|
fn[T : @json.FromJson] wire_read(value : Json) -> T raise ClusterError {
  @json.from_json(value) catch {
    _ => raise ClusterError("invalid protocol value")
  }
}

///|
pub extend ClusterError with Debug::{to_repr}

///|
pub fn[T] WireCodec::to_json(self : WireCodec[T], value : T) -> Json {
  (self.encode)(value)
}

///|
pub fn[T] WireCodec::from_json(self : WireCodec[T], value : Json) -> T? {
  (self.decode)(value)
}
