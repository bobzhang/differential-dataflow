///|
test "compacted cancellation releases join index keys" {
  let state : Map[Int32, Array[(Int32, Int64, Int64)]] = Map([])
  for key in 0..<1000 {
    state[key] = [(1, 0L, 1L), (1, 1L, -1L)]
  }
  compact_join_state(state, Antichain([2L]))
  assert_true(state.is_empty())
}

///|
test "continuously active scheduler keeps bounded queue storage" {
  let worker = Worker()
  let scheduler = worker.scheduler
  let counters = [0, 0]
  let max_size = Ref(0)
  for index in 0..<2 {
    let _ = worker.register(fn() {
      if counters[index] < 3000 {
        counters[index] += 1
        scheduler.schedule(index)
      }
      if scheduler.queue.length() > max_size.val {
        max_size.val = scheduler.queue.length()
      }
    })
  }
  scheduler.schedule(0)
  scheduler.schedule(1)
  assert_eq(worker.run(), Quiescent(6002))
  assert_true(max_size.val <= 1025)
  assert_true(scheduler.queue.is_empty())
}
