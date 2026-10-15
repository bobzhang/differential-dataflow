///|
test "tuple scaling supports heterogeneous associated output types" {
  let values = (
    @differential.Present,
    @differential.VectorDiff([1L, -2L]),
    @differential.SingletonDiff(3),
    (),
  )
  let result = @differential.scale_quad(
    values,
    4L,
    first=fn(present, scalar) { present.multiply(scalar) },
    second=fn(vector, scalar) {
      vector.scale(scalar, fn(value, scale) { value * scale })
    },
    third=fn(singleton, scalar) {
      singleton.scale(scalar, fn(value, scale) { value.to_int64() * scale })
    },
    fourth=fn(value, scalar) { @differential.scale_unit(value, scalar) },
  )
  assert_eq(result.0, 4L)
  assert_eq(result.1.to_array(), [4L, -8L])
  assert_eq(result.2.value(), 12L)
  assert_eq(result.3, ())
  assert_eq(
    @differential.scale_triple(
      (1, 2L, 3.0),
      2,
      first=fn(a, b) { a * b },
      second=fn(a, b) { a * b.to_int64() },
      third=fn(a, b) { a * b.to_double() },
    ),
    (2, 4L, 6.0),
  )
}

///|
test "tuple weights scale through streaming joins and retractions" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (a, left) : (
    @differential.InputSession[(Int32, Int32), Int64, (Int64, Int64)],
    @differential.Collection[(Int32, Int32), Int64, (Int64, Int64)],
  ) = scope.input()
  let (b, right) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let totals = Ref((0L, 0L))
  let probe = left
    .join_map(right, fn(k, v, w) { (k, v + w) }, multiply=fn(pair, scalar) {
      @differential.scale_pair(pair, scalar, first=fn(x, y) { x * y }, second=fn(
        x,
        y,
      ) {
        x * y
      })
    })
    .inspect(fn(_, _, diff) {
      totals.val = (totals.val.0 + diff.0, totals.val.1 + diff.1)
    })
  a.update((1, 2), (2L, 3L))
  b.update((1, 4), 5L)
  a.advance_to(1L)
  b.advance_to(1L)
  a.flush()
  b.flush()
  let _ = worker.run()
  assert_eq(totals.val, (10L, 15L))
  a.update((1, 2), (-2L, -3L))
  a.close()
  b.close()
  let _ = worker.run()
  assert_eq(totals.val, (0L, 0L))
  assert_true(probe.done())
  worker.dispose()
}
