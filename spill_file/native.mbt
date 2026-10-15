///|
extern "c" fn open_file() -> FileHandle = "dd_spill_open"

///|
#borrow(file, bytes)
extern "c" fn append(file : FileHandle, bytes : Bytes) -> Int64 = "dd_spill_append"

///|
#borrow(file)
extern "c" fn read(file : FileHandle, offset : Int64, length : Int32) -> Bytes = "dd_spill_read"

///|
#borrow(file)
extern "c" fn error(file : FileHandle) -> Int32 = "dd_spill_error"

///|
#borrow(file)
extern "c" fn close_file(file : FileHandle) -> Unit = "dd_spill_close"
