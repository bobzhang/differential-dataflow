///|
/// Observe progress jointly across multiple collections. The handle's frontier
/// is the union of their frontiers; it completes only after every attached stream.
pub fn[D, T : Lattice, R] Collection::probe_with(
  self : Collection[D, T, R],
  probe : Probe[T],
) -> Collection[D, T, R] {
  let state = Ref(Antichain(self.channel.frontier.val.elements))
  probe.states.push(state)
  self.inspect_container(fn(event) {
    if event is Frontier(frontier) {
      state.val = frontier
    }
  })
}

///|
/// Mutable record transformation. The reference holds the current record and its
/// replacement; logical time and difference are unchanged.
pub fn[D, T : Lattice, R] Collection::map_in_place(
  self : Collection[D, T, R],
  logic : (Ref[D]) -> Unit,
) -> Collection[D, T, R] {
  self.map(fn(data) {
    let value = Ref(data)
    logic(value)
    value.val
  })
}

///|
/// Concatenate this collection and any additional collections in the same scope.
pub fn[D, T : Lattice, R] Collection::concatenate(
  self : Collection[D, T, R],
  sources : Array[Collection[D, T, R]],
) -> Collection[D, T, R] {
  sources.iter().fold(init=self, fn(result, next) { result.concat(next) })
}

///|
/// Concatenate any number of collections, including an empty list. The empty
/// result completes without requiring an input capability.
pub fn[D, T : Lattice, R, S] Scope::concatenate(
  self : Scope[T, S],
  sources : Array[Collection[D, T, R]],
) -> Collection[D, T, R] {
  let (output, capability, empty) : (
    Output[D, T, R, S],
    Capability[T, S],
    Collection[D, T, R],
  ) = self.source()
  ignore(output)
  capability.release()
  empty.concatenate(sources)
}

///|
/// Assert that all fully consolidated updates are zero. Returns a completion
/// probe so tests can wait until the assertion has checked the entire stream.
pub fn[D : Compare, T : Lattice, R : Semigroup] Collection::assert_empty(
  self : Collection[D, T, R],
) -> Probe[T] {
  self.consolidate().inspect(fn(_, _, _) { abort("collection is not empty") })
}

///|
/// Assert equality of timestamped weighted collections after consolidation.
pub fn[D : Compare, T : Lattice, R : Abelian] Collection::assert_eq(
  self : Collection[D, T, R],
  other : Collection[D, T, R],
) -> Probe[T] {
  self.concat(other.negate()).assert_empty()
}
