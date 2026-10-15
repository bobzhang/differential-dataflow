# Full compatibility tracking

Completion target: the behavior of Differential Dataflow 0.25.1 at the pinned
commit, including the required Timely runtime. Idiomatic MoonBit APIs can differ
from Rust syntax and ownership APIs; semantic differences must remain explicit
until resolved. A small core port does not satisfy this target.

## Current evidence

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Lattice joins/meets and advance-by | Common built-ins and products | Int32/Int64/UInt32/UInt64/Unit and generic products; small-width/128-bit integers and Duration remain |
| Minimal/counted antichains | Implemented | 10,240 Rust and independent-oracle rounds |
| Change batches | Implemented | Signed cancellation and frontier tests |
| Difference algebra | Partial | Signed/unsigned 32/64-bit, Present, pairs, custom algebra traits; remaining built-ins/tuple arities and convenience multiplication remain |
| Sealed traces | Initial implementation | Snapshots, compaction, cursors; not all upstream trace interfaces/layouts |
| Buffered input | Implemented callback and worker integration | Explicit close replaces Rust Drop |
| Worker scheduling | Cooperative workers | Counted scopes, activation deduplication, re-entry guards, bounded queues, disposal tests |
| Unary and binary collection operators | Implemented baseline | Map/filter/flat-map/explode/negate/concat/consolidate and weighted join family |
| Live weighted joins | Shared indexed arrangements and collection joins | 1,024 Rust epochs in three runtime variants; shared-reader lifetime and self-join tests |
| Reduce/count/threshold/distinct | Arbitrary-frontier compaction | 768 streamed Rust antichain epochs; 20,000 total-order and 5,000 incomparable-frontier retention epochs; incremental per-key optimization remains |
| Shared arrangements/imports/lookups/upsert | Implemented baseline | 1,024 Rust reader-compaction epochs, 8,192 Rust upsert records; live imports, deferred lookups and shared indexed joins tested; arranged reductions remain |
| General operator builders/notifications/capabilities | Heterogeneous builders implemented | Multiple input/output types, summary-aware connectivity, borrowed input capabilities, notifications; activators and broader scheduling interfaces remain |
| Nested scopes and iteration | Product nesting and fixed points implemented | 256 Rust feedback epochs and 256 cyclic graph fixed-point epochs; general Refines and negative-summary cases remain |
| Multi-worker/distributed runtime | Cooperative groups and TCP process clusters | Globally counted serialized exchange and nested iteration tested in two and three native processes; shared-memory parallel threads and asynchronous transport scheduling remain |
| Columnar/spilling/fueled trace variants | Pending | No compatibility or performance claim for these layouts |
| Capture/replay, logging, diagnostics | Partial | Capture protocol and reordering iterator match Rust in 256 cases; async durable sources/sinks, distributed replay, logging and diagnostics remain |
| Graph and auxiliary algorithms | Pending | Generic iteration is tested with cyclic graph reachability; dedicated upstream algorithm APIs remain |

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
wrong peers and graph mismatches. Native workloads pass ASan and LSan locally.

Reduction compacts history at arbitrary antichains but still enumerates a timestamp
join-closure. Trace cursors materialize snapshots and lookups scan snapshots.
Arranged joins reuse shared sorted batch indexes with binary key lookup; collection
joins retain private keyed histories. Full trace layouts, arranged reductions and
fueled computation remain unfinished. Capture/replay currently has a synchronous
callback/message interface and no durable or distributed replay protocol.

Built-in String ordering follows MoonBit (length-first), so lexical Rust behavior
requires a custom Compare implementation. Explicit release/close/dispose replace
Rust Drop semantics; APIs document ownership transfers and borrowed capabilities.
