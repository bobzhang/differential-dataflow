///|
/// A timestamp interval [lower, upper), observed at compaction frontier since.
pub struct Description[T] {
  priv lower : Antichain[T]
  priv upper : Antichain[T]
  priv since : Antichain[T]
}

///|
pub fn[T : Lattice] Description::Description(
  lower : Antichain[T],
  upper : Antichain[T],
  since : Antichain[T],
) -> Description[T] {
  guard !lower.is_empty() else { abort("batch lower frontier cannot be empty") }
  guard lower.precedes(upper) else {
    abort("batch upper frontier precedes lower")
  }
  {
    lower: Antichain(lower.elements),
    upper: Antichain(upper.elements),
    since: Antichain(since.elements),
  }
}

///|
pub fn[T : Lattice] Description::lower(self : Description[T]) -> Antichain[T] {
  Antichain(self.lower.elements)
}

///|
pub fn[T : Lattice] Description::upper(self : Description[T]) -> Antichain[T] {
  Antichain(self.upper.elements)
}

///|
pub fn[T : Lattice] Description::since(self : Description[T]) -> Antichain[T] {
  Antichain(self.since.elements)
}
