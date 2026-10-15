///|
#borrow(path)
extern "c" fn open_file(
  path : Bytes,
  writer : Bool,
  limit : Int32,
) -> JournalHandle = "dd_journal_open"

///|
#borrow(handle, bytes)
extern "c" fn append_bytes(handle : JournalHandle, bytes : Bytes) -> Unit = "dd_journal_append"

///|
#borrow(handle)
extern "c" fn next_bytes(handle : JournalHandle) -> Bytes = "dd_journal_next"

///|
#borrow(handle)
extern "c" fn error(handle : JournalHandle) -> Int32 = "dd_journal_error"

///|
#borrow(handle)
extern "c" fn ready(handle : JournalHandle) -> Bool = "dd_journal_ready"

///|
#borrow(handle)
extern "c" fn close_file(handle : JournalHandle) -> Unit = "dd_journal_close"
