---
doc_radar:
  sentinels:
    - description: "index verb still generation-publishes index + paths + freshness anchor"
      file: pkg/kernels/irregex/src/cli/gist/lifecycle/index.zig
      contains:
        - "persist.persistIndexAndPaths"
        - "fresh.writeAnchor"
        - "Index.build"
    - description: "codex verb group persists + queries the self-index shelf"
      file: pkg/kernels/irregex/src/cli/gist/lifecycle/codex.zig
      contains:
        - "codex.shelf"
        - "Shelf.build"
        - "fresh.changedSince"
---

# cli/gist/lifecycle — `gist index` · `gist codex`

The *mutating* lifecycle actions. Everything else in the CLI is read-only
against the live tree or the artifacts these verbs publish.

## `gist index` — the trigram tier

`index.zig::run` walks the configured corpus roots, builds the trigram `Index`,
and generation-publishes three things into `.local/gist-verify/`:

1. the mmap-friendly index blob
2. the doc-id → path table (NUL-separated, doc-id order)
3. the T3 freshness wall-clock anchor (`index/trigrams/fresh.zig`)

Publish is pair-atomic: both blobs stage under `gens/<id>/`, then `pair.gen`
flips, so a concurrent loader never sees a mixed old/new pair. The anchor is
captured *before* the corpus read, so a file touched during the build has
mtime ≥ anchor and is re-verified on the next query.

**Who consumes it.** The unified engine's read-elision path
([`runtime/cold/engine/serial.zig`](../../../runtime/cold/engine/serial.zig)
`IndexSkip`) and the `--rank` view
([`runtime/cold/engine/ranked.zig`](../../../runtime/cold/engine/ranked.zig))
mmap these artifacts. A missing index is never fatal for search — the engine
live-scans — but `gist status` reports it as an actionable `unavailable` state.
See [`../status/`](../status) for the matching read-only verb.

## `gist codex` — the exact existence/count tier

`codex.zig` owns the verb group over the compressed self-index shelf
([`src/index/codex/shelf.zig`](../../../index/codex/README.md)): `build` loads the
same index corpus, builds the FM-index shelf, and writes `codex.shelf`
atomically (temp-then-rename); `count` / `tally` / `status` are read-only
queries against it. Where the trigram index nominates *candidate* files
(false positives possible; a read verifies), the codex *answers*: `count == 0`
with a clean freshness walk is a proof of absence across the corpus with
zero corpus I/O. The shelf carries its own build anchor; every query verb
stat-walks the roots against it (`fresh.changedSince`) and reports how many
files changed since the build. `relate quote` reads the same artifact.
