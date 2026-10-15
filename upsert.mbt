///|
/// Convert timestamped upserts to a differential arrangement. At equal key/time,
/// Some wins over None, and the greatest present value wins, matching upstream.
/// Upserts require a total timestamp order; repeated values produce no changes.
pub fn[K : Compare + Hash, V : Compare, T : TotalOrder] Collection::arrange_from_upsert(
  self : Collection[(K, V?), T, Present],
) -> Arranged[K, V, T, Int64] {
  let output : Channel[(K, V), T, Int64] = self.channel.output()
  let input : Mailbox[(K, V?), T, Present] = Mailbox()
  let pending : Ref[Array[((K, V?), T, Present)]] = Ref([])
  let current : Map[K, V] = Map([])
  input.task = self.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Records(_, updates) =>
          for update in updates {
            pending.val.push(update)
            output.hold(update.1, 1)
          }
        Progress(frontier) => {
          let ready = []
          let retained = []
          for update in pending.val {
            if frontier.less_equal(update.1) {
              retained.push(update)
            } else {
              ready.push(update)
            }
          }
          pending.val = retained
          ready.sort_by(fn(a, b) {
            let order = Compare::compare(a.1, b.1)
            if order != 0 {
              return order
            }
            let order = Compare::compare(a.0.0, b.0.0)
            if order != 0 {
              return order
            }
            a.0.1.compare(b.0.1)
          })
          let changes = []
          let mut index = 0
          while index < ready.length() {
            let ((key, _), time, _) = ready[index]
            let mut end = index + 1
            while end < ready.length() &&
                  ready[end].0.0 == key &&
                  ready[end].1 == time {
              end += 1
            }
            let next = ready[end - 1].0.1
            let old = current.get(key)
            if old != next {
              if old is Some(value) {
                changes.push(((key, value), time, -1L))
              }
              match next {
                Some(value) => {
                  current[key] = value
                  changes.push(((key, value), time, 1L))
                }
                None => current.remove(key)
              }
            }
            index = end
          }
          output.data(changes)
          for (_, time, _) in ready {
            output.hold(time, -1)
          }
          output.progress(frontier)
          if frontier.is_empty() {
            current.clear()
          }
        }
      }
    }
  })
  self.channel.subscribe(input)
  output.depends_on(input)
  let collection : Collection[(K, V), T, Int64] = {
    worker: self.worker,
    channel: output,
  }
  collection.arrange_by_key()
}
