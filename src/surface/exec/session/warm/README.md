<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/surface/exec/session/warm/resident.zig
    - pkg/kernels/irregex/src/surface/exec/session/warm/recall.zig
    - pkg/kernels/irregex/src/surface/exec/session/warm/corpus.zig
    - pkg/kernels/irregex/src/surface/exec/session/warm/overlay.zig
  sentinels:
    - file: pkg/kernels/irregex/src/surface/exec/session/warm/resident.zig
      contains:
        [
          "pub const query = fold.query",
          "pub const queryLines = present.queryLines",
          "pub const queryExists = stream.queryExists",
          "pub const search = stream.search",
          "pub fn beginRead",
        ]
-->

# `warm/` — the resident engines and the state they hold warm

Two sibling warm engines live here, one per face of the kernel, plus the byte
stores they answer out of. What makes this a single concern is ownership: every
module in this folder holds something **across** queries. Nothing here decides
what an answer looks like — that is [`../facet/`](../facet) — and nothing here
proves the held state still matches the disk — that is
[`../freshness/`](../freshness).

| Module                         | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`resident.zig`](resident.zig) | `ResidentSession` — the session **state**: the mirror + trigram index bound at `init`, the mutation overlay, the freshness seqlock + exact dirty log, and `beginRead`, the read lease every answer passes through (answer under the shared lease while the watcher proves the tree clean; else drop to exclusive, reconcile, downgrade). The engine's behavior lives in the sibling folders and is bound back as real methods by a decl-alias table at the struct's foot, so a caller still writes `sess.query(…)` and the module still owns its whole surface.                                                                                                     |
| [`recall.zig`](recall.zig)     | `RetrievalSession` — the sibling warm session for **relate** search/pack. It holds one repo's mmap'd trigram index + doc→path table warm and answers through the shared `surface/exec/cold/engine/retrieval.zig` kernel, so warm ≡ cold. Unlike the byte-mirroring resident above, its freshness is the persisted index's build **anchor** (`fresh.readAnchor`), so the overlay is cacheable while the watcher proves the roots quiescent. Fail-closed to a cold answer on any doubt.                                                                                                                                                                               |
| [`corpus.zig`](corpus.zig)     | The faithful corpus ingest as a **two-tier byte store**: an unchanged member binds its bytes to the persisted `content.shard` mmap (zero heap, page-cache-evictable); a changed/new/binary/oversize/BOM-carrying doc — or the whole corpus when no shard exists — heap-reads. Either tier applies cold's own per-file treatment (full reads, no cap; BOM/UTF-16 decode; whole-body first-NUL offsets; empty docs dropped), so binary/oversize/UTF-16 files answer warm exactly as they do cold while resident heap drops from O(corpus) to O(churn + exceptions). Also home to `gatedBody`, the single authority on how far into a binary document a mode may look. |
| [`overlay.zig`](overlay.zig)   | The mutation store — how a live tree edit becomes an answerable substitution without rebuilding the base mirror: gpa-owned replacement docs and tombstones keyed by path, one chokepoint (`put`) that also maintains the macOS non-ASCII twin set the scoped sweep needs, and `readInto`, the cold-identical re-read of a single changed file (an empty or vanished file tombstones rather than mirroring a lie).                                                                                                                                                                                                                                                   |
| [`truth.zig`](truth.zig)       | An independent filesystem oracle for the adversarial tests below — a naive re-read that never runs the engine, so a backend bug cannot hide behind the engine that produced it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |

`resident_test.zig` and `scoped_test.zig` sit beside their subject: parity
against a cold run, overlay and read-your-writes behavior, and the scoped
reconcile checked against full-walk ground truth.

## Why the two engines don't share a base type

They hold different things. `resident` mirrors corpus **bytes** and reconciles a
moving cursor over them; `recall` never holds file contents at all and reasons
about a persisted index's build anchor. They genuinely share only the freshness
primitives ([`../freshness/`](../freshness)) and the watcher
([`../watch/`](../watch)), which they import directly — so a common supertype
would abstract over a similarity that isn't there.
