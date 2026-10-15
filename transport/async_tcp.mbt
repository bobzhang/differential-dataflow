///|
priv type Transfer

///|
#borrow(socket, bytes)
extern "c" fn start_send(socket : Socket, bytes : Bytes) -> Transfer = "dd_tcp_start_send"

///|
#borrow(socket)
extern "c" fn start_receive(socket : Socket) -> Transfer = "dd_tcp_start_receive"

///|
#borrow(socket, transfer)
extern "c" fn poll_frame(socket : Socket, transfer : Transfer) -> Int32 = "dd_tcp_poll_frame"

///|
#borrow(transfer)
extern "c" fn take_frame(transfer : Transfer) -> Bytes = "dd_tcp_take_frame"

///|
priv enum TcpRound {
  Gather(Array[String?], Array[Transfer?])
  Publish(Array[String], Array[Transfer?])
  Client(Transfer, Transfer)
}

///|
fn Socket::poll(
  self : Socket,
  transfer : Transfer,
) -> Bool raise TransportError {
  let status = poll_frame(self, transfer)
  self.check()
  status == 1
}

///|
fn Transfer::value(self : Transfer) -> String raise TransportError {
  @utf8.decode(take_frame(self)) catch {
    _ => raise TransportError("TCP payload is not UTF-8")
  }
}

///|
/// Submit one all-gather without waiting for socket readiness. The constructor's
/// connection/handshake remains synchronous. Drive poll_exchange until complete;
/// a transport supports one outstanding exchange, with the existing frame bounds
/// and I/O deadlines. The String is copied into owned transfer storage.
pub fn TcpTransport::start_exchange(
  self : TcpTransport,
  value : String,
) -> Unit raise {
  guard !self.closed else { raise TransportError("TCP transport is closed") }
  guard self.pending is None else {
    raise TransportError("TCP exchange is already pending")
  }
  errdefer self.close()
  if self.index == 0 {
    let values = Array::make(self.peers, None)
    values[0] = Some(value)
    let receives = Array::make(self.peers, None)
    for peer in 1..<self.peers {
      let socket = self.sockets[peer].unwrap()
      receives[peer] = Some(start_receive(socket))
      socket.check()
    }
    self.pending = Some(Gather(values, receives))
  } else {
    let socket = self.sockets[0].unwrap()
    let send = start_send(socket, @utf8.encode(value))
    socket.check()
    let receive = start_receive(socket)
    socket.check()
    self.pending = Some(Client(send, receive))
  }
}

///|
/// Perform bounded nonblocking I/O per peer. None means the exchange is pending;
/// Some contains peer-ordered values and permits the next exchange. Each frame
/// advances by at most one header and 64 KiB of payload per call. No poll/sleep or
/// readiness wait occurs; the host decides when to call again.
pub fn TcpTransport::poll_exchange(self : TcpTransport) -> Array[String]? raise {
  guard !self.closed else { raise TransportError("TCP transport is closed") }
  guard self.pending is Some(pending) else {
    raise TransportError("no TCP exchange is pending")
  }
  errdefer self.close()
  match pending {
    Gather(values, receives) => {
      for peer in 1..<self.peers {
        if receives[peer] is Some(frame) &&
          self.sockets[peer].unwrap().poll(frame) {
          values[peer] = Some(frame.value())
          receives[peer] = None
        }
      }
      if values.iter().all(fn(value) { value is Some(_) }) {
        let result = values.map(fn(value) { value.unwrap() })
        if self.peers == 1 {
          self.pending = None
          return Some(result)
        }
        let message = @utf8.encode(Json(result).stringify())
        let sends = Array::make(self.peers, None)
        for peer in 1..<self.peers {
          let socket = self.sockets[peer].unwrap()
          sends[peer] = Some(start_send(socket, message))
          socket.check()
        }
        self.pending = Some(Publish(result, sends))
      }
      None
    }
    Publish(values, sends) => {
      for peer in 1..<self.peers {
        if sends[peer] is Some(frame) && self.sockets[peer].unwrap().poll(frame) {
          sends[peer] = None
        }
      }
      if sends.iter().all(fn(frame) { frame is None }) {
        self.pending = None
        Some(values)
      } else {
        None
      }
    }
    Client(send, receive) => {
      let socket = self.sockets[0].unwrap()
      let sent = socket.poll(send)
      let received = socket.poll(receive)
      if sent && received {
        let values : Array[String] = @json.from_json(
          @json.parse(receive.value()),
        ) catch {
          _ => raise TransportError("invalid all-gather values")
        }
        guard values.length() == self.peers else {
          raise TransportError("all-gather peer count mismatch")
        }
        self.pending = None
        Some(values)
      } else {
        None
      }
    }
  }
}
