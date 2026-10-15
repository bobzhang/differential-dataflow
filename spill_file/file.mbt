///|
type FileHandle

///|
fn FileHandle::check(self : FileHandle) -> Unit {
  let code = error(self)
  guard code == 0 else { abort("spill file I/O failed (errno \{code})") }
}

///|
/// Anonymous temporary-file store. Handles keep the file alive until released.
/// close is optional and invalidates outstanding byte handles. This is temporary
/// trace storage, not a durable checkpoint or cross-process sharing protocol.
pub struct SpillFile {
  priv handle : FileHandle
}

///|
pub fn SpillFile::SpillFile() -> SpillFile {
  let handle = open_file()
  handle.check()
  { handle, }
}

///|
pub fn SpillFile::store(self : SpillFile) -> @differential.BytesStore {
  let handle = self.handle
  BytesStore(fn(bytes) {
    let length = bytes.length()
    let offset = append(handle, bytes)
    handle.check()
    BytesSource(fn() {
      let bytes = read(handle, offset, length)
      handle.check()
      bytes
    })
  })
}

///|
pub fn SpillFile::close(self : SpillFile) -> Unit {
  close_file(self.handle)
}
