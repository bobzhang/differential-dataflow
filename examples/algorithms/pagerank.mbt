///|
/// Integer surfer PageRank from upstream pagerank.rs. This keeps the original
/// six-million initialization and one-million reset weights. iterations must be
/// positive; the example explicitly bounds the inner feedback coordinate.
pub fn pagerank(
  scope : @differential.Scope[Int64, Int64],
  edges : @differential.Collection[(Int32, Int32), Int64, Int64],
  iterations~ : Int64 = 4L,
) -> @differential.Collection[Int32, Int64, Int64] {
  guard iterations > 0 else {
    abort("PageRank iteration count must be positive")
  }
  let nodes = edges.flat_map(fn(edge) { [edge.0, edge.1] }).distinct()
  let degrees = edges.map(fn(edge) { edge.0 }).count()
  let nested = scope.nested(0L, @differential.SummaryDomain::int64())
  let inner = nested.scope()
  let edges = nested.enter(edges)
  let nodes = nested.enter(nodes)
  let degrees = nested.enter(degrees)
  let initial = nodes.explode(fn(node) {
    [(node, fn(weight) { weight * 6000000L })]
  })
  let reset = nodes.explode(fn(node) {
    [(node, fn(weight) { weight * 1000000L })]
  })
  let (variable, ranks) = inner.variable_from(initial, Product(0L, 1L))
  let to_push = degrees
    .semijoin(ranks)
    .threshold(fn(row, rank) { 5L * rank / (6L * row.1) })
    .map(fn(row) { row.0 })
  let pushed = edges
    .semijoin(to_push)
    .map(fn(edge) { edge.1 })
    .concat(reset)
    .consolidate()
  let bounded = inner.unary(pushed, fn(output, initial) {
    initial.release()
    fn(event) {
      if event is Data(capability, records) {
        if capability.time().inner < iterations {
          output.send(capability, records)
        }
      }
    }
  })
  variable.set(bounded)
  nested.leave(bounded)
}
