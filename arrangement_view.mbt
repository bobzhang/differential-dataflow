///|
/// An arrangement backed by a retained trace view. Entering a scope adapts batch
/// timestamps lazily and preserves the original index and reader compaction pins.
pub struct ArrangementView[K, V, T, R] {
  priv collection : Collection[(K, V), T, R]
  priv trace : TraceReader[(K, V), T, R]
}

///|
pub fn[K : Compare, V : Compare, T : Lattice, R : Semigroup] Arranged::view(
  self : Arranged[K, V, T, R],
) -> ArrangementView[K, V, T, R] {
  { collection: self.collection, trace: self.trace.reader(), }
}

///|
pub fn[K, V, T, R] ArrangementView::trace(
  self : ArrangementView[K, V, T, R],
) -> TraceReader[(K, V), T, R] {
  self.trace.clone()
}

///|
pub fn[K, V, T, R] ArrangementView::as_collection(
  self : ArrangementView[K, V, T, R],
) -> Collection[(K, V), T, R] {
  self.collection
}

///|
pub fn[K, V, T, R] ArrangementView::release(
  self : ArrangementView[K, V, T, R],
) -> Unit {
  self.trace.release()
}

///|
pub fn[K, V, A : Lattice, B : Lattice, R, S, U] ArrangementView::enter(
  self : ArrangementView[K, V, A, R],
  nested : NestedScope[A, B, S, U],
) -> ArrangementView[K, V, Product[A, B], R] {
  {
    collection: nested.enter(self.collection),
    trace: self.trace.enter(nested.minimum),
  }
}

///|
pub fn[K : Compare, V : Compare, A : Lattice, B : Lattice, R : Semigroup, S, U] Arranged::enter(
  self : Arranged[K, V, A, R],
  nested : NestedScope[A, B, S, U],
) -> ArrangementView[K, V, Product[A, B], R] {
  let view = self.view()
  defer view.release()
  view.enter(nested)
}

///|
pub fn[K, V, A : Lattice, B : Lattice, R, S, U] ArrangementView::enter_refined(
  self : ArrangementView[K, V, A, R],
  nested : RefinedScope[A, B, S, U],
) -> ArrangementView[K, V, B, R] {
  let refinement = nested.refinement
  {
    collection: nested.enter(self.collection),
    trace: self.trace.refine(lift=fn(time) { refinement.to_inner(time) }, project=fn(
      time,
    ) {
      refinement.to_outer(time)
    }),
  }
}

///|
/// Enter at a data-dependent inner time while retaining the original index.
/// prior maps inner compaction capabilities conservatively into outer time.
pub fn[K, V, A : Lattice, B : Lattice, R, S, U] ArrangementView::enter_at(
  self : ArrangementView[K, V, A, R],
  nested : NestedScope[A, B, S, U],
  assign : ((K, V), A) -> B,
  prior : (Product[A, B]) -> A,
) -> ArrangementView[K, V, Product[A, B], R] {
  let minimum = nested.minimum
  {
    collection: nested.enter_at(self.collection, assign),
    trace: self.trace.refine_at(
      lift=fn(time) { Product(time, minimum) },
      project=fn(time) { time.outer },
      assign=fn(data, time) { Product(time, assign(data, time)) },
      prior~,
    ),
  }
}

///|
pub fn[K : Compare, V : Compare, A : Lattice, B : Lattice, R : Semigroup, S, U] Arranged::enter_at(
  self : Arranged[K, V, A, R],
  nested : NestedScope[A, B, S, U],
  assign : ((K, V), A) -> B,
  prior : (Product[A, B]) -> A,
) -> ArrangementView[K, V, Product[A, B], R] {
  let view = self.view()
  defer view.release()
  view.enter_at(nested, assign, prior)
}

///|
pub fn[K : Compare, V : Compare, A : Lattice, B : Lattice, R : Semigroup, S, U] Arranged::enter_refined(
  self : Arranged[K, V, A, R],
  nested : RefinedScope[A, B, S, U],
) -> ArrangementView[K, V, B, R] {
  let view = self.view()
  defer view.release()
  view.enter_refined(nested)
}
