///|
/// Reduce directly from a shared arrangement. Input history stays in the shared
/// index; per-key state retains only output history and unfinished corrections.
/// Logic is recomputed only for changed keys, and its input is a copied snapshot.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Abelian,
] Arranged::reduce(
  self : Arranged[K, V, T, R],
  logic : (K, Array[(V, R)]) -> Array[(W, S)],
) -> Collection[(K, W), T, S] {
  let view = self.view()
  defer view.release()
  view.reduce(logic)
}

///|
/// Retain the reduced output as a shared index for downstream joins or reductions.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Abelian,
] Arranged::reduce_arranged(
  self : Arranged[K, V, T, R],
  logic : (K, Array[(V, R)]) -> Array[(W, S)],
) -> Arranged[K, W, T, S] {
  self.reduce(logic).arrange_by_key()
}

///|
/// Compute semigroup output corrections from a shared arrangement. Input history
/// remains in the shared index; the callback receives sorted snapshot copies.
pub fn[
  K : Compare + Hash,
  V : Compare,
  W : Compare,
  T : Lattice,
  R : Semigroup,
  S : Semigroup,
] Arranged::reduce_core(
  self : Arranged[K, V, T, R],
  logic : (K, Array[(V, R)], Array[(W, S)]) -> Array[(W, S)],
) -> Arranged[K, W, T, S] {
  let view = self.view()
  defer view.release()
  view.reduce_core(logic)
}
