---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/src/exec/session/reconcile/dirty.zig
      contains: ["armExact", "noteDoubt"]
    - file: pkg/kernels/irregex/src/exec/session/reconcile/delta.zig
      contains: ["needs_full", "keyIsCurrent"]
    - description: "leases live on the math floor"
      file: pkg/kernels/irregex/src/kernel/math/lease.zig
      contains: ["pub const Ward", "pub const Latch"]
---

# `reconcile/` — may the session serve the bytes it already holds?

The fail-closed barrier that earns a warm answer. Renamed from `freshness/`
so the barrier is the identity (and so it never puns with
[`corpus/fresh/`](../../../corpus/fresh/) — the artifact-clock law). Everything
here exists so `resident matches == gist --no-index matches == rg matches`
holds by construction. The watcher that makes the answer cheap is a separate,
optional accelerator ([`../watch/`](../watch/)); the correctness lives here.

| Module | Role |
| ------ | ---- |
| `reconcile.zig` | The session’s **only** writer: generation reload, scoped O(changed) pass, full re-walk on refusal, `guardExtras` for queries that reach past the mirror |
| `seqlock.zig` | Freshness seqlock both warm engines share — lock-free clean/dirty bit |
| `dirty.zig` | Exact dirty-path log + `exact` / `doubt` soundness bits |
| `delta.zig` | O(changed) resolver using cold’s own `Ignore` machinery |
| `annals.zig` | Journal of the watcher’s changed set across a restart |

Suites: `reconcile_test.zig` (barrier vs on-disk oracle) and `vouch_test.zig`
(real watcher backends — kqueue / inotify).

## Fail-closed is the design

A rebuilt index, a reconcile allocation failure, or a walk error declines with
`freshness_unprovable`; the client falls back to the certified cold path.
Every scoped-path refusal degrades to the full walk — never to trusting stale
bytes.

## Concurrency shape

Reads overlap under a shared `Ward` lease (`kernel/math/lease.zig`) while a
reconcile runs alone under the exclusive lease. `dirty.zig` and `annals.zig`
guard their sets with `Latch` from the same file.
