# Full compatibility tracking

Completion target: the behavior of Differential Dataflow 0.25.1 at the pinned
commit, including the required Timely runtime. Idiomatic MoonBit APIs can differ
from Rust syntax and ownership APIs; semantic differences must remain explicit
until resolved. A small core port does not satisfy this target.

## Current evidence

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Lattice joins/meets and advance-by | Implemented for Int64 and generic products | Rust differential oracle; complete built-in timestamp family and summaries remain |
| Minimal/counted antichains | Implemented | 10,240 Rust and independent-oracle rounds |
| Change batches | Implemented | Signed cancellation and frontier tests |
| Difference algebra | Partial | Int/Int64, Present, custom semigroup/monoid/Abelian traits; remaining built-ins and convenience products remain |
| Sealed traces | Initial implementation | Snapshot, compaction, cursor, and sustained-update tests; not all upstream trace interfaces/layouts |
| Buffered input | Implemented callback and worker integration | Explicit close replaces Rust Drop; scoped resource ergonomics still needed |
| Worker scheduling | Single cooperative worker | Activation deduplication, re-entry guards, bounded queue storage tested |
| Unary and binary collection operators | Implemented baseline | Map/filter/flat-map/explode/negate/concat/consolidate and weighted join family |
| Live weighted joins | Implemented with keyed histories and compaction | 1,024 Rust epochs plus independent recomputation; reusable arrangements still needed |
| Reduce/count/threshold/distinct | Reference implementation | Partial-order synthetic-time and snapshot tests; optimized incremental implementation and Rust operator differential checks remain |
| Shared arrangements/imports/lookups/upsert | Pending | Must preserve trace reader capabilities, compaction, and reuse |
| General operator builders/notifications/capabilities | Pending | Existing source progress alone is insufficient for arbitrary user operators |
| Nested scopes and iteration | Pending | Must implement full progress reachability, timestamp summaries, feedback, and nested fixed points |
| Multi-worker/distributed runtime | Pending | Worker allocation, partitioning/exchange, serialization, TCP transport, distributed progress |
| Columnar/spilling/fueled trace variants | Pending | No compatibility or performance claim for these layouts |
| Capture/replay, logging, diagnostics | Pending | Structured probes alone do not cover upstream facilities |
| Graph and auxiliary algorithms | Pending | BFS, SCC, propagation and other upstream algorithms after iteration |

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

The current worker supports an acyclic graph built before execution. It has no
feedback, nested scopes, multi-worker execution, or network transport. Reduction
is an intentionally unoptimized reference algorithm that retains open-input
history. Trace cursors materialize a snapshot instead of borrowing upstream's
ordered trie containers. The current trace implementation is not a substitute
for the full family of trace layouts and shared arrangement capabilities.
