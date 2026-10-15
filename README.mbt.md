# Differential Dataflow for MoonBit — work in progress

The target is **full upstream compatibility** with pinned Rust Differential
Dataflow and its Timely runtime. This repository is not a completed port or a
production release. [COMPATIBILITY.md](COMPATIBILITY.md) tracks the remaining
work; [UPSTREAM.md](UPSTREAM.md) pins both reference checkouts.

The implemented foundations currently run on JavaScript, native, Wasm, and Wasm GC:

- Timestamp lattices, product partial orders, antichains, and counted frontiers.
- Signed and presence-only differences and generic update consolidation.
- Sealed trace batches, logical/physical compaction, and snapshot cursors.
- Buffered input sessions, a cooperative worker, progress probes, and fanout.
- Map, flat-map, filter, explode, negate, concat, and consolidation.
- Weighted incremental joins, semijoins, and antijoins, including retractions.
- Reference grouped reduction, count, threshold, and distinct, including synthetic
  timestamps required by partially ordered time.

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

Reduction currently enumerates the finite join-closure of historical timestamps.
It is a correctness reference, not the final optimized operator. It retains
history while its input is open; timestamp closure can grow exponentially for
some lattices. Do not use this checkpoint for unbounded production workloads.

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

The Rust harness compares progress-frontier changes and compaction over 10,240
randomized rounds, plus live weighted joins over 1,024 update epochs. Both also
use independent Python oracles. Local tests cover product-time reductions,
trace snapshots, long-lived compaction, bounded scheduler storage, retractions,
and cancellation. These results validate the implemented components, not full
upstream compatibility. See [validation/results.json](validation/results.json).

MIT licensed; both upstream notices are retained. Module: `bobzhang/differential`.
