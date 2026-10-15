///|
fn main raise {
  let args = @env.args()
  let peer : Int32 = @json.from_json(@json.parse(args[1]))
  let port : Int32 = @json.from_json(@json.parse(args[2]))
  let seed : Int32 = @json.from_json(@json.parse(args[3]))
  let peers : Int32 = @json.from_json(@json.parse(args[4]))
  let mode = if args.length() > 5 { args[5] } else { "join" }
  let transport = @transport.TcpTransport(
    "127.0.0.1",
    port,
    peer,
    peers,
    timeout_ms=if mode == "timeout" || mode == "async_timeout" {
      200
    } else {
      10000
    },
  )
  defer transport.close()
  if mode == "async_wire" || mode == "async_timeout" || mode == "async_wait" {
    let payload = "🪐☄️漢字\u0000".repeat(seed)
    for _ in 0..<3 {
      transport.start_exchange(payload)
      if mode == "async_wait" {
        guard transport.poll_exchange() is None else {
          abort("expected a pending exchange")
        }
        println("wire-ok")
        return
      }
      for ;; {
        if transport.poll_exchange() is Some(values) {
          guard values.length() == peers &&
            values.iter().all(fn(value) { value == payload }) else {
            abort("async wire round trip mismatch")
          }
          break
        }
      }
    }
    println("wire-ok")
    return
  }
  if mode == "wire" {
    let payload = "🪐☄️漢字\u0000".repeat(seed)
    let values = transport.exchange(payload)
    guard values.length() == peers &&
      values.iter().all(fn(value) { value == payload }) else {
      abort("wire round trip mismatch")
    }
    println("wire-ok")
    return
  }
  let asynchronous = match mode {
    "async_join"
    | "async_iteration"
    | "async_deep_iteration"
    | "async_dynamic_iteration"
    | "async_replay"
    | "async_pointstamp"
    | "async_cancellation" => true
    _ => false
  }
  let cluster = if asynchronous {
    @differential.ClusterWorker(
      peer,
      peers,
      async_exchange=AsyncExchange(
        start=fn(value) raise { transport.start_exchange(value) },
        poll=fn() raise { transport.poll_exchange() },
      ),
    )
  } else {
    ClusterWorker(peer, peers, exchange=fn(value) raise {
      transport.exchange(value)
    })
  }
  let mode = match mode {
    "async_join" => "join"
    "async_iteration" => "iteration"
    "async_deep_iteration" => "deep_iteration"
    "async_dynamic_iteration" => "dynamic_iteration"
    "async_replay" => "replay"
    "async_cancellation" => "cancellation"
    "async_pointstamp" => "pointstamp"
    mode => mode
  }
  defer cluster.dispose()
  if mode == "pointstamp" {
    println(pointstamp_iteration(cluster, seed))
    return
  }
  if mode == "cancellation" {
    println(cancellation(cluster, seed))
    return
  }
  if mode == "replay" {
    println(replay(cluster, seed))
    return
  }
  if mode == "dynamic_iteration" {
    let results = []
    for offset in 0..<3 {
      results.push(iteration(cluster, seed + offset, deep=true))
    }
    println(results.join("/"))
    return
  }
  if mode == "iteration" || mode == "deep_iteration" {
    println(iteration(cluster, seed, deep=mode == "deep_iteration"))
    return
  }
  let scope = cluster.scope(
    0L,
    @differential.SummaryDomain::int64(),
    time_codec=@differential.WireCodec::json(),
    summary_codec=@differential.WireCodec::json(),
  )
  let (a, left) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let (b, right) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let left = scope
    .exchange(
      left,
      fn(x) { x.0.to_uint64() },
      data_codec=@differential.WireCodec::json(),
      time_codec=@differential.WireCodec::json(),
      diff_codec=@differential.WireCodec::json(),
    )
    .arrange_by_key()
  let right = scope
    .exchange(
      right,
      fn(x) { x.0.to_uint64() },
      data_codec=@differential.WireCodec::json(),
      time_codec=@differential.WireCodec::json(),
      diff_codec=@differential.WireCodec::json(),
    )
    .arrange_by_key()
  let observed : Map[(Int32, Int32, Int32), Int64] = Map([])
  let probe = left
    .join(right)
    .consolidate()
    .inspect(fn(d, _, r) {
      let key = (d.0, d.1.0, d.1.1)
      observed[key] = observed.get(key).unwrap_or(0L) + r
    })
  left.release()
  right.release()
  let mut random = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0L..<16L {
    for side in 0..<2 {
      for _ in 0..<4 {
        random = random * 1664525U + 1013904223U
        let index = ((random >> 8) % 20U).reinterpret_as_int()
        let origin = ((random >> 16) % peers.reinterpret_as_uint()).reinterpret_as_int()
        let diff = (random % 5U).to_int64() - 2L
        if origin == peer {
          if side == 0 {
            a.update((index / 5, index % 5), diff)
          } else {
            b.update((index / 5, index % 5), diff)
          }
        }
      }
    }
    a.advance_to(epoch + 1)
    b.advance_to(epoch + 1)
    a.flush()
    b.flush()
    guard drive(cluster, max_rounds=1000) is Quiescent(_) else {
      abort("cluster join round limit")
    }
    guard !probe.less_than(epoch + 1) else {
      abort("cluster join progress stalled")
    }
    let current = observed.to_array().filter(fn(x) { x.1 != 0L })
    current.sort()
    results.push(
      current.map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1}" }).join(";"),
    )
  }
  a.close()
  b.close()
  let _ = drive(cluster)
  guard probe.done() else { abort("cluster did not close") }
  println(results.join("/"))
}
