# Differential Dataflow for MoonBit — work in progress

The target is **full upstream compatibility** with pinned Rust Differential
Dataflow and its Timely runtime. This repository is not a completed port or a
production release. [COMPATIBILITY.md](COMPATIBILITY.md) tracks the remaining
work; [UPSTREAM.md](UPSTREAM.md) pins both reference checkouts.

The implemented foundations currently run on JavaScript, native, Wasm, and Wasm GC:

- Timestamp lattices, product partial orders, antichains, and counted frontiers.
- Counted cyclic progress, feedback loops, nested product scopes, and fixed-point iteration.
- Output capabilities, custom unary operators, and frontier notifications.
- Signed and presence-only differences and generic update consolidation.
- Sealed trace batches, logical/physical compaction, and snapshot cursors.
- Buffered input sessions, a cooperative worker, progress probes, and fanout.
- Map, flat-map, filter, explode, negate, concat, and consolidation.
- Weighted incremental joins, semijoins, and antijoins, including retractions.
- Grouped reduction, count, threshold, and distinct with synthetic partial-order timestamps.
- Shared arrangements and independent trace readers, live imports, historical lookups,
  and total-order upserts with upstream tie-breaking.
- Capture/replay with duplicate suppression, out-of-order messages, and counted progress.

## Example: totals that change when prices change

```mbt check
///|
test "reprice existing orders incrementally" {
  let worker = @differential.Worker()
  let (orders, order_stream) : (
    @differential.InputSession[(Int32, String), Int64, Int64],
    @differential.Collection[(Int32, String), Int64, Int64],
  ) = worker.input(0)
  let (prices, price_stream) : (
    @differential.InputSession[(Int32, Int64), Int64, Int64],
    @differential.Collection[(Int32, Int64), Int64, Int64],
  ) = worker.input(0)
  let changes = []
  let probe = order_stream
    .join_map(price_stream, fn(_, customer, price) { (customer, price) }, multiply=fn(
      quantity,
      present,
    ) {
      quantity * present
    })
    .reduce(fn(_, values) {
      let mut total = 0L
      for (price, quantity) in values {
        total += price * quantity
      }
      [(total, 1L)]
    })
    .inspect(fn(data, time, diff) { changes.push((data, time, diff)) })
  orders.update((1, "Alice"), 3)
  prices.insert((1, 7))
  orders.advance_to(1)
  prices.advance_to(1)
  orders.flush()
  prices.flush()
  assert_true(worker.run() is Quiescent(_))
  prices.remove((1, 7))
  prices.insert((1, 9))
  orders.close()
  prices.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  assert_eq(changes, [
    (("Alice", 21L), 0L, 1L),
    (("Alice", 21L), 1L, -1L),
    (("Alice", 27L), 1L, 1L),
  ])
  worker.dispose()
}
```

## Example: incremental fixed points

```mbt check
///|
test "fixed point updates after a root changes" {
  let worker = @differential.Worker()
  let scope = worker.scope(0L, @differential.SummaryDomain::int64())
  let (input, roots) : (
    @differential.InputSession[Int32, Int64, Int64],
    @differential.Collection[Int32, Int64, Int64],
  ) = scope.input()
  let reachable = scope.iterate(roots, fn(_, values) {
    values
    .concat(
      values.flat_map(fn(node) { if node < 5 { [node + 1] } else { [] } }),
    )
    .distinct()
  })
  let counts : Map[Int32, Int64] = Map([])
  let probe = reachable.inspect(fn(node, _, diff) {
    counts[node] = counts.get(node).unwrap_or(0) + diff
  })
  input.insert(2)
  input.advance_to(1)
  input.flush()
  assert_true(worker.run() is Quiescent(_))
  assert_true(!probe.less_than(1))
  assert_eq(counts.get(3), Some(1L))
  input.remove(2)
  input.insert(4)
  input.close()
  assert_true(worker.run() is Quiescent(_))
  assert_true(probe.done())
  assert_eq(counts.get(3), Some(0L))
  assert_eq(counts.get(5), Some(1L))
  worker.dispose()
}
```

## Current contracts

Build a worker graph before running it or flushing input. `advance_to()` changes
an input's local timestamp; `flush()` publishes buffered data and progress.
Call `close()` explicitly to release the input capability. `run()` returning
`Quiescent` means no operator is currently activated; open inputs can still
produce more data. Probe frontiers determine whether a timestamp is complete.
`dispose()` releases the worker's registered tasks and invalidates its inputs.

Tuples, timestamps, and weights must be immutable. Comparison and algebra traits
must obey their mathematical laws. Callbacks must be deterministic and must not
re-enter the worker or mutate the graph. Signed weights use MoonBit integer
arithmetic; applications are responsible for avoiding unwanted overflow.

`join_map` accepts explicit weight multiplication so different input and output
weight types can be used without Rust associated types. `antijoin` implements
weighted subtraction; its key input must have weights zero or one for set-style
exclusion. `distinct` represents any nonzero accumulated weight, including a
negative weight, as one occurrence.

Reduction enumerates the finite join-closure of retained timestamps. It compacts
input and output history at singleton frontiers, and releases canceled keys.
The 20,000-epoch retention test bounds this state for a total-order workload.
General incomparable frontiers still retain history, and timestamp closure can
grow exponentially for some lattices. This remains a reference algorithm, with
further incremental optimization required.

Use `worker.scope(minimum, domain)` for counted progress and cyclic graphs;
`worker.input(initial)` remains available for acyclic pipelines. Scope minimums
must be lower bounds of all timestamps supplied in that domain. Feedback currently
requires nonnegative path advancement. `iterate` does not insert consolidation:
finish the loop body with `distinct`, `reduce`, or `consolidate` to dissipate
canceling differences, as in upstream.

Capabilities and trace readers use explicit `release()` in place of Rust Drop.
Cloning creates independent ownership; a plain MoonBit assignment aliases the same
handle. Notification queues and capability sets transfer inserted handles.
Custom unary data callbacks borrow their capability: clone it to retain it.
Worker disposal cancels imports and lookups, unregisters listeners, and clears
scoped progress and queued records.

Ordering follows MoonBit's `Compare` implementation. In particular, built-in
String comparison is length-first, unlike Rust's lexical string order. Use a
custom ordered key/value type when lexical ordering matters (for example upsert
ties or minimum-value reductions).

Trace `snapshot(time)` requires a complete timestamp at or beyond the logical
compaction frontier. Physical compaction can remove batch cuts; `cursor_through`
then returns `None`. Cursors snapshot their records and survive later compaction.

## Validation

```sh
moon fmt --check
moon check --target all --warn-list +unnecessary_annotation --deny-warn
moon test --target all
# Restore pinned references using UPSTREAM.md first:
python3 validation/compare.py
```

The pinned Rust comparisons cover:

- 10,240 frontier/compaction rounds and 1,024 live weighted join epochs.
- 128 product-time reduction cases, with 3,200 independent snapshot queries.
- 256 feedback epochs and 256 nested fixed-point epochs with a cyclic graph BFS oracle.
- 1,024 shared-arrangement epochs with independent reader compaction.
- 8,192 upsert records, including equal-time conflicts and deletion.
- 256 reordered/duplicated capture-replay cases, comparing exact progress transitions.

Local retention tests exercise 20,000 reduction epochs, 2,000 feedback epochs,
2,000 shared-trace epochs, and 10,000 replay intervals. Tests run on native,
JavaScript, Wasm, and Wasm GC. The CI workflow repeats backend tests on Linux and
macOS and runs the Rust oracle separately; it has not yet run on GitHub for this
unfinished port. Results validate these components, not full upstream compatibility.
See [validation/results.json](validation/results.json).

MIT licensed; both upstream notices are retained. Module: `bobzhang/differential`.
