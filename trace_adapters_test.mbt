///|
priv struct ExternalStore {
  batches : Array[@differential.BatchView[(Int32, Int32), Int64, Int64]]
  mut upper : @differential.Antichain[Int64]
  pins : Map[
    Int32,
    (@differential.Antichain[Int64], @differential.Antichain[Int64]),
  ]
  listeners : Map[
    Int32,
    (@differential.BatchView[(Int32, Int32), Int64, Int64]) -> Unit,
  ]
  mut next : Int32
  mut close_calls : Int32
  mut builds : Int32
}

///|
fn ExternalStore::ExternalStore() -> ExternalStore {
  {
    batches: [],
    upper: Antichain([0L]),
    pins: Map([]),
    listeners: Map([]),
    next: 0,
    close_calls: 0,
    builds: 0,
  }
}

///|
fn ExternalStore::reader(
  self : ExternalStore,
) -> @differential.TraceReader[(Int32, Int32), Int64, Int64] {
  self.reader_at(Antichain([0L]), Antichain([0L]))
}

///|
fn ExternalStore::reader_at(
  self : ExternalStore,
  logical : @differential.Antichain[Int64],
  physical : @differential.Antichain[Int64],
) -> @differential.TraceReader[(Int32, Int32), Int64, Int64] {
  self.next += 1
  let id = self.next
  self.pins[id] = (logical, physical)
  TraceReader(
    clone_reader=fn() { self.reader_at(self.pins[id].0, self.pins[id].1) },
    release_reader=fn() { self.pins.remove(id) },
    upper=fn() { Antichain(self.upper.to_array()) },
    logical_compaction=fn() { Antichain(self.pins[id].0.to_array()) },
    physical_compaction=fn() { Antichain(self.pins[id].1.to_array()) },
    set_logical_compaction=fn(frontier) {
      guard self.pins[id].0.precedes(frontier) else {
        abort("logical pin regressed")
      }
      self.pins[id] = (frontier, self.pins[id].1)
    },
    set_physical_compaction=fn(frontier) {
      guard self.pins[id].1.precedes(frontier) else {
        abort("physical pin regressed")
      }
      self.pins[id] = (self.pins[id].0, frontier)
    },
    batches_through=fn(cut) {
      if !self.pins[id].1.precedes(cut) {
        return None
      }
      if cut.is_empty() {
        return Some(self.batches.copy())
      }
      if cut.to_array() == [0L] {
        return Some([])
      }
      let result = []
      for batch in self.batches {
        result.push(batch)
        if batch.description().upper().to_array() == cut.to_array() {
          return Some(result)
        }
      }
      None
    },
    subscribe=fn(notify) {
      self.next += 1
      let listener = self.next
      self.listeners[listener] = notify
      fn() { self.listeners.remove(listener) }
    },
  )
}

///|
fn ExternalStore::insert(
  self : ExternalStore,
  batch : @differential.BatchView[(Int32, Int32), Int64, Int64],
) -> Unit {
  guard batch.description().lower().to_array() == self.upper.to_array() else {
    abort("custom backend received a noncontiguous batch")
  }
  self.batches.push(batch)
  self.upper = batch.description().upper()
  for _, notify in self.listeners {
    notify(batch)
  }
}

///|
fn ExternalStore::backend(
  self : ExternalStore,
) -> @differential.TraceBackend[(Int32, Int32), Int64, Int64] {
  TraceBackend(
    self.reader(),
    insert=fn(batch) { self.insert(batch) },
    close=fn() {
      self.close_calls += 1
      if !self.upper.is_empty() {
        self.insert(
          BatchView(
            0,
            Description(self.upper, Antichain([]), Antichain([0L])),
            read=fn(_) { abort("empty batch must not be read") },
          ),
        )
      }
    },
    // Store rows in four independent columns to exercise a truly external layout.
    build=fn(rows, description) {
      self.builds += 1
      let keys = rows.map(fn(r) { r.0.0 })
      let values = rows.map(fn(r) { r.0.1 })
      let times = rows.map(fn(r) { r.1 })
      let diffs = rows.map(fn(r) { r.2 })
      BatchView(rows.length(), description, read=fn(i) {
        ((keys[i], values[i]), times[i], diffs[i])
      })
    },
  )
}

///|
test "external trace backend supports shared joins reductions and live imports" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let store = ExternalStore()
  let arranged = source.arrange_with(fn(_) { store.backend() })
  let reference = source.arrange_by_key()
  let custom_join = []
  let builtin_join = []
  let p = arranged
    .join(arranged)
    .inspect(fn(d, t, r) { custom_join.push((d, t, r)) })
  let q = reference
    .join(reference)
    .inspect(fn(d, t, r) { builtin_join.push((d, t, r)) })
  let custom_reduce = []
  let builtin_reduce = []
  let logic = fn(_ : Int32, values : Array[(Int32, Int64)]) {
    [(values[0].0, 1L)]
  }
  let _ = arranged
    .reduce(logic)
    .inspect(fn(d, t, r) { custom_reduce.push((d, t, r)) })
  let _ = reference
    .reduce(logic)
    .inspect(fn(d, t, r) { builtin_reduce.push((d, t, r)) })
  let reader = arranged.trace()
  arranged.release()
  reference.release()
  let mut state = 42U
  for epoch in 0L..<24L {
    for _ in 0..<5 {
      state = state * 1664525U + 1013904223U
      let i = ((state >> 8) % 20U).reinterpret_as_int()
      input.update((i / 5, i % 5), (state % 5U).to_int64() - 2L)
    }
    input.advance_to(epoch + 1L)
    input.flush()
    let _ = worker.run()
    assert_false(p.less_than(epoch + 1L) || q.less_than(epoch + 1L))
    assert_eq(
      @differential.consolidate_updates(custom_join),
      @differential.consolidate_updates(builtin_join),
    )
    assert_eq(
      @differential.consolidate_updates(custom_reduce),
      @differential.consolidate_updates(builtin_reduce),
    )
    let query_scope = worker.scope(0L, @differential.SummaryDomain::int64())
    let imported = reader.import_arranged(query_scope)
    let values = []
    let probe = imported
      .as_collection()
      .inspect(fn(d, t, r) { values.push((d, t, r)) })
    imported.release()
    let _ = worker.run()
    assert_false(probe.less_than(epoch + 1L))
    let expected = reader.snapshot(epoch)
    let actual = @differential.consolidate(
      values.filter(fn(r) { r.1 <= epoch }).map(fn(r) { (r.0, r.2) }),
    )
    assert_eq(actual, expected)
    worker.drop_dataflow(query_scope.dataflow_index())
  }
  input.close()
  let _ = worker.run()
  assert_true(p.done() && q.done())
  assert_eq(store.close_calls, 1)
  assert_true(store.builds >= 24)
  reader.release()
  worker.dispose()
  assert_true(store.pins.is_empty())
  assert_true(store.listeners.is_empty())
}

///|
test "custom trace writer closure completes surviving imports on producer cancellation" {
  let producer = @differential.Worker()
  let scope = producer.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let store = ExternalStore()
  let arranged = source.arrange_with(fn(_) { store.backend() })
  let reader = arranged.trace()
  arranged.release()
  input.insert((1, 2))
  input.advance_to(1L)
  input.flush()
  let _ = producer.run()
  let consumer = @differential.Worker()
  let consumer_scope = consumer.scope(0L, @differential.SummaryDomain::int64())
  let imported = reader.import_arranged(consumer_scope)
  let seen = []
  let probe = imported
    .as_collection()
    .inspect(fn(d, _, r) { seen.push((d, r)) })
  imported.release()
  let _ = consumer.run()
  assert_false(probe.done())
  producer.drop_dataflow(scope.dataflow_index())
  let _ = consumer.run()
  assert_true(probe.done())
  assert_eq(seen, [((1, 2), 1L)])
  assert_eq(store.close_calls, 1)
  reader.release()
  input.close()
  producer.dispose()
  consumer.dispose()
  assert_true(store.pins.is_empty() && store.listeners.is_empty())
}
