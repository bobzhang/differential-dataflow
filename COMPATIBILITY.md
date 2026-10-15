# Full compatibility tracking

Completion target: the behavior of Differential Dataflow 0.25.1 at the pinned
commit, including the required Timely runtime. Idiomatic MoonBit APIs can differ
from Rust syntax and ownership APIs; semantic differences must remain explicit
until resolved. A small core port does not satisfy this target.

## Current evidence

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Lattice joins/meets and advance-by | Common built-ins and products | Signed/unsigned 8/16/32/64/128-bit integers, Duration, Unit and generic products; Int8 pairs tested exhaustively |
| Minimal/counted antichains | Implemented | 10,240 Rust and independent-oracle rounds |
| Change batches | Implemented | Signed cancellation and frontier tests |
| Difference algebra | Upstream built-ins implemented with typed adapters | All integer widths, Wrapping signed adapters, Present, singleton/tuple arities through four and VectorDiff; explicit multiplication callbacks adapt associated output types; scale_unit/pair/triple/quad support heterogeneous associated outputs |
| Sealed traces | Initial implementation | Snapshots, compaction, closure, exact-cut cursors, empty-interval traversal and lazy entered/frontier-filtered trace views with independent reader pins; not all upstream trace interfaces/layouts |
| Buffered input | Implemented callback and worker integration | Explicit close replaces Rust Drop |
| Worker scheduling | Cooperative workers | Counted scopes, local/timed activators with explicit monotonic host clock, activation deduplication, re-entry guards, bounded queues, disposal tests; 8,192 activation rounds match Rust; fresh scopes and live trace queries can be added between runs |
| Unary and binary collection operators | Implemented baseline | Map/filter/flat-map/explode/negate/concat/consolidate and weighted join family |
| Live weighted joins | Shared indexed arrangements and collection joins | 1,024 Rust epochs in four runtime variants, including twice-entered shared indexes; shared-reader lifetime and self-join tests; bounded cursor/emission work with explicit output capabilities, including compaction while joins are unfinished |
| Reduce/count/threshold/distinct | Arbitrary-frontier compaction | 768 streamed Rust antichain epochs for collections, arrangements and entered views; 20,000 total-order and 5,000 incomparable-frontier retention epochs; unchanged keys cache pending corrections |
| Shared arrangements/imports/lookups/upsert | Implemented baseline | 1,024 Rust reader-compaction epochs, 8,192 Rust upsert records; live imports, deferred lookups, shared indexed joins and reductions tested |
| General operator builders/notifications/capabilities | Heterogeneous builders implemented | Multiple input/output types, summary-aware connectivity, borrowed input capabilities, notifications, local activators, build_reschedule and automatic callback retirement; 6,144 lifecycle rounds match Rust resource-lifetime behavior; thread-safe activators and broader scheduling interfaces remain |
| Nested scopes and iteration | Product nesting, custom refinements and identity regions implemented | 256 Rust feedback epochs and 256 cyclic graph fixed-point epochs; nested feedback cycles tested locally and across processes; 256 Rust epochs with signed-summary edges in advancing cycles |
| Multi-worker/distributed runtime | Cooperative groups and TCP process clusters | Globally counted serialized exchange and nested iteration tested in two and three native processes; 144 repeated nested-dataflow epochs across two/three processes; shared-memory parallel threads and asynchronous transport scheduling remain |
| Columnar/spilling/fueled trace variants | Fueled spine, columnar arrangements and pluggable spilling implemented | 1,024 partial-order batching epochs and 2,048 fueled spine epochs match Rust; columnar storage also checked against upstream columnar spines, 16,384 cursor steps, 1,024 nested join and 768 partial-order reduction epochs; 2,048 upstream spilled spine epochs, paged cursors/joins, corruption checks and native disk compaction tests; trie-native chunk transducers and columnar binary codecs remain |
| Capture/replay, logging, diagnostics | Partial | Capture protocol matches Rust in 256 cases; retryable capture writers and activated replay sources compare with Rust across 1,536 epochs; POSIX capture journals provide fsynced persistence and tailing with 268 truncation and 7 corruption checks; distributed replay matches upstream three-worker sources across 128 two/three-process epochs; logging and diagnostics remain |
| Graph and auxiliary algorithms | BFS, label propagation and SCC edges | 192 dynamic graph epochs against Rust and independent BFS/transitive closure, including duplicate edges and scheduled labels; generic Ring weights tested; arranged graph APIs reuse shared indexes across feedback; bidijkstra and sequential updates match 192 Rust epochs; prefix aggregate/broadcast match 192 Rust epochs; identifiers match 384 collision/retraction epochs |

## Completion gates

- Port upstream examples and behavior tests, recording intentional MoonBit API
  adaptations instead of silently dropping functionality.
- Compare incremental results and progress against pinned Rust for every operator
  family, including negative differences, incomparable times and nested loops.
- Exercise at least two workers and separate processes, including uneven input
  progress, exchange, closure, and transport ordering.
- Test compaction and reader/capability lifetimes under sustained updates; verify
  memory retention for optimized reductions and shared traces.
- Run native, JavaScript, Wasm and Wasm GC tests where the backend supports the
  required facilities. Native transport/runtime-specific tests need explicit
  target configuration; a passing single-worker suite is insufficient.
- Resolve the pending rows before describing this as a complete compatible port
  or creating the requested completed-port GitHub repository.

## Known implementation limits

Cooperative worker groups execute on one thread. ClusterWorker executes independent
processes with globally counted progress; TcpTransport provides framed, bounded
POSIX TCP I/O. Joins and nested fixed points pass against Rust and independent
oracles in two and three processes. The cluster uses synchronous all-gather rounds
and an independent wire protocol, not Timely wire interoperability. It does not
yet offer shared-memory parallel threads or asynchronous peer-to-peer scheduling.
Transport failures terminate the local runtime; reconnect/recovery is not implicit.
Fault injection covers truncation, oversized frames, timeouts, malformed text,
wrong peers and graph mismatches. Native workloads pass ASan and LSan locally, including 512 shared graph/import
epochs using row and columnar indexes, across normal closure and disposal with live input capabilities.

Reduction compacts history at arbitrary antichains but still enumerates a timestamp
join-closure. Trace cursors merge retained batch indexes lazily; lookups still scan snapshots.
16,384 cursor navigation steps match Rust, including seeks, rewinds and
per-batch timestamp enumeration. Composed frontier and data-dependent entry
views match Rust in 128 seeds; another 1,024 join epochs cover assigned inner
times across two nested scopes. Trace imports use the same retained views.
Arranged joins reuse shared sorted batch indexes with binary key lookup; collection
joins retain private keyed histories. Arranged reductions read shared key ranges and retain output corrections separately.
Arranged joins now expose a per-activation fuel budget and retain immutable views
for unfinished work. Full trace layouts, columnar chunk transducers and bounded
computation for the remaining operator families remain unfinished. Capture/replay supports nonblocking writer retries, explicit commit completion, cancellation,
and bounded activated sources. POSIX capture journals persist versioned checksummed frames and can replay complete
prefixes after interruption; missing terminal progress keeps replay incomplete.
Creation is exclusive and append calls fsync; automatic crashed-writer resumption
remains pending. Distributed replay broadcasts protocol messages and replicates
deduplication state on every peer, then partitions output records; it provides
global exactly-once reconstruction but does not yet implement upstream's
partitioned deduplication/count state. Journal encoding is independent of Rust serde.
The pinned Rust progress writer only retries inside its frontier-advance branch;
the port also retries queued progress when the frontier is unchanged, avoiding
a stalled terminal progress message. Its regression test uses a delayed final
message; the Rust oracle retries update writes and accepts progress immediately.

Built-in String ordering follows MoonBit (length-first), so lexical Rust behavior
requires a custom Compare implementation. Explicit release/close/dispose replace
Rust Drop semantics; APIs document ownership transfers and borrowed capabilities.

The pinned Rust spine rejects noncontiguous and zero-width insertions, despite
the generic Trace trait documentation describing automatic gap filling. The port
follows the pinned implementation: callers explicitly seal empty intervals.

Dynamic scopes preserve existing graph immutability. Completed built-in dataflow
tasks and topology metadata currently remain until worker disposal; automatic
whole-dataflow reclamation is still pending. Custom operator callbacks retire
independently once their completion conditions hold.
