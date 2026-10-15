///|
// Immutable batch storage. Indexed layouts open an independent reader so future
// external-memory layouts need not retain a decoded copy in the batch itself.
priv enum UpdateStorage[D, T, R] {
  Rows(Array[(D, T, R)])
  Paged(
    Int32,
    () -> UpdateReader[D, T, R],
    (Array[(D, T, R)]) -> UpdateStorage[D, T, R]
  )
  Indexed(
    Int32,
    () -> UpdateReader[D, T, R],
    (Array[(D, T, R)]) -> UpdateStorage[D, T, R]
  )
}

///|
priv struct UpdateReader[D, T, R] {
  size : Int32
  read : (Int32) -> (D, T, R)
}

///|
fn[D, T, R] UpdateStorage::reader(
  self : UpdateStorage[D, T, R],
) -> UpdateReader[D, T, R] {
  match self {
    Rows(rows) => { size: rows.length(), read: fn(i) { rows[i] }, }
    Indexed(_, open, _) | Paged(_, open, _) => open()
  }
}

///|
fn[D, T, R] UpdateStorage::length(self : UpdateStorage[D, T, R]) -> Int32 {
  match self {
    Rows(rows) => rows.length()
    Indexed(size, _, _) | Paged(size, _, _) => size
  }
}

///|
fn[D, T, R] UpdateStorage::is_empty(self : UpdateStorage[D, T, R]) -> Bool {
  self.length() == 0
}

///|
fn[D, T, R] UpdateStorage::copy(
  self : UpdateStorage[D, T, R],
) -> Array[(D, T, R)] {
  let reader = self.reader()
  Array::makei(reader.size, fn(i) { (reader.read)(i) })
}

///|
fn[D, T, R] UpdateStorage::iter(
  self : UpdateStorage[D, T, R],
) -> Iter[(D, T, R)] {
  let reader = self.reader()
  let mut index = 0
  Iter::new(fn() {
    if index == reader.size {
      None
    } else {
      let result = (reader.read)(index)
      index += 1
      Some(result)
    }
  })
}

///|
fn[D, T, R] UpdateReader::length(self : UpdateReader[D, T, R]) -> Int32 {
  self.size
}

///|
#alias("_[_]")
fn[D, T, R] UpdateReader::get(
  self : UpdateReader[D, T, R],
  index : Int32,
) -> (D, T, R) {
  (self.read)(index)
}

///|
fn[D, T, R] UpdateStorage::packer(
  self : UpdateStorage[D, T, R],
) -> (Array[(D, T, R)]) -> UpdateStorage[D, T, R] {
  match self {
    Rows(_) => fn(rows) { Rows(rows) }
    Indexed(_, _, pack) | Paged(_, _, pack) => pack
  }
}

///|
fn[D, T, R] UpdateStorage::merge_packer(
  self : UpdateStorage[D, T, R],
  other : UpdateStorage[D, T, R],
) -> (Array[(D, T, R)]) -> UpdateStorage[D, T, R] {
  match (self, other) {
    (Paged(_, _, pack), _) => pack
    (_, Paged(_, _, pack)) => pack
    (Indexed(_, _, pack), _) => pack
    (Rows(_), _) => other.packer()
  }
}
