///|
#export_name("evaluate_examples")
pub fn evaluate_examples(seed : Int32) -> String {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, edges) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let ranks : Map[Int32, Int64] = Map([])
  let degrees : Map[(Int64, Int64), Int64] = Map([])
  let scores : Map[((Int32, Int32), (Int64, Int64)), Int64] = Map([])
  let p1 = @algorithms.pagerank(
    scope,
    edges,
    iterations=(seed % 5 + 1).to_int64(),
  ).inspect(fn(d, _, r) { ranks[d] = ranks.get(d).unwrap_or(0L) + r })
  let p2 = @algorithms.degree_histogram(edges).inspect(fn(d, _, r) {
    degrees[d] = degrees.get(d).unwrap_or(0L) + r
  })
  let p3 = @algorithms.recommendations(edges, max_interactions=4L).inspect(fn(
    d,
    _,
    r,
  ) {
    scores[d] = scores.get(d).unwrap_or(0L) + r
  })
  let active : Set[(Int32, Int32)] = Set([])
  let mut random = seed.reinterpret_as_uint()
  let results = []
  for epoch in 0..<12 {
    if epoch == 11 {
      for edge in active {
        input.remove(edge)
      }
      active.clear()
    } else if epoch != 0 {
      for _ in 0..<10 {
        random = random * 1664525U + 1013904223U
        let index = ((random >> 8) % 64U).reinterpret_as_int()
        let edge = (index / 8, index % 8)
        if active.contains(edge) {
          active.remove(edge)
          input.remove(edge)
        } else {
          active.add(edge)
          input.insert(edge)
        }
      }
    }
    input.advance_to(epoch.to_int64() + 1)
    input.flush()
    let _ = worker.run()
    guard !p1.less_than(epoch.to_int64() + 1) &&
      !p2.less_than(epoch.to_int64() + 1) &&
      !p3.less_than(epoch.to_int64() + 1) else {
      abort("example progress stalled")
    }
    let rank = ranks.to_array().filter(fn(row) { row.1 != 0L })
    let degree = degrees.to_array().filter(fn(row) { row.1 != 0L })
    let score = scores.to_array().filter(fn(row) { row.1 != 0L })
    rank.sort()
    degree.sort()
    score.sort()
    results.push(
      rank.map(fn(r) { "\{r.0},\{r.1}" }).join(";") +
      "|" +
      degree.map(fn(r) { "\{r.0.0},\{r.0.1},\{r.1}" }).join(";") +
      "|" +
      score
      .map(fn(r) { "\{r.0.0.0},\{r.0.0.1},\{r.0.1.0},\{r.0.1.1},\{r.1}" })
      .join(";"),
    )
  }
  input.close()
  let _ = worker.run()
  guard p1.done() && p2.done() && p3.done() else {
    abort("examples did not close")
  }
  worker.dispose()
  results.join("/")
}
