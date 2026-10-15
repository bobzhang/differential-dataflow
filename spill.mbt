///|
/// A persistent immutable byte handle. A failed load must abort, as in upstream.
pub struct BytesSource {
  priv read : () -> Bytes
}

///|
pub fn BytesSource::BytesSource(load : () -> Bytes) -> BytesSource {
  { read: load, }
}

///|
pub fn BytesSource::load(self : BytesSource) -> Bytes {
  (self.read)()
}

///|
/// Store bytes and return a handle that can reproduce them after this call.
pub struct BytesStore {
  priv write : (Bytes) -> BytesSource
}

///|
pub fn BytesStore::BytesStore(store : (Bytes) -> BytesSource) -> BytesStore {
  { write: store, }
}

///|
pub fn BytesStore::store(self : BytesStore, bytes : Bytes) -> BytesSource {
  (self.write)(bytes)
}

///|
pub(all) struct SpillStats {
  spilled_chunks : Int64
  spilled_records : Int64
  fetched_chunks : Int64
  bytes_written : Int64
  resident_records : Int64
} derive(Eq, Debug)

///|
pub extend SpillStats with Eq::{equal, not_equal}

///|
pub extend SpillStats with Debug::{to_repr}

///|
/// Explicit per-worker high-water-mark policy. Resident budget is not reclaimed
/// when old batches disappear, matching upstream. Readers cache at most one page
/// each; counters are cumulative. The codec is an application-selected encoding.
pub struct SpillPolicy[D, T, R] {
  priv budget : Int64
  priv chunk_size : Int32
  priv store : BytesStore
  priv codec : WireCodec[Array[(D, T, R)]]
  priv mut resident : Int64
  priv mut spilled_chunks : Int64
  priv mut spilled_records : Int64
  priv mut fetched_chunks : Int64
  priv mut bytes_written : Int64
}

///|
pub fn[D, T, R] SpillPolicy::SpillPolicy(
  budget_records : Int64,
  store~ : BytesStore,
  codec~ : WireCodec[Array[(D, T, R)]],
  chunk_size~ : Int32 = 8192,
) -> SpillPolicy[D, T, R] {
  guard budget_records >= 0 && chunk_size > 0 else {
    abort("invalid spill budget or chunk size")
  }
  {
    budget: budget_records,
    chunk_size,
    store,
    codec,
    resident: 0L,
    spilled_chunks: 0L,
    spilled_records: 0L,
    fetched_chunks: 0L,
    bytes_written: 0L,
  }
}

///|
pub fn[D, T, R] SpillPolicy::stats(self : SpillPolicy[D, T, R]) -> SpillStats {
  {
    resident_records: self.resident,
    spilled_chunks: self.spilled_chunks,
    spilled_records: self.spilled_records,
    fetched_chunks: self.fetched_chunks,
    bytes_written: self.bytes_written,
  }
}

///|
// Integrity check detects an accidentally changed store payload before decoding.
fn spill_checksum(bytes : Bytes) -> UInt32 {
  let mut hash = 2166136261U
  for byte in bytes {
    hash = (hash ^ byte.to_uint()) * 16777619U
  }
  hash
}

///|
fn[D, T, R] SpillPolicy::pack(
  self : SpillPolicy[D, T, R],
  rows : Array[(D, T, R)],
  resident_pack : (Array[(D, T, R)]) -> UpdateStorage[D, T, R],
) -> UpdateStorage[D, T, R] {
  let size = rows.length()
  let pages : Array[() -> UpdateReader[D, T, R]] = []
  let mut start = 0
  while start < size {
    let length = Int32::min(self.chunk_size, size - start)
    let chunk = rows[start:start + length].to_owned()
    if length.to_int64() <= self.budget - self.resident {
      self.resident += length.to_int64()
      let storage = resident_pack(chunk)
      pages.push(fn() { storage.reader() })
    } else {
      let bytes = @utf8.encode((self.codec.encode)(chunk).stringify())
      let checksum = spill_checksum(bytes)
      let byte_length = bytes.length()
      let source = self.store.store(bytes)
      self.spilled_chunks += 1
      self.spilled_records += length.to_int64()
      self.bytes_written += byte_length.to_int64()
      pages.push(fn() {
        let bytes = source.load()
        guard bytes.length() == byte_length && spill_checksum(bytes) == checksum else {
          abort("spill store payload changed")
        }
        let json = @json.parse(
          @utf8.decode(bytes) catch {
            _ => abort("spill page is not UTF-8")
          },
        ) catch {
          _ => abort("spill page is not JSON")
        }
        guard (self.codec.decode)(json) is Some(chunk) &&
          chunk.length() == length else {
          abort("spill page decoding failed")
        }
        self.fetched_chunks += 1
        resident_pack(chunk).reader()
      })
    }
    start += length
  }
  let chunk_size = self.chunk_size
  Paged(
    size,
    fn() {
      let cached : Ref[(Int32, UpdateReader[D, T, R])?] = Ref(None)
      {
        size,
        read: fn(index) {
          guard index >= 0 && index < size else {
            abort("spill update index out of bounds")
          }
          let page = index / chunk_size
          let reader = match cached.val {
            Some((last, reader)) if last == page => reader
            _ => {
              let reader = pages[page]()
              cached.val = Some((page, reader))
              reader
            }
          }
          reader[index % chunk_size]
        },
      }
    },
    fn(rows) { self.pack(rows, resident_pack) },
  )
}

///|
/// Page a sealed batch using this policy. Repeated calls on a paged batch are
/// idempotent. Compaction and merges continue to use its original spill policy.
pub fn[D, T, R] Batch::spill(
  self : Batch[D, T, R],
  policy : SpillPolicy[D, T, R],
) -> Batch[D, T, R] {
  if self.updates is Paged(_, _, _) {
    return self
  }
  {
    updates: policy.pack(self.to_array(), self.updates.packer()),
    description: self.description,
  }
}
