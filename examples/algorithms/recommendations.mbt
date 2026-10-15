///|
/// Upstream itembased_cf.rs, with an exact Jaccard fraction in place of its final
/// floating point score. Input is a set of (user,item) interactions. The result
/// ((item_a,item_b),(intersection,union)) includes scores strictly above 0.05.
pub fn[T : @differential.Lattice] recommendations(
  interactions : @differential.Collection[(Int32, Int32), T, Int64],
  max_interactions~ : Int64 = 500L,
) -> @differential.Collection[((Int32, Int32), (Int64, Int64)), T, Int64] {
  let users = interactions
    .map(fn(row) { row.0 })
    .count()
    .filter(fn(row) { row.1 < max_interactions })
    .map(fn(row) { row.0 })
  let remaining = interactions.semijoin(users)
  let counts = remaining.map(fn(row) { row.1 }).count().arrange_by_key()
  let arranged = remaining.arrange_by_key()
  let cooccurrences = arranged
    .join_map(arranged, fn(_, a, b) { (a, b) }, multiply=fn(a, b) { a * b })
    .filter(fn(pair) { pair.0 > pair.1 })
    .count()
  let by_first = cooccurrences
    .map(fn(row) { (row.0.0, (row.0.1, row.1)) })
    .arrange_by_key()
  let with_first = by_first
    .join_map(counts, fn(a, pair, count) { (pair.0, (a, pair.1, count)) }, multiply=fn(
      a,
      b,
    ) {
      a * b
    })
    .arrange_by_key()
  let scores = with_first
    .join_map(
      counts,
      fn(b, row, count) { ((row.0, b), (row.1, row.2 + count - row.1)) },
      multiply=fn(a, b) { a * b },
    )
    .filter(fn(row) { row.1.0 * 20L > row.1.1 })
  arranged.release()
  by_first.release()
  with_first.release()
  counts.release()
  scores
}
