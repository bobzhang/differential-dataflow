# Differential Dataflow for MoonBit — work in progress

The target is **full upstream compatibility** with pinned Rust Differential
Dataflow and its Timely runtime. This repository is not a completed port or a
production release. [COMPATIBILITY.md](COMPATIBILITY.md) tracks the remaining
work; [UPSTREAM.md](UPSTREAM.md) pins both reference checkouts.

The implemented foundations currently run on JavaScript, native, Wasm, and Wasm GC:

- Timestamp lattices, product partial orders, antichains, and counted frontiers.
- Counted cyclic progress, nested feedback loops, custom timestamp refinements and identity regions.
- Output capabilities, custom unary operators, and frontier notifications.
- Signed and presence-only differences and generic update consolidation.
- Sealed trace batches, logical/physical compaction, and snapshot cursors.
- Buffered input sessions, cooperative workers, progress probes, and fanout.
- Worker groups with keyed exchange, global progress, and nested peer iteration.
- Map, flat-map, filter, explode, negate, concat, and consolidation.
- Weighted incremental joins, semijoins, and antijoins, including retractions.
- Grouped reduction, count, threshold, and distinct with synthetic partial-order timestamps.
- Shared arrangements and independent trace readers, live imports, historical lookups,
  and total-order upserts with upstream tie-breaking.
- Capture/replay with duplicate suppression, out-of-order messages, and counted progress.
- Incremental BFS distances, minimum-label propagation, strongly connected component edges,
  bidirectional shortest-path queries, and sequential neighbor-state updates.
- Exclusive prefix sums at sparse 64-bit positions, with independent keys and dynamic queries.
- Stable identifier assignment with iterative collision repair and Rust-compatible FNV encodings.

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

Custom operators can retain `builder.activator()` to request a coalesced wakeup,
including from their own callback. `activate_after(Duration(...))` schedules a
local timer using an explicit `Worker(clock=...)` monotonic host clock; zero delay
needs no clock. The host calls `step()`/`run()` and can use `next_activation()` to
choose its next wakeup. `Quiescent` does not wait for future timers. Handles become
inert on disposal. Thread-safe cross-thread activators are not implemented.

`WorkerGroup(peers)` coordinates workers in one process with globally counted
progress and keyed exchange. It executes cooperatively on one thread; it does
not provide shared-memory parallel threads. Build identical operator
graphs on each peer, and use `ScopeGroup.exchange` to colocate equal keys before
keyed operations. `ScopeGroup.iterate` coordinates nested progress and exchange.
Dispose the entire group with `group.dispose()`.

`ClusterWorker` runs independent processes using ordered all-gather rounds.
`DistributedScope.exchange` serializes updates and tracks records in transit;
`DistributedScope.iterate` coordinates nested fixed points across processes.
The native `transport` package supplies `TcpTransport` for POSIX hosts. All peers
must build identical graphs, use compatible codecs, and call `run()` with the
same round bound. Release the worker and close the transport separately. Transport
errors terminate the runtime. This currently uses synchronous barriers and its own
wire protocol. See `validation/cluster` for an executable two-process example.

Tuples, timestamps, and weights must be immutable. Comparison and algebra traits
must obey their mathematical laws. Callbacks must be deterministic and must not
re-enter the worker or mutate the graph. Signed weights use MoonBit integer
arithmetic; applications are responsible for avoiding unwanted overflow.

`Int8`, `Int128`, and `UInt128` cover integer widths absent from native MoonBit
types. `Wrapping` preserves explicit signed wrapping types; `SingletonDiff`
adapts Rust one-element tuples. Graph propagation and SCC accept any `Ring`
difference, which supplies multiplication and one in addition to Abelian addition.

`join_map` accepts explicit weight multiplication so different input and output
weight types can be used without Rust associated types. `antijoin` implements
weighted subtraction; its key input must have weights zero or one for set-style
exclusion. `distinct` represents any nonzero accumulated weight, including a
negative weight, as one occurrence.

Reduction enumerates the finite join-closure of retained timestamps. It compacts
input and output history at arbitrary antichain frontiers and releases canceled
keys. Retention tests cover 20,000 total-order and 5,000 incomparable-frontier
epochs. Timestamp closure can still grow exponentially for some lattices;
further incremental optimization remains necessary.

`Batcher(minimum)` consumes chunks, merges sorted chains, and seals intervals at
arbitrary antichains. `BatchBuilder` consumes ordered chunks into immutable
batches. `Batch.begin_merge` creates a `BatchMerger` whose `work(fuel)` advances
by complete data groups; `is_complete()` and `done()` finish the result. Fuel
counts input updates and may overshoot by one group, a conservative adaptation
of Rust's output-based accounting. `Spine(minimum)` uses these primitives for bounded maintenance and configurable
idle exertion. `shared_spine(minimum)` adds independently pinned readers;
`collection.arrange_by_key(fueled=true)` selects that backend for arrangements.
The default arrangement backend retains eager compaction for existing callers.

`Cursor` merges retained batch views without copying stored update history.
Times are visited per batch; callers consolidate them when needed.

`Arranged.join` and `Arranged.join_map` share existing sorted batch indexes, using
binary key lookup and independent compaction capabilities. Multiple joins reuse
one arrangement without copying its history. `Arranged.reduce` also reuses shared
key ranges and caches unchanged-key corrections. Release the arrangement handle after
building consumers; the consumers retain their own readers until completion.
`Arranged.enter` and `ArrangementView.enter_refined` retain the original index
across nested scopes. `TraceReader` adapts timestamps and compaction capabilities
without copying stored batches; `BatchView` maps immutable batches lazily.
`BatchView.frontier` and `TraceReader.frontier` advance visible times by a since
frontier and suppress updates at or beyond an until frontier. As in Rust, they
preserve batch metadata and cursor keys even when all times for a key are hidden.
`ArrangementView.enter_at` assigns inner times from the data, with an explicit
conservative inverse for compaction. `TraceReader.import_into` supports these
views for both retained history and future sealed batches.
Views and readers own independent capabilities and require `release()`.
`Scope.bfs_arranged`, `Scope.propagate_core`, and `Scope.bidijkstra_arranged`
accept these views, allowing graph algorithms to share edge indexes. Collection
convenience methods build those indexes once and delegate to the same algorithms.

Use `worker.scope(minimum, domain)` for counted progress and cyclic graphs;
`worker.input(initial)` remains available for acyclic pipelines. Scope boundaries share one progress calculation seeded by real capabilities and
queued records, so an empty nested feedback cycle cannot sustain its own progress.
Scope minimums must be lower bounds of all timestamps supplied in that domain. Individual feedback edges may move time backward, provided complete cycles
have convergent reachability summaries and the domain laws hold. `iterate` does not insert consolidation:
finish the loop body with `distinct`, `reduce`, or `consolidate` to dissipate
canceling differences, as in upstream.

Capabilities and trace readers use explicit `release()` in place of Rust Drop.
Cloning creates independent ownership; a plain MoonBit assignment aliases the same
handle. Notification queues and capability sets transfer inserted handles.
Custom unary data callbacks borrow their capability: clone it to retain it.
`scope.operator()` builds heterogeneous multi-input/output operators. Its input
capabilities are borrowed; `cap.delayed(output, time)` creates an owned output
capability only when the declared connection summaries permit that timestamp.
Empty summary sets disconnect a port pair. Release every initial output capability
received by `builder.build` when it is no longer needed.
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
python3 validation/cluster_compare.py
python3 validation/transport_failures.py
# Optional Clang ASan/LSan validation:
python3 validation/sanitize_cluster.py
```

The pinned Rust comparisons cover:

- 10,240 frontier/compaction rounds and 1,024 live weighted join epochs.
- 128 product-time reduction cases, with 3,200 independent snapshot queries.
- 768 streamed reduction epochs with independently advanced antichain capabilities.
- 256 feedback epochs and 256 nested fixed-point epochs with a cyclic graph BFS oracle.
- 1,024 shared-arrangement epochs with independent reader compaction.
- 8,192 upsert records, including equal-time conflicts and deletion.
- 256 reordered/duplicated capture-replay cases, comparing exact progress transitions.
- 512 partitioned join epochs against Rust running two workers.
- 128 TCP process join epochs and 128 fixed-point epochs with one/two nested loops and two/three peers.
- 192 dynamic graph epochs comparing BFS, label propagation, SCC edge weights, and scheduled variants.
- 2,048 cases for 128-bit wrapping arithmetic, checked overflow, and Duration carries.
- 192 prefix-sum epochs with sparse positions, data/query retractions and multiplicities.
- 384 identifier epochs with forced collisions, winner deletions and FNV encoding checks.
- 192 bidirectional search/sequential-update epochs with independent graph recomputation.

Local retention tests exercise 20,000 total-order and 5,000 antichain reduction epochs,
2,000 shared-index join epochs, 2,000 feedback epochs,
2,000 shared-trace epochs, 10,000 replay intervals, and 1,000 exchange epochs. Tests run on native,
JavaScript, Wasm, and Wasm GC. The CI workflow repeats backend tests on Linux and
macOS and runs the Rust oracle separately; it has not yet run on GitHub for this
unfinished port. Results validate these components, not full upstream compatibility.
See [validation/results.json](validation/results.json).

MIT licensed; both upstream notices are retained. Module: `bobzhang/differential`.
