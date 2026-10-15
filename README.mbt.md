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
- Capture/replay with duplicate suppression, out-of-order messages, counted progress,
  retryable writers and externally activated sources.
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

Build each scope graph before running the worker or flushing that scope's input.
Fresh scopes can be created between worker runs, including imports of existing
live traces; already executed scope graphs remain frozen. `advance_to()` changes
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
inert on retirement or disposal. Thread-safe cross-thread activators are not implemented.

`builder.build_reschedule(...)` accepts a callback returning whether external work
is still unfinished. Returning `true` retains the operator but does not queue another
invocation: use its activator for that. Once it returns `false`, all input records
and final frontiers have been consumed, and output capabilities are released, the
worker drops the callback. Both builder methods accept `on_shutdown=...` for explicit
resource cleanup, called exactly once on completion or worker disposal. Scheduling
may coalesce progress wakeups differently from Rust; invocation counts are not a
portable contract.

`WorkerGroup(peers)` coordinates workers in one process with globally counted
progress and keyed exchange. It executes cooperatively on one thread; it does
not provide shared-memory parallel threads. Build identical operator
graphs on each peer (including newly added scope groups), and use `ScopeGroup.exchange` to colocate equal keys before
keyed operations. `ScopeGroup.iterate` coordinates nested progress and exchange.
Dispose the entire group with `group.dispose()`.

`ClusterWorker` runs independent processes using ordered all-gather rounds.
`DistributedScope.exchange` serializes updates and tracks records in transit;
`DistributedScope.iterate` coordinates nested fixed points across processes.
The native `transport` package supplies `TcpTransport` for POSIX hosts. All peers
must build identical graphs, use compatible codecs, and call `run()` with the
same round bound. New scopes must be added in the same order between runs on
all peers; their graph manifests are checked before processing them. Release the worker and close the transport separately. Transport
errors terminate the runtime. This currently uses synchronous barriers and its own
wire protocol. See `validation/cluster` for an executable two-process example.

`scale_pair`, `scale_triple` and `scale_quad` apply independent multiplication
callbacks to tuple fields; result types may differ by field. `scale_unit` covers
the empty tuple, and singleton/vector differences provide `scale` methods.

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

`ColumnarBatch(updates, lower=..., upper=...)` stores keys, values, timestamps and
weights in separate immutable arrays; offset tables share repeated keys and values.
`batch()` shares those columns with the normal trace/cursor APIs. Use
`arrange_by_key(columnar=true, fueled=true)` (or `arrange_by_self`) to retain that
layout through live arrangements and compaction. Storage counts describe entries,
not measured bytes. The current merge/compaction path uses temporary row groups;
upstream's trie-native chunk transducers and binary codecs remain pending.

`SpillPolicy(budget_records, store=..., codec=..., chunk_size=...)` pages sealed
batches through a pluggable `BytesStore`. Use `batch.spill(policy)` or pass
`spill=policy` to an arrangement. Compaction and merging retain the spill policy.
The high-water-mark resident budget is cumulative, matching upstream: dropping
old batches does not replenish it. Each reader caches one decoded page; builders
and mergers still use temporary rows, so this is not a total process-memory cap.
Payload checksums reject changed storage before decoding. `stats()` reports
stored/fetched chunks, records and bytes.

The native `spill_file` package supplies `SpillFile().store()`, backed by an
anonymous temporary file. Page handles retain the file; optional `close()`
invalidates outstanding handles. This is temporary storage, not durable replay.
Codecs are explicit; the supplied JSON codec preserves 64-bit values but does
not implement Rust's columnar binary format.

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

`ScopeGroup::replay_from` and `DistributedScope::replay_from` reconstruct one
captured collection from messages arriving at any peer. Duplicate messages across
peers are counted once globally; output goes to `hash(data) % peers`. These
adapters partition record deduplication and timestamp counts, then exchange
compact frontiers. `time_hash` controls count sharding; group replay defaults to
peer zero, process replay hashes the timestamp codec. Source replay emits records
eagerly and rejects different weights for the same data/time. The standalone
`Replayer` waits for sealed intervals. A paused source keeps progress open;
wake its handle when messages arrive and cancel every peer to abandon a replay.

Arrangement `join` and `join_map` accept `fuel` (default 100,000). A turn performs
at most that many cursor/emission steps before yielding. Pending work retains
immutable batch views and timestamp capabilities, so probes cannot report its
results complete prematurely. Empty historical intervals do not hold old times.

`TcpTransport.start_exchange(value)` and `poll_exchange()` provide nonblocking
round I/O for host event loops. A pending poll returns `None`; a completed poll
returns peer-ordered values. Each peer advances at most 64 KiB of payload per
poll, with frame bounds and deadlines. Connection setup and handshake remain
synchronous. Do not overlap exchanges or mix a pending asynchronous exchange with
`exchange`. Native validation checks host control before peer input, fragmented
frames, 11 failure cases, and repeated large exchanges across two/three peers.

For host-polled cluster execution, construct `AsyncExchange(start=..., poll=...)`
and pass it as `ClusterWorker(..., async_exchange=adapter)`. Bind these callbacks
to the transport's `start_exchange` and `poll_exchange`. `cluster.poll()` reports
`Pending`, `Progress`, or `Quiescent`; schedule a later host callback for Pending.
`run()` also yields as `StepLimit` when I/O is pending. It freezes the submitted
graph and keeps frontiers open until the complete peer response is applied.
Build graphs and submit input epochs before driving all peers to quiescence.
This removes blocking waits from round I/O; progress still uses collective rounds,
not decentralized peer-to-peer scheduling. Native comparisons repeat all six
workload families through the asynchronous adapter (784 epochs).

## Dataflow lifecycle

Each root `worker.scope(...)` gets a monotone `dataflow_index`; nested scopes and
regions share it. `next_dataflow_index`, `installed_dataflows`, and `has_dataflows`
inspect this lifecycle. `worker.drop_dataflow(id)` cancels a local dataflow and
all its nested work without disposing the worker. It drops queued records,
invalidates scoped output capabilities, runs operator shutdown callbacks once,
and closes trace writers so independent imports can finish. Externally owned
trace readers remain usable. Later flush/close calls on cancelled inputs are
ignored. As in pinned Timely, cancelled probes retain their last observed
frontier: cancellation does not certify that queued records were processed.
`WorkerGroup.drop_dataflow(id)` cancels corresponding roots across cooperative
peers. `ClusterWorker.drop_dataflow(id)` requests collective cancellation: any
peer can request it, and the next `run` round applies it everywhere before record
delivery. All peers must continue calling `run`. This takes effect at the round
boundary; work already processed remains observable. Cluster protocol version 3
carries cancellation requests alongside progress and completion votes.

## Runnable upstream algorithms

Run `moon run examples/showcase --target js` (or `--target native`) to see
integer PageRank, degree histograms, and item recommendations update after graph
insertions and removals. Each printed row contains the completed epoch followed
by the three accumulated results. These are reusable functions in
`bobzhang/differential/examples/algorithms`.

PageRank retains upstream's six-million initial and one-million reset weights,
with a positive iteration bound. Recommendations assume set-valued user/item
interactions and return exact `(intersection, union)` Jaccard fractions; upstream's
final floating score is an intentional presentation adaptation. Users with at
least `max_interactions` interactions are excluded, and scores must exceed 0.05.
The randomized oracle compares all three algorithms with pinned Rust and full
recomputation over 384 epochs, including empty input and complete retractions.

## Persistent capture

The native `bobzhang/differential/capture_journal` package stores capture messages
in an exclusively created POSIX file. Use `CaptureMessage::codec` with explicit
data/time/difference codecs, `CaptureJournal::create(path)`, and `journal.append(message, codec)`.
Each append fsyncs; creation also syncs the containing directory. To replay,
open a reader with `CaptureJournal::open(path)` and call `next(codec)` from
`Scope::replay_from`. Wake its handle when new bytes arrive. EOF or an incomplete
last frame means temporarily unavailable; only terminal capture progress means
completion. Complete corrupt frames raise `JournalError` and poison the reader.
Call `close` explicitly to report close errors. Automatic writer recovery is not
provided. The versioned JSON/frame encoding is independent of Rust serde.

## Custom trace storage

`Collection.arrange_with(factory)` accepts a `TraceBackend` with a reader, batch
insertion and closure callbacks, and an optional batch builder. `BatchView`
adapts an immutable indexed layout without eagerly copying its rows. `TraceReader`
adapts clean batch cuts, compaction capabilities, cloning, and live subscriptions.
The resulting `ArrangementView` supports shared joins, reductions, nested scopes,
and imported queries through the same operators as built-in storage.

A backend must retain immutable batches while readers use them, clone independent
compaction pins, and seal its upper frontier when closed. Operator cancellation
closes the writer, allowing surviving imports to finish. The black-box tests in
`trace_adapters_test.mbt` implement an independent four-column backend and exercise
these ownership and progress requirements.

## Message times and record times

A data message carries a capability time; each `(data, time, difference)` record
inside it may have a later logical time. `InputSession.update_at` and
`Output.send_at` preserve that distinction through mapping, nested scopes,
feedback, and local or process exchange. Progress counts messages at their
capability times, so future records do not hide unfinished earlier work.

- `inspect_batch` observes the capability time and a copied record array;
  `inspect_container` also observes frontier changes and forwards the stream.
- `results_in(step, domain)` changes logical record times and drops overflows,
  while retaining the original message capability.
- `delay(advance)` changes both times and holds messages until the input frontier
  passes their delayed capability. The function must be pure, monotone, and only
  advance times.
- `join_function` joins input times with computed row times and applies an explicit
  weight multiplication callback.
- `consolidate_stream` consolidates each message immediately, without waiting for
  all updates at a logical time.
- `OperatorInput.for_each_batch` exposes original messages and borrowed input
  capabilities; `for_each` remains a convenience API grouped by record time.

The cluster protocol is now version 4 because routed messages include capability
timestamps. All participating workers must use the same library version.

## Min-plus shortest paths

`examples/algorithms.monoid_bfs` ports upstream's semigroup shortest-path example.
`MinSum` combines alternative routes by minimum and extends routes by adding their
lengths. Adding edges, lowering edge weights, or adding roots propagates improved
distances through a feedback loop; zero-weight cycles converge. These weights do
not support retractions, so deleting edges requires the ordinary signed-weight
formulation. `validation/bridge/monoid_bfs.mbt` demonstrates incremental updates.

`Scope.variable(step)` now supports weights without negation. Only
`Scope.variable_from(source, step)` requires `Abelian`, because it must subtract
the initially supplied source. This matches upstream's constructor distinction.

## Reducers with explicit corrections

`Collection.reduce_core`, `Arranged.reduce_core`, and
`ArrangementView.reduce_core` receive the key, consolidated input snapshot, and
consolidated existing output snapshot. Return the changes to apply to that output.
Both snapshots are owned copies; the callback can receive an empty input after a
retraction. It is never called with both snapshots empty.

Unlike `reduce`, this API accepts output weights that implement only `Semigroup`.
For example, a presence-only reducer can emit newly seen values without requiring
subtraction or a zero value. The result is an `Arranged` shared index; use
`as_collection()` for the update stream and release the arrangement when finished.
The callback must be deterministic and preserve its reduction invariant after
applying corrections, including at joins of incomparable timestamps.

## Runtime-defined iteration depths

`PointStamp` stores a runtime-sized vector of timestamp coordinates. It uses
product order, so independent inner iterations can remain incomparable. Trailing
minimum coordinates are canonicalized away. `SummaryDomain::pointstamp` lifts a
scalar summary domain; `feedback_summary(level, step)` advances one coordinate,
and `Scope.leave_dynamic(collection, level)` discards coordinates at and below
that one-based level. `enter_dynamic` is an identity operation, as upstream.

Use these types inside a normal product scope when the number of nested loops is
known only at runtime. `WireCodec::pointstamp` and `pointstamp_summary` support the
same scopes across process workers. The `validation/bridge/pointstamp.mbt` and
`validation/cluster/pointstamp.mbt` fixtures demonstrate local and distributed
fixed points with runtime-selected depths and input retractions.

## Validation

```sh
moon fmt --check
moon check --target all --warn-list +unnecessary_annotation --deny-warn
moon test --target all
# Restore pinned references using UPSTREAM.md first:
python3 validation/compare.py
python3 validation/cluster_compare.py
python3 validation/transport_failures.py
python3 validation/journal_check.py
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
- 128 eager source cases against Rust, with records available before sealed progress.
- 1,536 activated capture/replay epochs with update retries, duplicate messages,
  progress arriving before data, and an independent accumulated-state oracle.
- 512 partitioned join epochs against Rust running two workers.
- 128 distributed replay epochs in two/three native processes against Rust
  running three workers, including duplicates across peers and delayed data.
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
