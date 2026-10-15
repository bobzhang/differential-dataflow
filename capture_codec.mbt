///|
/// A versioned JSON envelope for capture protocol messages. Explicit component
/// codecs preserve custom timestamps and exact integer widths. This is the
/// MoonBit capture format, not Rust serde's binary representation.
pub fn[D, T : Lattice, R] CaptureMessage::codec(
  data : WireCodec[D],
  time : WireCodec[T],
  diff : WireCodec[R],
) -> WireCodec[CaptureMessage[D, T, R]] {
  WireCodec(
    encode=fn(message) {
      match message {
        Updates(updates) =>
          [
            "moon-differential-capture/1",
            "updates",
            Json(
              updates.map(fn(u) {
                (
                  [data.to_json(u.0), time.to_json(u.1), diff.to_json(u.2)] :
                  Json)
              }),
            ),
          ]
        Progress(progress) =>
          [
            "moon-differential-capture/1",
            "progress",
            Json(progress.lower.elements.map(fn(t) { time.to_json(t) })),
            Json(progress.upper.elements.map(fn(t) { time.to_json(t) })),
            Json(
              progress.counts.map(fn(c) {
                ([time.to_json(c.0), Json(c.1)] : Json)
              }),
            ),
          ]
      }
    },
    decode=fn(json) {
      match json {
        [String("moon-differential-capture/1"), String("updates"), Array(rows)] => {
          let updates = []
          for row in rows {
            guard row is [d, t, r] &&
              data.from_json(d) is Some(d) &&
              time.from_json(t) is Some(t) &&
              diff.from_json(r) is Some(r) else {
              return None
            }
            updates.push((d, t, r))
          }
          Some(Updates(updates))
        }
        [
          String("moon-differential-capture/1"),
          String("progress"),
          Array(lo),
          Array(hi),
          Array(rows),
        ] => {
          let lower = []
          let upper = []
          for t in lo {
            guard time.from_json(t) is Some(t) else { return None }
            lower.push(t)
          }
          for t in hi {
            guard time.from_json(t) is Some(t) else { return None }
            upper.push(t)
          }
          let lower = Antichain(lower)
          let upper = Antichain(upper)
          guard lower.precedes(upper) else { return None }
          let counts = []
          let times = []
          for row in rows {
            guard row is [t, c] && time.from_json(t) is Some(t) else {
              return None
            }
            let count : Int64 = @json.from_json(c) catch { _ => return None }
            guard count > 0 &&
              lower.less_equal(t) &&
              !upper.less_equal(t) &&
              !times.contains(t) else {
              return None
            }
            times.push(t)
            counts.push((t, count))
          }
          Some(Progress(CaptureProgress(lower, upper, counts)))
        }
        _ => None
      }
    },
  )
}
