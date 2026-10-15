///|
fn open_file(_path : Bytes, _writer : Bool, _limit : Int32) -> JournalHandle {
  abort("capture journals require POSIX native")
}

///|
fn append_bytes(_handle : JournalHandle, _bytes : Bytes) -> Unit {
  abort("capture journals require POSIX native")
}

///|
fn next_bytes(_handle : JournalHandle) -> Bytes {
  abort("capture journals require POSIX native")
}

///|
fn error(_handle : JournalHandle) -> Int32 {
  abort("capture journals require POSIX native")
}

///|
fn ready(_handle : JournalHandle) -> Bool {
  abort("capture journals require POSIX native")
}

///|
fn close_file(_handle : JournalHandle) -> Unit {
  abort("capture journals require POSIX native")
}
