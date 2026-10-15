///|
test "identifier collision resolution preserves weights and repairs after deletion" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let observed : Map[(Int32, UInt64), Int64] = Map([])
  let probe = scope
    .identifiers_with(source, fn(round, value) {
      ((round + value) / 4).to_uint64()
    })
    .inspect(fn(data, _, diff) {
      observed[data] = observed.get(data).unwrap_or(0L) + diff
    })
  for value in 1..<=5 {
    input.update(value, value.to_int64())
  }
  input.advance_to(1)
  input.flush()
  assert_true(worker.run() is Quiescent(_))
  assert_true(!probe.less_than(1))
  let rows = observed.to_array().filter(fn(x) { x.1 != 0L })
  assert_eq(rows.length(), 5)
  let used : Map[UInt64, Bool] = Map([])
  for ((value, id), weight) in rows {
    assert_eq(weight, value.to_int64())
    assert_true(!used.contains(id))
    used[id] = true
  }
  input.remove(1)
  input.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  let rows = observed.to_array().filter(fn(x) { x.1 != 0L })
  assert_eq(rows.length(), 4)
  used.clear()
  for ((value, id), weight) in rows {
    assert_true(value != 1)
    assert_eq(weight, value.to_int64())
    assert_true(!used.contains(id))
    used[id] = true
  }
  worker.dispose()
}

///|
test "FNV hashing uses upstream numeric and UTF8 field encodings" {
  let hasher = @differential.FnvHasher()
  assert_eq(hasher.finish(), 0xcbf29ce484222325UL)
  hasher.write(b"hello")
  assert_eq(hasher.finish(), 0xa430d84680aabd0bUL)
  assert_eq(@differential.rust_hash((1, 2U)), @differential.rust_hash((1U, 2)))
  assert_true(
    @differential.rust_hash("ab") != @differential.rust_hash(("a", "b")),
  )
}
