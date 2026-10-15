///|
/// FNV-1a hasher used by upstream Hashable. Numeric writes use little-endian
/// encoding, matching the pinned Rust oracle on supported 64-bit hosts.
pub struct FnvHasher {
  priv mut state : UInt64
}

///|
pub fn FnvHasher::FnvHasher() -> FnvHasher {
  { state: 0xcbf29ce484222325UL, }
}

///|
pub fn FnvHasher::write_byte(self : FnvHasher, value : Byte) -> Unit {
  self.state = (self.state ^ value.to_uint64()) * 0x100000001b3UL
}

///|
pub fn FnvHasher::write(self : FnvHasher, bytes : BytesView) -> Unit {
  for value in bytes {
    self.write_byte(value)
  }
}

///|
pub fn FnvHasher::write_word(
  self : FnvHasher,
  value : UInt64,
  width : Int32,
) -> Unit {
  guard width >= 0 && width <= 8 else {
    abort("hash word width must be between zero and eight")
  }
  for index in 0..<width {
    self.write_byte((value >> (index * 8)).to_byte())
  }
}

///|
pub fn FnvHasher::finish(self : FnvHasher) -> UInt64 {
  self.state
}

///|
/// Rust Hash byte encoding for identifier interoperability. Custom records can
/// implement this trait by hashing their fields in declaration order.
pub(open) trait RustHash {
  fn hash_into(Self, FnvHasher) -> Unit
}

///|
pub fn[T : RustHash] rust_hash(value : T) -> UInt64 {
  let hasher = FnvHasher()
  value.hash_into(hasher)
  hasher.finish()
}

///|
pub impl RustHash for Byte with fn hash_into(self, hasher) {
  hasher.write_word(self.to_uint64(), 1)
}

///|
pub impl RustHash for Int8 with fn hash_into(self, hasher) {
  hasher.write_word(self.to_int().to_int64().reinterpret_as_uint64(), 1)
}

///|
pub impl RustHash for Int16 with fn hash_into(self, hasher) {
  hasher.write_word(self.to_int().to_int64().reinterpret_as_uint64(), 2)
}

///|
pub impl RustHash for UInt16 with fn hash_into(self, hasher) {
  hasher.write_word(self.to_uint64(), 2)
}

///|
pub impl RustHash for Int32 with fn hash_into(self, hasher) {
  hasher.write_word(self.to_int64().reinterpret_as_uint64(), 4)
}

///|
pub impl RustHash for UInt32 with fn hash_into(self, hasher) {
  hasher.write_word(self.to_uint64(), 4)
}

///|
pub impl RustHash for Int64 with fn hash_into(self, hasher) {
  hasher.write_word(self.reinterpret_as_uint64(), 8)
}

///|
pub impl RustHash for UInt64 with fn hash_into(self, hasher) {
  hasher.write_word(self, 8)
}

///|
pub impl RustHash for Int128 with fn hash_into(self, hasher) {
  let (high, low) = self.to_words()
  hasher.write_word(low, 8)
  hasher.write_word(high.reinterpret_as_uint64(), 8)
}

///|
pub impl RustHash for UInt128 with fn hash_into(self, hasher) {
  let (high, low) = self.to_words()
  hasher.write_word(low, 8)
  hasher.write_word(high, 8)
}

///|
pub impl RustHash for Bool with fn hash_into(self, hasher) {
  hasher.write_byte(if self { 1 } else { 0 })
}

///|
pub impl RustHash for Unit with fn hash_into(_, _) {
  ()
}

///|
pub impl RustHash for Char with fn hash_into(self, hasher) {
  hasher.write_word(self.to_int().to_uint64(), 4)
}

///|
pub impl RustHash for String with fn hash_into(self, hasher) {
  hasher.write(@utf8.encode(self[:]))
  hasher.write_byte(255)
}

///|
pub impl RustHash for Bytes with fn hash_into(self, hasher) {
  hasher.write_word(self.length().to_uint64(), 8)
  hasher.write(self)
}

///|
pub impl[T : RustHash] RustHash for Array[T] with fn hash_into(self, hasher) {
  hasher.write_word(self.length().to_uint64(), 8)
  for value in self {
    value.hash_into(hasher)
  }
}

///|
pub impl[T : RustHash] RustHash for T? with fn hash_into(self, hasher) {
  match self {
    None => hasher.write_word(0UL, 8)
    Some(value) => {
      hasher.write_word(1UL, 8)
      value.hash_into(hasher)
    }
  }
}

///|
pub impl[A : RustHash, B : RustHash] RustHash for (A, B) with fn hash_into(
  self,
  hasher,
) {
  self.0.hash_into(hasher)
  self.1.hash_into(hasher)
}

///|
pub impl[A : RustHash, B : RustHash, C : RustHash] RustHash for (A, B, C) with fn hash_into(
  self,
  hasher,
) {
  self.0.hash_into(hasher)
  self.1.hash_into(hasher)
  self.2.hash_into(hasher)
}

///|
pub impl[A : RustHash, B : RustHash, C : RustHash, D : RustHash] RustHash for (
  A,
  B,
  C,
  D,
) with fn hash_into(self, hasher) {
  self.0.hash_into(hasher)
  self.1.hash_into(hasher)
  self.2.hash_into(hasher)
  self.3.hash_into(hasher)
}

///|
pub extend Int8 with RustHash::{hash_into}

///|
pub extend Int128 with RustHash::{hash_into}

///|
pub extend UInt128 with RustHash::{hash_into}
