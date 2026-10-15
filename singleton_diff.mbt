///|
/// MoonBit counterpart of Rust's one-element difference tuple `(R,)`.
pub struct SingletonDiff[R] {
  priv inner : R
} derive(Eq, Compare, Debug, Hash)

///|
pub fn[R] SingletonDiff::SingletonDiff(value : R) -> SingletonDiff[R] {
  { inner: value, }
}

///|
pub fn[R] SingletonDiff::value(self : SingletonDiff[R]) -> R {
  self.inner
}

///|
pub impl[R : Semigroup] Semigroup for SingletonDiff[R] with fn plus(self, other) {
  SingletonDiff(self.inner.plus(other.inner))
}

///|
pub impl[R : Semigroup] Semigroup for SingletonDiff[R] with fn is_zero(self) {
  self.inner.is_zero()
}

///|
pub impl[R : Monoid] Monoid for SingletonDiff[R] with fn zero() {
  SingletonDiff(R::zero())
}

///|
pub impl[R : Abelian] Abelian for SingletonDiff[R] with fn negate(self) {
  SingletonDiff(self.inner.negate())
}

///|
pub fn[R, S, O] SingletonDiff::scale(
  self : SingletonDiff[R],
  scalar : S,
  multiply : (R, S) -> O,
) -> SingletonDiff[O] {
  SingletonDiff(multiply(self.inner, scalar))
}

///|
pub extend SingletonDiff with Eq::{equal, not_equal}

///|
pub extend SingletonDiff with Compare::{compare, op_lt, op_le, op_gt, op_ge}

///|
pub extend SingletonDiff with Debug::{to_repr}

///|
pub extend SingletonDiff with Hash::{hash, hash_combine}

///|
pub extend SingletonDiff with Semigroup::{plus, is_zero}

///|
pub extend SingletonDiff with Monoid::{zero}

///|
pub extend SingletonDiff with Abelian::{negate}
