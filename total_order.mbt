///|
/// Marker: the lattice order must agree with Compare's total order.
pub(open) trait TotalOrder: Lattice {}

///|
pub impl TotalOrder for Int64
