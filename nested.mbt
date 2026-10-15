///|
/// A nested timestamp domain. Enter adds an inner coordinate; leave projects it
/// away while retaining parent progress until all inner work at that time finishes.
pub struct NestedScope[A, B, S, U] {
  priv outer : Scope[A, S]
  priv inner : Scope[Product[A, B], Product[S, U]]
  priv minimum : B
}

///|
pub fn[A : Lattice, B : Lattice, S : Compare, U : Compare] Scope::nested(
  self : Scope[A, S],
  minimum : B,
  domain : SummaryDomain[B, U],
) -> NestedScope[A, B, S, U] {
  let inner = self.worker.scope(
    Product(self.minimum, minimum),
    SummaryDomain::product(self.domain, domain),
  )
  { outer: self, inner, minimum, }
}

///|
pub fn[A, B, S, U] NestedScope::scope(
  self : NestedScope[A, B, S, U],
) -> Scope[Product[A, B], Product[S, U]] {
  self.inner
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] NestedScope::enter(
  self : NestedScope[A, B, S, U],
  source : Collection[D, A, R],
) -> Collection[D, Product[A, B], R] {
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.outer.context) else {
    abort("enter requires a collection in the parent scope")
  }
  let minimum = self.minimum
  let initial = Antichain(
    source.channel.frontier.val.elements.map(fn(time) { Product(time, minimum) }),
  )
  let output : Channel[D, Product[A, B], R] = Channel(
    self.inner.worker.scheduler,
    initial,
    context=self.inner.context,
  )
  let held = Ref(initial)
  for time in initial.elements {
    output.hold(time, 1)
  }
  let input : Mailbox[D, A, R] = Mailbox()
  input.task = self.outer.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          output.data(
            updates.map(fn(update) {
              (update.0, Product(update.1, minimum), update.2)
            }),
          )
        Progress(frontier) => {
          let next = Antichain(
            frontier.elements.map(fn(time) { Product(time, minimum) }),
          )
          for time in next.elements {
            output.hold(time, 1)
          }
          for time in held.val.elements {
            output.hold(time, -1)
          }
          held.val = next
        }
      }
    }
  })
  source.channel.subscribe(input)
  { worker: self.inner.worker, channel: output, }
}

///|
pub fn[D, A : Lattice, B : Lattice, R, S, U] NestedScope::leave(
  self : NestedScope[A, B, S, U],
  source : Collection[D, Product[A, B], R],
) -> Collection[D, A, R] {
  guard source.channel.context is Some(context) &&
    physical_equal(context, self.inner.context) else {
    abort("leave requires a collection in the child scope")
  }
  let initial = Antichain(
    source.channel.frontier.val.elements.map(fn(time) { time.outer }),
  )
  let output : Channel[D, A, R] = Channel(
    self.outer.worker.scheduler,
    initial,
    context=self.outer.context,
  )
  let held = Ref(initial)
  for time in initial.elements {
    output.hold(time, 1)
  }
  let input : Mailbox[D, Product[A, B], R] = Mailbox()
  input.task = self.inner.worker.register(fn() {
    for frame in input.drain() {
      match frame {
        Data(updates) =>
          output.data(
            updates.map(fn(update) { (update.0, update.1.outer, update.2) }),
          )
        Progress(frontier) => {
          let next = Antichain(frontier.elements.map(fn(time) { time.outer }))
          for time in next.elements {
            output.hold(time, 1)
          }
          for time in held.val.elements {
            output.hold(time, -1)
          }
          held.val = next
        }
      }
    }
  })
  source.channel.subscribe(input)
  { worker: self.outer.worker, channel: output, }
}
