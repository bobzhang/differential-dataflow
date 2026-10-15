///|
/// Explicit counterpart of Timely's Refines association. Functions must preserve
/// the timestamp orders, project(lift(t)) == t, and agree with path-summary
/// composition. User-defined refinements have the same law obligations as lattices.
pub struct Refinement[A, B, S, U] {
  priv lift : (A) -> B
  priv project : (B) -> A
  priv summarize : (U) -> S
}

///|
pub fn[A, B, S, U] Refinement::Refinement(
  lift~ : (A) -> B,
  project~ : (B) -> A,
  summarize~ : (U) -> S,
) -> Refinement[A, B, S, U] {
  { lift, project, summarize, }
}

///|
pub fn[T, S] Refinement::identity() -> Refinement[T, T, S, S] {
  Refinement(lift=fn(time) { time }, project=fn(time) { time }, summarize=fn(
    summary,
  ) {
    summary
  })
}

///|
pub fn[A, B, S, U] Refinement::product(
  minimum : B,
) -> Refinement[A, Product[A, B], S, Product[S, U]] {
  Refinement(
    lift=fn(time) { Product(time, minimum) },
    project=fn(time) { time.outer },
    summarize=fn(summary) { summary.outer },
  )
}

///|
pub fn[A, B, S, U] Refinement::to_inner(
  self : Refinement[A, B, S, U],
  time : A,
) -> B {
  (self.lift)(time)
}

///|
pub fn[A, B, S, U] Refinement::to_outer(
  self : Refinement[A, B, S, U],
  time : B,
) -> A {
  (self.project)(time)
}

///|
pub fn[A, B, S, U] Refinement::summary_to_outer(
  self : Refinement[A, B, S, U],
  summary : U,
) -> S {
  (self.summarize)(summary)
}

///|
pub struct RefinedScope[A, B, S, U] {
  priv outer : Scope[A, S]
  priv inner : Scope[B, U]
  priv refinement : Refinement[A, B, S, U]
}

///|
pub fn[A, B : Lattice, S, U : Compare] Scope::refine(
  self : Scope[A, S],
  domain : SummaryDomain[B, U],
  refinement : Refinement[A, B, S, U],
) -> RefinedScope[A, B, S, U] {
  guard !self.progress.frozen else { abort("parent scope graph is frozen") }
  let inner = self.worker.make_scope(
    refinement.to_inner(self.minimum),
    domain,
    true,
    family=self.progress.family,
  )
  { outer: self, inner, refinement, }
}

///|
/// A nested region with identical timestamps and summaries.
pub fn[T : Lattice, S : Compare] Scope::region(
  self : Scope[T, S],
) -> RefinedScope[T, T, S, S] {
  self.refine(self.domain, Refinement::identity())
}

///|
pub fn[A, B, S, U] RefinedScope::scope(
  self : RefinedScope[A, B, S, U],
) -> Scope[B, U] {
  self.inner
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] RefinedScope::enter(
  self : RefinedScope[A, B, S, U],
  source : Collection[D, A, R],
) -> Collection[D, B, R] {
  let refinement = self.refinement
  self.enter_at(source, fn(_, time) { refinement.to_inner(time) })
}

///|
/// Assign data-dependent refined times, each at or beyond the lifted input time.
/// Progress follows the lifted input frontier, independent of observed data.
pub fn[D, A : Lattice, B : Lattice, R, S, U] RefinedScope::enter_at(
  self : RefinedScope[A, B, S, U],
  source : Collection[D, A, R],
  assign : (D, A) -> B,
) -> Collection[D, B, R] {
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.outer.context) else {
    abort("refinement entry requires a collection in the parent scope")
  }
  let refinement = self.refinement
  let initial = Antichain(
    source.channel.frontier.val.elements.map(fn(time) {
      refinement.to_inner(time)
    }),
  )
  let output : Channel[D, B, R] = Channel(
    self.inner.worker.scheduler,
    initial,
    context=self.inner.context,
  )
  let input : Mailbox[D, A, R] = Mailbox()
  input.task = self.outer.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) => {
          let result = updates.map(fn(update) {
            let time = assign(update.0, update.1)
            guard refinement.to_inner(update.1).less_equal(time) else {
              abort("assigned timestamp precedes refined input capability")
            }
            (update.0, time, update.2)
          })
          output.data(result)
        }
        Progress(_) => ()
      }
    }
  })
  source.channel.subscribe(input)
  self.outer.worker.network.link(
    self.outer.progress,
    input.counter.unwrap().1,
    self.inner.progress,
    output.port,
    fn(time) { refinement.to_inner(time) },
  )
  { worker: self.inner.worker, channel: output, }
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] RefinedScope::leave(
  self : RefinedScope[A, B, S, U],
  source : Collection[D, B, R],
) -> Collection[D, A, R] {
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.inner.context) else {
    abort("refinement exit requires a collection in the child scope")
  }
  let refinement = self.refinement
  let initial = Antichain(
    source.channel.frontier.val.elements.map(fn(time) {
      refinement.to_outer(time)
    }),
  )
  let output : Channel[D, A, R] = Channel(
    self.outer.worker.scheduler,
    initial,
    context=self.outer.context,
  )
  let input : Mailbox[D, B, R] = Mailbox()
  input.task = self.inner.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          output.data(
            updates.map(fn(update) {
              (update.0, refinement.to_outer(update.1), update.2)
            }),
          )
        Progress(_) => ()
      }
    }
  })
  source.channel.subscribe(input)
  self.outer.worker.network.link(
    self.inner.progress,
    input.counter.unwrap().1,
    self.outer.progress,
    output.port,
    fn(time) { refinement.to_outer(time) },
  )
  { worker: self.outer.worker, channel: output, }
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] NestedScope::enter_at(
  self : NestedScope[A, B, S, U],
  source : Collection[D, A, R],
  assign : (D, A) -> B,
) -> Collection[D, Product[A, B], R] {
  let refined : RefinedScope[A, Product[A, B], S, Product[S, U]] = {
    outer: self.outer,
    inner: self.inner,
    refinement: Refinement::product(self.minimum),
  }
  refined.enter_at(source, fn(data, time) { Product(time, assign(data, time)) })
}
