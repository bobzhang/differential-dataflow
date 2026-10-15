///|
/// Adapted from upstream hello.rs/degrees.rs: count sources, then count degrees.
pub fn[T : @differential.Lattice] degree_histogram(
  edges : @differential.Collection[(Int32, Int32), T, Int64],
) -> @differential.Collection[(Int64, Int64), T, Int64] {
  edges.map(fn(edge) { edge.0 }).count().map(fn(entry) { entry.1 }).count()
}
