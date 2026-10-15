///|
/// Tuple multiplication with independently typed results. Explicit callbacks
/// adapt Rust Multiply's associated Output type without restricting it to Self.
pub fn[A, B, S, X, Y] scale_pair(
  values : (A, B),
  scalar : S,
  first~ : (A, S) -> X,
  second~ : (B, S) -> Y,
) -> (X, Y) {
  (first(values.0, scalar), second(values.1, scalar))
}

///|
pub fn[A, B, C, S, X, Y, Z] scale_triple(
  values : (A, B, C),
  scalar : S,
  first~ : (A, S) -> X,
  second~ : (B, S) -> Y,
  third~ : (C, S) -> Z,
) -> (X, Y, Z) {
  (first(values.0, scalar), second(values.1, scalar), third(values.2, scalar))
}

///|
pub fn[A, B, C, D, S, X, Y, Z, W] scale_quad(
  values : (A, B, C, D),
  scalar : S,
  first~ : (A, S) -> X,
  second~ : (B, S) -> Y,
  third~ : (C, S) -> Z,
  fourth~ : (D, S) -> W,
) -> (X, Y, Z, W) {
  (
    first(values.0, scalar),
    second(values.1, scalar),
    third(values.2, scalar),
    fourth(values.3, scalar),
  )
}

///|
pub fn[S] scale_unit(_value : Unit, _scalar : S) -> Unit {
  ()
}
