///|
#export_name("evaluate_replay")
pub fn evaluate_replay(seed : Int32) -> String {
  let mut random = seed.reinterpret_as_uint()
  let messages : Array[@differential.CaptureMessage[Int32, Int64, Int64]] = []
  for epoch in 0L..<8L {
    random = random * 1664525U + 1013904223U
    let data = ((random >> 8) % 11U).reinterpret_as_int()
    let diff = (random % 3U + 1U).to_int64()
    messages.push(Updates([(data, epoch, diff), (data + 20, epoch, -diff)]))
    messages.push(
      Progress(
        CaptureProgress(Antichain([epoch]), Antichain([epoch + 1]), [
          (epoch, 2L),
        ]),
      ),
    )
  }
  messages.push(Progress(CaptureProgress(Antichain([8L]), Antichain([]), [])))
  let delivery = messages + messages
  for index in 1..<delivery.length() {
    random = random * 1664525U + 1013904223U
    let other = (random % (index + 1).reinterpret_as_uint()).reinterpret_as_int()
    let temporary = delivery[index]
    delivery[index] = delivery[other]
    delivery[other] = temporary
  }
  let replayer : @differential.Replayer[Int32, Int64, Int64] = Replayer(0)
  let result = []
  for message in delivery {
    if replayer.push(message) is Some((updates, frontier)) {
      let data = updates.map(fn(u) { "\{u.0},\{u.1},\{u.2}" }).join(";")
      let times = frontier.to_array().map(fn(t) { "\{t}" }).join(",")
      result.push("\{data}|\{times}")
    }
  }
  result.join("/")
}
