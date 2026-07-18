---
doc_radar:
  sentinels:
    - description: "index verb still generation-publishes index + paths + freshness anchor"
      file: pkg/kernels/irregex/src/gist/faces/cli/lifecycle/index.zig
      contains:
        - "persist.persistIndexAndPaths"
        - "fresh.writeAnchor"
        - "Index.build"
---

# gist/faces/cli/lifecycle — `gist index`

The one *mutating* lifecycle action. Everything else in the CLI is read-only
against the live tree or the artifacts this verb publishes.

`index.zig::run` walks the configured corpus roots, builds the trigram `Index`,
and generation-publishes three things into `.local/gist-verify/`:

1. the mmap-friendly index blob
2. the doc-id → path table (NUL-separated, doc-id order)
3. the T3 freshness wall-clock anchor (`kernel/index/fresh.zig`)

Publish is pair-atomic: both blobs stage under `gens/<id>/`, then `pair.gen`
flips, so a concurrent loader never sees a mixed old/new pair. The anchor is
captured *before* the corpus read, so a file touched during the build has
mtime ≥ anchor and is re-verified on the next query.

**Who consumes it.** The unified engine's read-elision path
([`../search/engine/serial.zig`](../search/engine/serial.zig) `IndexSkip`) and
the `--rank` view ([`../search/engine/ranked.zig`](../search/engine/ranked.zig))
mmap these artifacts. A missing index is never fatal for search — the engine
live-scans — but `gist status` reports it as an actionable `unavailable` state.
See [`../status/`](../status) for the matching read-only verb.
