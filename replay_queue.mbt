///|
// FIFO packet delivery prevents control messages from starving older records
// under a continuously active source. Consumed payloads are released immediately.
priv struct ReplayQueue[D, T, R] {
  items : Array[ReplayPacket[D, T, R]?]
  mut head : Int32
}

///|
fn[D, T, R] ReplayQueue::ReplayQueue() -> ReplayQueue[D, T, R] {
  { items: [], head: 0, }
}

///|
fn[D, T, R] ReplayQueue::push(
  self : ReplayQueue[D, T, R],
  packet : ReplayPacket[D, T, R],
) -> Unit {
  self.items.push(Some(packet))
}

///|
fn[D, T, R] ReplayQueue::pop(
  self : ReplayQueue[D, T, R],
) -> ReplayPacket[D, T, R]? {
  if self.head == self.items.length() {
    return None
  }
  let packet = self.items[self.head]
  self.items[self.head] = None
  self.head += 1
  if self.head == self.items.length() {
    self.clear()
  } else if self.head >= 1024 && self.head >= self.items.length() / 2 {
    let retained = self.items[self.head:].to_owned()
    self.items.clear()
    for item in retained {
      self.items.push(item)
    }
    self.head = 0
  }
  packet
}

///|
fn[D, T, R] ReplayQueue::is_empty(self : ReplayQueue[D, T, R]) -> Bool {
  self.head == self.items.length()
}

///|
fn[D, T, R] ReplayQueue::clear(self : ReplayQueue[D, T, R]) -> Unit {
  self.items.clear()
  self.head = 0
}
