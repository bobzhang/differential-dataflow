///|
/// Exclusive prefix accumulation at each input location. Positions are 64-bit
/// unsigned integers (the upstream 64-bit usize domain). Each key is independent.
/// The input must describe at most one value per (position, key); combine must be
/// associative with the supplied zero, and need not be commutative.
pub fn[K : Compare + Hash, D : Compare + Hash, T : Lattice, S : Compare] Scope::prefix_sum(
  self : Scope[T, S],
  source : Collection[((UInt64, K), D), T, Int64],
  zero : D,
  combine : (K, D, D) -> D,
) -> Collection[((UInt64, K), D), T, Int64] {
  self.prefix_sum_at(source, source.map(fn(value) { value.0 }), zero, combine)
}

///|
/// Exclusive prefix values at arbitrary query locations, including empty ranges.
/// Output multiplicities follow the query collection.
pub fn[K : Compare + Hash, D : Compare + Hash, T : Lattice, S : Compare] Scope::prefix_sum_at(
  self : Scope[T, S],
  source : Collection[((UInt64, K), D), T, Int64],
  locations : Collection[(UInt64, K), T, Int64],
  zero : D,
  combine : (K, D, D) -> D,
) -> Collection[((UInt64, K), D), T, Int64] {
  let ranges = self.aggregate_ranges(source, combine)
  self.broadcast_prefix(ranges, locations, zero, combine)
}

///|
/// Accumulate every aligned power-of-two range. A key (position, log, key)
/// represents [position * 2^log, (position + 1) * 2^log); log ranges from 0 to 64.
pub fn[K : Compare + Hash, D : Compare, T : Lattice, S : Compare] Scope::aggregate_ranges(
  self : Scope[T, S],
  source : Collection[((UInt64, K), D), T, Int64],
  combine : (K, D, D) -> D,
) -> Collection[((UInt64, Int32, K), D), T, Int64] {
  let units = source.map(fn(value) { ((value.0.0, 0, value.0.1), value.1) })
  let nested = self.nested(0L, SummaryDomain::int64())
  let entered = nested.enter(units)
  let (variable, ranges) = nested
    .scope()
    .variable_from(entered, Product(self.domain.identity, 1L))
  let result = ranges
    .filter(fn(value) { value.0.1 < 64 })
    .map(fn(value) {
      let (position, log, key) = value.0
      ((position >> 1, log + 1, key), (position, value.1))
    })
    .reduce(fn(key, values) {
      let first = values[0].0.1
      let result = if values.length() > 1 {
        combine(key.2, first, values[1].0.1)
      } else {
        first
      }
      [(result, 1L)]
    })
    .concat(entered)
  variable.set(result)
  nested.leave(result)
}

///|
/// Reconstruct exclusive prefixes from aligned ranges. Missing requested ranges
/// contribute zero; repeated queries retain their multiplicity.
pub fn[K : Compare + Hash, D : Compare + Hash, T : Lattice, S : Compare] Scope::broadcast_prefix(
  self : Scope[T, S],
  ranges : Collection[((UInt64, Int32, K), D), T, Int64],
  queries : Collection[(UInt64, K), T, Int64],
  zero : D,
  combine : (K, D, D) -> D,
) -> Collection[((UInt64, K), D), T, Int64] {
  let requests = queries
    .flat_map(fn(query) {
      let result = []
      for log in 0..<64 {
        if (query.0 & (1UL << log)) != 0UL {
          result.push(((query.0 >> log) - 1UL, log, query.1))
        }
      }
      result
    })
    .distinct()
  let full_ranges = ranges.semijoin(requests)
  let zero_ranges = full_ranges
    .map(fn(value) { (value.0, zero) })
    .negate()
    .concat(requests.map(fn(key) { (key, zero) }))
  let used = full_ranges.concat(zero_ranges)
  let initial = queries.map(fn(query) { ((0UL, query.1), zero) }).distinct()
  let nested = self.nested(0L, SummaryDomain::int64())
  let seeds = nested.enter(initial)
  let ranges = nested
    .enter(used)
    .map(fn(value) {
      let (position, log, key) = value.0
      ((position << log, key), (log, value.1))
    })
  let (variable, states) = nested
    .scope()
    .variable_from(seeds, Product(self.domain.identity, 1L))
  let result = ranges
    .join_map(
      states,
      fn(key, range, state) {
        ((key.0 + (1UL << range.0), key.1), combine(key.1, state, range.1))
      },
      multiply=fn(a, b) { a * b },
    )
    .concat(seeds)
    .distinct()
  variable.set(result)
  nested.leave(result).semijoin(queries)
}
