///|
test "temporary file sources survive other appends and out-of-order reads" {
  let file = @spill_file.SpillFile()
  let store = file.store()
  let first = store.store(b"first\x00page")
  let empty = store.store(b"")
  let last = store.store(b"last page")
  assert_eq(last.load(), b"last page")
  assert_eq(first.load(), b"first\x00page")
  assert_eq(empty.load(), b"")
  assert_eq(last.load(), b"last page")
  file.close()
  file.close()
}

///|
test "panic read after spill file close" {
  let file = @spill_file.SpillFile()
  let source = file.store().store(b"page")
  file.close()
  let _ = source.load()
}
