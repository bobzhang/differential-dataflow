///|
test "exclusive prefix sums preserve order sparse locations and query weights" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, source) : (
    @differential.InputSession[((UInt64, Int32), String), Int64, Int64],
    @differential.Collection[((UInt64, Int32), String), Int64, Int64],
  ) = scope.input()
  let (queries, locations) : (
    @differential.InputSession[(UInt64, Int32), Int64, Int64],
    @differential.Collection[(UInt64, Int32), Int64, Int64],
  ) = scope.input()
  let observed : Map[((UInt64, Int32), String), Int64] = Map([])
  let probe = scope
    .prefix_sum_at(source, locations, "", fn(_, a, b) { a + b })
    .inspect(fn(data, _, diff) {
      observed[data] = observed.get(data).unwrap_or(0L) + diff
    })
  input.insert(((0UL, 0), "a"))
  input.insert(((3UL, 0), "b"))
  input.insert(((1UL << 63, 0), "c"))
  for
    location in [
      (0UL, 0),
      (3UL, 0),
      (4UL, 0),
      (0xffff_ffff_ffff_ffffUL, 0),
      (4UL, 1),
    ] {
    queries.update(location, 2L)
  }
  input.advance_to(1)
  queries.advance_to(1)
  input.flush()
  queries.flush()
  assert_true(worker.run() is Quiescent(_))
  assert_true(!probe.less_than(1))
  assert_eq(observed.get(((0UL, 0), "")), Some(2L))
  assert_eq(observed.get(((3UL, 0), "a")), Some(2L))
  assert_eq(observed.get(((4UL, 0), "ab")), Some(2L))
  assert_eq(observed.get(((0xffff_ffff_ffff_ffffUL, 0), "abc")), Some(2L))
  assert_eq(observed.get(((4UL, 1), "")), Some(2L))
  input.remove(((3UL, 0), "b"))
  queries.update((4UL, 0), -1L)
  input.close()
  queries.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  assert_eq(observed.get(((4UL, 0), "ab")), Some(0L))
  assert_eq(observed.get(((4UL, 0), "a")), Some(1L))
  assert_eq(observed.get(((0xffff_ffff_ffff_ffffUL, 0), "abc")), Some(0L))
  assert_eq(observed.get(((0xffff_ffff_ffff_ffffUL, 0), "ac")), Some(2L))
  worker.dispose()
}
