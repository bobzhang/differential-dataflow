///|
#export_name("evaluate_upsert")
pub fn evaluate_upsert(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, updates) : (
    @differential.InputSession[(Int32, Int32?), Int64, @differential.Present],
    @differential.Collection[(Int32, Int32?), Int64, @differential.Present],
  ) = scope.input()
  let arranged = updates.arrange_from_upsert()
  arranged.release()
  let observed = []
  let probe = arranged
    .as_collection()
    .inspect(fn(d, t, r) { observed.push((d, t, r)) })
  let mut random = seed.reinterpret_as_uint()
  for _ in 0..<64 {
    random = random * 1664525U + 1013904223U
    let index = ((random >> 8) % 256U).reinterpret_as_int()
    input.update_at(
      (index / 64, if random % 4U == 0U { None } else { Some(index % 8) }),
      (index / 8 % 8).to_int64(),
      Present,
    )
  }
  input.close()
  guard worker.run() is Quiescent(_) && probe.done() else {
    abort("upsert progress stalled")
  }
  worker.dispose()
  @differential.consolidate_updates(observed)
  .map(fn(u) { "\{u.0.0},\{u.0.1},\{u.1},\{u.2}" })
  .join(";")
}
