---
doc_radar:
  sentinels:
    - description: "index verb still generation-publishes index + paths + freshness anchor"
      file: pkg/kernels/irregex/src/surface/face/gist/lifecycle/index.zig
      contains:
        - "persist.persistIndexAndPaths"
        - "fresh.writeAnchor"
        - "Index.build"
    - description: "codex verb group persists + queries the self-index shelf"
      file: pkg/kernels/irregex/src/surface/face/gist/lifecycle/codex.zig
      contains:
        - "codex.shelf"
        - "Shelf.build"
        - "fresh.changedSince"
---

# surface/face/gist/lifecycle — `gist index` · `gist codex`

The _mutating_ lifecycle actions. Everything else in the CLI is read-only
against the live tree or the artifacts these verbs publish.

## `gist index` — the trigram tier

`index.zig::run` walks the corpus roots, builds the trigram `Index`, and
generation-publishes four things into `.local/gist-verify/`:

1. the mmap-friendly index blob
2. the doc-id → path table (NUL-separated, doc-id order)
3. the build roots (`roots.list`, NUL-separated) — queries and freshness
   walks scope to _these_, so an index built anywhere stays self-describing
4. the T3 freshness wall-clock anchor (`corpus/index/trigrams/fresh.zig`)

Roots are never hardcoded: `gist index [ROOT...]` takes them positionally,
else `corpus.resolveRoots` picks them per tree — `GIST_ROOTS` env override
(`:`/`,`/space separated), else `.` (the whole tree; the skip-dir policy
still prunes VCS/build output). A legacy pre-`roots.list` cache falls back
to `.` on load — a sound superset (elision keys on the persisted path set,
never on roots). The artifact home itself is `GIST_DIR`-relocatable
(default `.local/gist-verify`).

The skip-dir policy is generic the same way: the built-in list is
cross-ecosystem names only (VCS dirs, package caches, build output —
`corpus/tree/haystack.zig::skip_dirs`), and a project's own heavy dirs
extend it via `GIST_SKIP` (env, `:`/`,`/space separated) or the per-tree
config `<GIST_DIR>/skips.list` (one name per line, `#` comments). Both scope
only the corpus walks (index build, freshness, relate) — rg-mode search
keeps pure gitignore parity and ignores them.

Publish is pair-atomic: both blobs stage under `gens/<id>/`, then `pair.gen`
flips, so a concurrent loader never sees a mixed old/new pair. The anchor is
captured _before_ the corpus read, so a file touched during the build has
mtime ≥ anchor and is re-verified on the next query.

**Who consumes it.** The unified engine's read-elision path
([`surface/exec/cold/engine/serial.zig`](../../../exec/cold/engine/serial.zig)
`IndexSkip`) and the `--rank` view
([`surface/exec/cold/engine/ranked.zig`](../../../exec/cold/engine/ranked.zig))
mmap these artifacts. A missing index is never fatal for search — the engine
live-scans — but `gist status` reports it as an actionable `unavailable` state.
See [`../status/`](../status) for the matching read-only verb.

## `gist codex` — the exact existence/count tier

`codex.zig` owns the verb group over the compressed self-index shelf
([`src/corpus/index/codex/shelf.zig`](../../../../corpus/index/codex/README.md)): `build` loads the
same index corpus, builds the FM-index shelf, and writes `codex.shelf`
atomically (temp-then-rename); `count` / `tally` / `status` are read-only
queries against it. Where the trigram index nominates _candidate_ files
(false positives possible; a read verifies), the codex _answers_: `count == 0`
with a clean freshness walk is a proof of absence across the corpus with
zero corpus I/O. The shelf carries its own build anchor; every query verb
stat-walks the roots against it (`fresh.changedSince`) and reports how many
files changed since the build. `relate quote` reads the same artifact.
