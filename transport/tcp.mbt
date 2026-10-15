///|
type Socket

///|
#borrow(host)
extern "c" fn socket_open(
  host : Bytes,
  port : Int32,
  server : Bool,
  timeout : Int32,
  limit : Int32,
) -> Socket = "dd_tcp_open"

///|
#borrow(socket)
extern "c" fn socket_accept(socket : Socket) -> Socket = "dd_tcp_accept"

///|
#borrow(socket)
extern "c" fn socket_error(socket : Socket) -> Int32 = "dd_tcp_error"

///|
#borrow(socket)
extern "c" fn socket_close(socket : Socket) -> Unit = "dd_tcp_close"

///|
#borrow(socket, bytes)
extern "c" fn socket_send(socket : Socket, bytes : Bytes) -> Int32 = "dd_tcp_send"

///|
#borrow(socket)
extern "c" fn socket_receive(socket : Socket) -> Bytes = "dd_tcp_receive"

///|
pub suberror TransportError {
  TransportError(String)
} derive(Debug)

///|
pub extend TransportError with Debug::{to_repr}

///|
fn Socket::check(self : Socket) -> Unit raise TransportError {
  let code = socket_error(self)
  if code != 0 {
    raise TransportError("TCP operation failed (errno \{code})")
  }
}

///|
fn Socket::send(self : Socket, value : String) -> Unit raise TransportError {
  let _ = socket_send(self, @utf8.encode(value))
  self.check()
}

///|
fn Socket::receive(self : Socket) -> String raise TransportError {
  let bytes = socket_receive(self)
  self.check()
  @utf8.decode(bytes) catch {
    _ => raise TransportError("TCP payload is not UTF-8")
  }
}

///|
/// Length-prefixed TCP all-gather for ClusterWorker. Peer zero coordinates rounds;
/// all other peers connect to its host/port. POSIX native targets only. Each frame
/// has a byte limit and an I/O deadline; partial writes/reads are handled. A failed
/// round closes all local sockets and cannot be retried on this transport.
pub struct TcpTransport {
  priv sockets : Array[Socket?]
  priv index : Int32
  priv peers : Int32
  priv mut closed : Bool
  priv mut pending : TcpRound?
}

///|
pub fn TcpTransport::TcpTransport(
  host : String,
  port : Int32,
  index : Int32,
  peers : Int32,
  timeout_ms~ : Int32 = 30000,
  max_frame_bytes~ : Int32 = 67108864,
) -> TcpTransport raise {
  guard peers > 0 &&
    index >= 0 &&
    index < peers &&
    port > 0 &&
    port <= 65535 &&
    timeout_ms > 0 &&
    max_frame_bytes > 0 &&
    !host.contains("\u0000") else {
    raise TransportError("invalid TCP cluster configuration")
  }
  let result = {
    sockets: Array::make(peers, None),
    index,
    peers,
    closed: false,
    pending: None,
  }
  errdefer result.close()
  if peers == 1 {
    return result
  }
  if index == 0 {
    let listener = socket_open(
      @utf8.encode(host),
      port,
      true,
      timeout_ms,
      max_frame_bytes,
    )
    defer socket_close(listener)
    listener.check()
    for _ in 1..<peers {
      let client = socket_accept(listener)
      errdefer socket_close(client)
      client.check()
      let hello = @json.parse(client.receive()) catch {
        _ => raise TransportError("invalid TCP handshake")
      }
      guard hello is [String("moon-differential-tcp/1"), remote, size] else {
        raise TransportError("TCP protocol mismatch")
      }
      let remote : Int32 = @json.from_json(remote) catch {
        _ => raise TransportError("invalid peer identity")
      }
      let size : Int32 = @json.from_json(size) catch {
        _ => raise TransportError("invalid peer count")
      }
      guard remote > 0 &&
        remote < peers &&
        size == peers &&
        result.sockets[remote] is None else {
        raise TransportError("duplicate or incompatible TCP peer")
      }
      result.sockets[remote] = Some(client)
    }
    for peer in 1..<peers {
      result.sockets[peer].unwrap().send("ready")
    }
  } else {
    let socket = socket_open(
      @utf8.encode(host),
      port,
      false,
      timeout_ms,
      max_frame_bytes,
    )
    result.sockets[0] = Some(socket)
    socket.check()
    let hello : Json = ["moon-differential-tcp/1", Json(index), Json(peers)]
    socket.send(hello.stringify())
    guard socket.receive() == "ready" else {
      raise TransportError("TCP handshake refused")
    }
  }
  result
}

///|
pub fn TcpTransport::exchange(
  self : TcpTransport,
  value : String,
) -> Array[String] raise {
  guard !self.closed else { raise TransportError("TCP transport is closed") }
  guard self.pending is None else {
    raise TransportError("TCP exchange is already pending")
  }
  errdefer self.close()
  if self.index == 0 {
    let values = [value]
    for peer in 1..<self.peers {
      values.push(self.sockets[peer].unwrap().receive())
    }
    let message = Json(values).stringify()
    for peer in 1..<self.peers {
      self.sockets[peer].unwrap().send(message)
    }
    values
  } else {
    let socket = self.sockets[0].unwrap()
    socket.send(value)
    let message = @json.parse(socket.receive()) catch {
      _ => raise TransportError("invalid all-gather response")
    }
    let values : Array[String] = @json.from_json(message) catch {
      _ => raise TransportError("invalid all-gather values")
    }
    guard values.length() == self.peers else {
      raise TransportError("all-gather peer count mismatch")
    }
    values
  }
}

///|
pub fn TcpTransport::close(self : TcpTransport) -> Unit {
  if !self.closed {
    self.closed = true
    self.pending = None
    for socket in self.sockets {
      if socket is Some(socket) {
        socket_close(socket)
      }
    }
    self.sockets.clear()
  }
}
