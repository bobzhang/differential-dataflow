///|
#export_name("evaluate_reduce")
pub fn evaluate_reduce(seed : Int32) -> String {
  reduce_case(seed, false)
}

///|
#export_name("evaluate_scope_reduce")
pub fn evaluate_scope_reduce(seed : Int32) -> String {
  reduce_case(seed, true)
}

///|
fn reduce_case(seed : Int32, counted : Bool) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(
    @differential.Product(0L, 0L),
    @differential.SummaryDomain::product(
      @differential.SummaryDomain::int64(),
      @differential.SummaryDomain::int64(),
    ),
  )
  let (input, collection) : (
    @differential.InputSession[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
    @differential.Collection[
      (Int32, Int32),
      @differential.Product[Int64, Int64],
      Int64,
    ],
  ) = if counted { scope.input() } else { worker.input(Product(0, 0)) }
  let observed : Array[
    ((Int32, Int32, Int64), @differential.Product[Int64, Int64], Int64),
  ] = []
  let p0 = collection
    .map(fn(x) { x.0 })
    .distinct()
    .inspect(fn(k, t, d) { observed.push(((0, k, 0L), t, d)) })
  let p1 = collection
    .map(fn(x) { x.0 })
    .count()
    .inspect(fn(x, t, d) { observed.push(((1, x.0, x.1), t, d)) })
  let p2 = collection
    .reduce(fn(_, values) { [(values[0].0, 1L)] })
    .inspect(fn(x, t, d) { observed.push(((2, x.0, x.1.to_int64()), t, d)) })
  let mut random = seed.reinterpret_as_uint()
  for _ in 0..<32 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 375U).reinterpret_as_int()
    input.update_at(
      (index / 125, index % 5),
      Product((index / 25 % 5).to_int64(), (index / 5 % 5).to_int64()),
      (random % 5U).to_int64() - 2L,
    )
  }
  input.close()
  guard worker.run() is Quiescent(_) && p0.done() && p1.done() && p2.done() else {
    abort("reduction progress stalled")
  }
  worker.dispose()
  @differential.consolidate_updates(observed)
  .map(fn(x) { "\{x.0.0},\{x.0.1},\{x.0.2},\{x.1.outer},\{x.1.inner},\{x.2}" })
  .join(";")
}
