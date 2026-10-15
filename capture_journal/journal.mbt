///|
type JournalHandle

///|
pub suberror JournalError {
  JournalError(String)
} derive(Debug)

///|
pub extend JournalError with Debug::{to_repr}

///|
fn JournalHandle::check(self : JournalHandle) -> Unit raise JournalError {
  let code = error(self)
  guard code == 0 else {
    raise JournalError("capture journal I/O failed (errno \{code})")
  }
}

///|
/// POSIX single-writer capture log with checksummed, bounded frames. Each append
/// writes a complete message and fsyncs the file. Creation also fsyncs its parent
/// directory. Filesystem and device fsync guarantees apply. A reader can follow
/// a growing file; only a terminal capture progress message establishes completion.
/// Existing logs are never overwritten. Resuming a crashed writer is not implicit.
pub struct CaptureJournal {
  priv handle : JournalHandle
  priv mut failed : Bool
}

///|
pub fn CaptureJournal::create(
  path : String,
  max_frame_bytes~ : Int32 = 67108864,
) -> CaptureJournal raise JournalError {
  let handle = open_file(@utf8.encode(path), true, max_frame_bytes)
  handle.check()
  { handle, failed: false, }
}

///|
pub fn CaptureJournal::open(
  path : String,
  max_frame_bytes~ : Int32 = 67108864,
) -> CaptureJournal raise JournalError {
  let handle = open_file(@utf8.encode(path), false, max_frame_bytes)
  handle.check()
  { handle, failed: false, }
}

///|
pub fn[D, T, R] CaptureJournal::append(
  self : CaptureJournal,
  message : @differential.CaptureMessage[D, T, R],
  codec : @differential.WireCodec[@differential.CaptureMessage[D, T, R]],
) -> Unit raise JournalError {
  guard !self.failed else {
    raise JournalError("capture journal previously failed")
  }
  errdefer {
    self.failed = true
  }
  append_bytes(self.handle, @utf8.encode(codec.to_json(message).stringify()))
  self.handle.check()
}

///|
/// None means no complete frame is currently available. Incomplete trailing
/// frames remain unread for a later poll. Corrupt complete frames and invalid
/// protocol values raise errors. The file must be append-only while being read.
pub fn[D, T, R] CaptureJournal::next(
  self : CaptureJournal,
  codec : @differential.WireCodec[@differential.CaptureMessage[D, T, R]],
) -> @differential.CaptureMessage[D, T, R]? raise JournalError {
  guard !self.failed else {
    raise JournalError("capture journal previously failed")
  }
  errdefer {
    self.failed = true
  }
  let bytes = next_bytes(self.handle)
  self.handle.check()
  guard ready(self.handle) else { return None }
  let json = @json.parse(@utf8.decode(bytes)) catch {
    _ => raise JournalError("capture journal frame is not valid UTF-8 JSON")
  }
  guard codec.from_json(json) is Some(message) else {
    raise JournalError("capture journal frame is not a valid capture message")
  }
  Some(message)
}

///|
pub fn CaptureJournal::close(self : CaptureJournal) -> Unit raise JournalError {
  close_file(self.handle)
  self.handle.check()
}
