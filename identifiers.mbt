///|
/// Assign unique 64-bit identifiers using upstream's FNV hash and iterative
/// collision resolution. Records compare by MoonBit Compare; custom Rust-ordered
/// records should provide matching Compare and RustHash implementations.
pub fn[D : Compare + RustHash, T : Lattice, R : Abelian, S : Compare] Scope::identifiers(
  self : Scope[T, S],
  source : Collection[D, T, R],
) -> Collection[(D, UInt64), T, R] {
  self.identifiers_with(source, fn(round, data) { rust_hash((round, data)) })
}

///|
/// Custom collision proposals. The hash must eventually admit distinct IDs as
/// rounds increase; otherwise the fixed point need not converge.
pub fn[D : Compare, T : Lattice, R : Abelian, S : Compare] Scope::identifiers_with(
  self : Scope[T, S],
  source : Collection[D, T, R],
  hash : (Int32, D) -> UInt64,
) -> Collection[(D, UInt64), T, R] {
  let initial = source.map(fn(data) { (0, data) })
  let nested = self.nested(0L, SummaryDomain::int64())
  let entered = nested.enter(initial)
  let (variable, changes) = nested
    .scope()
    .variable(Product(self.domain.identity, 1L))
  let result = entered
    .concat(changes)
    .map(fn(pair) { (hash(pair.0, pair.1), pair) })
    .reduce(fn(_, values) {
      let output = []
      let ((round, data), count) = values[0]
      if round > 0 {
        output.push(((0, data), count.negate()))
        output.push(((round, data), count))
      }
      for index in 1..<values.length() {
        let ((round, data), count) = values[index]
        output.push(((0, data), count.negate()))
        output.push(((round + 1, data), count))
      }
      output
    })
    .map(fn(value) { value.1 })
  variable.set(result)
  nested
  .leave(result)
  .concat(initial)
  .map(fn(pair) { (pair.1, hash(pair.0, pair.1)) })
}
