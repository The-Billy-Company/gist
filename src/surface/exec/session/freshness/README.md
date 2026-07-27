<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/surface/exec/session/freshness/reconcile.zig
    - pkg/kernels/irregex/src/surface/exec/session/freshness/seqlock.zig
    - pkg/kernels/irregex/src/surface/exec/session/freshness/dirty.zig
    - pkg/kernels/irregex/src/surface/exec/session/freshness/delta.zig
    - pkg/kernels/irregex/src/surface/exec/session/freshness/annals.zig
  sentinels:
    - file: pkg/kernels/irregex/src/surface/exec/session/freshness/dirty.zig
      contains: ["armExact", "noteDoubt"]
    - file: pkg/kernels/irregex/src/surface/exec/session/freshness/delta.zig
      contains: ["needs_full", "keyIsCurrent"]
-->

# `freshness/` — the fail-closed barrier that earns the warm answer

This folder answers exactly one question, and answers it conservatively: _may the
session serve from the bytes it already holds?_ Everything here exists so that
`resident matches == gist --no-index matches == rg matches` holds by
construction. The watcher that lets the answer be cheap is a separate, purely
optional accelerator ([`../watch/`](../watch)); the correctness lives here.

| Module                           | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`reconcile.zig`](reconcile.zig) | The fail-closed read-your-writes barrier — the session's **only** writer, and the reason a warm answer cannot drift from a cold one: generation reload (`pair.gen` drift ⇒ rebuild the engine, or decline), the scoped O(changed) pass over a drained exact dirty batch, the full re-walk it degrades to on any refusal, and `guardExtras`, which declines the two requests that reach past the mirror: a `-t`/`-g` query whose un-hidden/un-ignored candidates it structurally cannot hold, and a positional root the default walk pruned (hidden or gitignored) that cold still searches because naming a root exempts it. |
| [`seqlock.zig`](seqlock.zig)     | The freshness seqlock both warm engines share — the lock-free clean/dirty bit and its ordering contract, so no session ever touches a raw atomic. `clean` is set only under `eligible`, and any event clears it.                                                                                                                                                                                                                                                                                                                                                                                                             |
| [`dirty.zig`](dirty.zig)         | The exact dirty-path log: a bounded, deduped set of watcher-reported paths plus two soundness bits — `exact` (the backend promises every dirty bump was preceded by a note) and `doubt` (overflow / OOM / unattributable event ⇒ the next reconcile walks fully). The O(changed) hand-off between backend and reconcile.                                                                                                                                                                                                                                                                                                     |
| [`delta.zig`](delta.zig)         | The O(changed) resolver: maps one drained batch of absolute watcher paths into walk-certified verdicts (`file`/`subtree`/`gone`/`skip`/`needs_full`) using the cold walk's **own** `Ignore` machinery, so a scoped reconcile cannot drift from `defaultFileSet`. Ignore-source edits, `.git` topology, and unmappable paths answer `needs_full`; non-ASCII paths ARE scoped through the `realpath` oracle, with the session sweeping its non-ASCII keys via `keyIsCurrent` to retire a stale normalization/case twin.                                                                                                        |
| [`annals.zig`](annals.zig)       | The journal that hands the watcher's changed set to the session across a restart, stored **repo-relative** so an armed absolute root never leaks into the record. Replayed in the same fail-closed posture: every uncertainty degrades to a full walk.                                                                                                                                                                                                                                                                                                                                                                       |

`freshness_test.zig` sits beside its subject — differential checks against an
on-disk oracle, concurrency, and the overflow/bound edges.

## Fail-closed is the design, not the error handling

A rebuilt index, a reconcile allocation failure, or a **walk error** (an
unreadable directory — cold reports it and exits 2, so a warm answer over a
silently gapped set would lie) all decline with `freshness_unprovable`, and the
client falls back to the certified cold path. Every scoped-path refusal degrades
to the full walk — never to trusting stale bytes. The cheap path is only ever
taken when the barrier can _prove_ the roots were quiescent.

## Concurrency shape

Reads overlap under a shared `Ward` lease (`kernel/primitives/ward.zig`) while a
reconcile runs alone under the exclusive lease. The watcher only ever touches the
shared seqlock and the dirty log, never the overlay — so the barrier is a
lock-free seqlock over a ward-guarded engine. `dirty.zig` and `annals.zig` guard
their sets with the shared `primitives/ward.zig::Latch`, whose critical sections
are small enough that a spin beats parking.
