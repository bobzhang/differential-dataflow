///|
fn main {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, edges) : (
    @differential.InputSession[(Int32, Int32), Int64, Int64],
    @differential.Collection[(Int32, Int32), Int64, Int64],
  ) = scope.input()
  let ranks : Map[Int32, Int64] = Map([])
  let degrees : Map[(Int64, Int64), Int64] = Map([])
  let scores : Map[((Int32, Int32), (Int64, Int64)), Int64] = Map([])
  let p1 = @algorithms.pagerank(scope, edges).inspect(fn(d, _, r) {
    ranks[d] = ranks.get(d).unwrap_or(0L) + r
  })
  let p2 = @algorithms.degree_histogram(edges).inspect(fn(d, _, r) {
    degrees[d] = degrees.get(d).unwrap_or(0L) + r
  })
  let p3 = @algorithms.recommendations(edges).inspect(fn(d, _, r) {
    scores[d] = scores.get(d).unwrap_or(0L) + r
  })
  for (a, b) in [(0, 1), (0, 2), (1, 2), (2, 0), (2, 3), (3, 0)] {
    input.insert((a, b))
  }
  for epoch in 0L..<3L {
    if epoch == 1 {
      input.remove((2, 0))
      input.insert((1, 3))
    }
    if epoch == 2 {
      input.insert((3, 2))
    }
    input.advance_to(epoch + 1)
    input.flush()
    let _ = worker.run()
    guard !p1.less_than(epoch + 1) &&
      !p2.less_than(epoch + 1) &&
      !p3.less_than(epoch + 1) else {
      abort("example did not complete")
    }
    let rank = ranks.to_array().filter(fn(row) { row.1 != 0L })
    rank.sort()
    let degree = degrees.to_array().filter(fn(row) { row.1 != 0L })
    degree.sort()
    let score = scores.to_array().filter(fn(row) { row.1 != 0L })
    score.sort()
    println(Json((epoch, rank, degree, score)).stringify())
  }
  input.close()
  let _ = worker.run()
  worker.dispose()
}
