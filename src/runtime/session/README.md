<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/runtime/session/resident.zig
    - pkg/kernels/irregex/src/runtime/session/corpus.zig
    - pkg/kernels/irregex/src/runtime/session/render.zig
    - pkg/kernels/irregex/src/runtime/session/request.zig
    - pkg/kernels/irregex/src/runtime/session/protocol.zig
    - pkg/kernels/irregex/src/runtime/session/watch.zig
    - pkg/kernels/irregex/src/runtime/session/dirty.zig
    - pkg/kernels/irregex/src/runtime/session/delta.zig
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["[session]", "eligible_modes", "fail-closed-reconcile", "\"lines\""]
    - file: pkg/kernels/irregex/src/runtime/session/protocol.zig
      contains: ["chunk = 11", "protocol_version: u8 = 1"]
    - file: pkg/kernels/irregex/src/runtime/session/dirty.zig
      contains: ["armExact", "noteDoubt"]
    - file: pkg/kernels/irregex/src/runtime/session/delta.zig
      contains: ["needs_full", "keyIsCurrent"]
-->

# `src/runtime/session/` — the resident search session (ADR-352 rung 2.5)

The warm, in-memory engine behind the `gist serve` daemon. It productizes the
in-memory bench path (`bench/harness/bench.zig::gistMatches`) as a real
per-repository service: the corpus bytes + trigram index are held resident, so
an eligible request answers without re-paying the cold subprocess's process +
index-mmap + candidate-read startup. It selects its corpus with the cold path's
own certified rg-default walk (`runtime/cold/engine/serial.zig::defaultFileSet`),
ingests each file exactly as a cold read would (`corpus.zig`), and lowers each
query through the shared search core (`engine/query.zig` over `index/trigram`,
`scan/verify`, `scan/simd`, `regex/core`) — but every entry point **returns
errors** instead of calling `die()`, which is exactly why the resident path
sidesteps the exit hazard ADR-352 defers the in-process C FFI on.

| File                           | Role                                                                                                                                                                                                                                                                                                                                                                                                                  |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`resident.zig`](resident.zig) | `ResidentSession`: mirror + index, mutation overlay, generation reload, the fail-closed reconcile barrier, and the three answer faces — the `-l`/`-c` fold (`query`), the default line search (`queryLines`), and the FFI record stream (`search`).                                                                                                                                                                   |
| [`corpus.zig`](corpus.zig)     | The faithful corpus ingest: full reads (no cap), BOM/UTF-16 decode, whole-body first-NUL offsets, empty docs dropped — the same per-file treatment a cold run applies, so binary/oversize/UTF-16 files answer warm exactly as they do cold.                                                                                                                                                                           |
| [`render.zig`](render.zig)     | The warm `lines` renderer: the default `path:text` / `-n` `path:line:text` frame, produced through the cold engine's **own** `Emitter` + `grepfile.handleBinary` — byte-parity by construction, never a re-derived formatter.                                                                                                                                                                                         |
| [`request.zig`](request.zig)   | The eligibility classifier — accepts only the supported argv surface (bare pattern → `lines`, `-l`/`-c`, `-F`, `-i`, `-n`/`-N`, `-e`/`--regexp`; **rootless only** — any explicit PATH arg, even `.`, stays cold), everything else → `error.Unsupported` (cold fallback).                                                                                                                                             |
| [`protocol.zig`](protocol.zig) | The length-prefixed UDS frame codec (`[u32 len][u8 opcode][payload]`) + fd send/recv, fail-closed on oversized/truncated/unknown frames. A `lines` answer streams as `chunk` frames + a terminal `result` (additive; protocol stays v1).                                                                                                                                                                              |
| [`watch.zig`](watch.zig)       | The freshness watcher — a pure accelerator (Linux inotify · macOS FSEvents; reconcile-always baseline on other targets) that only ever decides _whether — and how narrowly — the reconcile walk may run_, never correctness. FSEvents runs with per-file events and feeds the exact dirty log; inotify stays coarse (never arms exactness) and poisons the session on queue overflow or an unwatchable new directory. |
| [`dirty.zig`](dirty.zig)       | The exact dirty-path log: a bounded, deduped set of watcher-reported paths plus two soundness bits — `exact` (the backend promises every dirty bump was preceded by a note) and `doubt` (overflow / OOM / unattributable event ⇒ the next reconcile walks fully). The O(changed) hand-off between backend and reconcile.                                                                                              |
| [`delta.zig`](delta.zig)       | The O(changed) resolver: maps one drained batch of absolute watcher paths into walk-certified verdicts (`file`/`subtree`/`gone`/`skip`/`needs_full`) using the cold walk's **own** `Ignore` machinery, so a scoped reconcile cannot drift from `defaultFileSet`. Ignore-source edits, `.git` topology, unmapped or non-ASCII paths all answer `needs_full`.                                                           |

## The invariant

`resident matches == gist --no-index matches == rg matches`. It holds by
construction because both the base corpus and every reconcile re-derive their
file set from the cold path's own certified walk
(`runtime/cold/engine/serial.zig::defaultFileSet` — hidden-file exclusion,
`.gitignore`/`.ignore` precedence, `.git` skip, root scope), never
`haystack`'s coarse superset — and because per-file ingest is cold's own
(`corpus.zig`): a binary doc is **admitted** with its first-NUL offset and each
mode applies cold's binary rule (`-l` observes only complete buffers before the
NUL one; `-c` suppresses the file; the line search emits pre-cut matches + the
WARNING), rather than being skipped by an approximate sniff. A query is
answered from resident bytes directly only in a watcher-proven-clean window;
otherwise the session reconciles before answering — **scoped** when it can
prove the drained dirty-path set covers every possible divergence (an exact
per-file backend, a doubt-free bounded log, one prior covering full pass, no
ignore-semantics path in the batch: verify exactly those paths via `delta.zig`
against the walk's own admission rules), else **full** (re-walk the
authoritative set and diff it against base + overlay: left the set →
tombstone; new → read in; mtime/ctime advanced → re-read). Every scoped-path
refusal degrades to the full walk — never to trusting stale bytes. A delete
that races the walk→report window is caught
by a per-match existence check whenever the session is not watcher-clean. A
rebuilt index (`pair.gen` drift) or an errored walk (unreadable directory —
cold reports it and exits 2) surfaces as `error.Stale`, and the daemon declines
so the client uses the certified cold path.

The daemon lifecycle, CLI routing, and clients live in
[`../../cli/gist/daemon/serve`](../../cli/gist/daemon/serve) and
[`../../cli/gist/daemon/client`](../../cli/gist/daemon/client); the persistent
client→daemon performance certificate lives in
[`../../../bench/session`](../../../bench/session).
