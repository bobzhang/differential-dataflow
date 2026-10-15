///|
fn open_file() -> FileHandle {
  abort("temporary spill files require the native backend")
}

///|
fn append(_file : FileHandle, _bytes : Bytes) -> Int64 {
  abort("native backend required")
}

///|
fn read(_file : FileHandle, _offset : Int64, _length : Int32) -> Bytes {
  abort("native backend required")
}

///|
fn error(_file : FileHandle) -> Int32 {
  abort("native backend required")
}

///|
fn close_file(_file : FileHandle) -> Unit {
  abort("native backend required")
}
