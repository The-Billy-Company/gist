<!--
doc_radar:
  counts:
    - glob: pkg/kernels/irregex/src/surface/exec/session/*/
      equals: 6
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["[session]", "eligible_modes", "fail-closed-reconcile", "\"lines\""]
-->

# `src/surface/exec/session/` — the resident search session (ADR-352 rung 2.5)

The warm, in-memory engine behind the `gist serve` daemon. It productizes the
in-memory bench path (`bench/harness/bench.zig::gistMatches`) as a real
per-repository service: the corpus bytes + trigram index are held resident, so
an eligible request answers without re-paying the cold subprocess's process +
index-mmap + candidate-read startup. It selects its corpus with the cold path's
own certified rg-default walk (`surface/exec/cold/engine/serial.zig::defaultFileSet`),
ingests each file exactly as a cold read would, and lowers each query through the
shared search core (`kernel/match/query.zig` over `corpus/index/trigrams`,
`scan/verify`, `scan/simd`, `regex/core`) — but every entry point **returns
errors** instead of calling `die()`, which is exactly why the resident path
sidesteps the exit hazard ADR-352 defers the in-process C FFI on.

## The six planes

Read them in this order; each answers a different question.

| Folder | The question it answers |
|---|---|
| [`answer/`](answer) | What may be asked warm, what comes back, and the one candidate walk between them. The contract a consumer can read without opening an engine. |
| [`warm/`](warm) | What is held **across** queries — both resident engines (gist's byte mirror, relate's index session), the two-tier corpus store, and the mutation overlay. |
| [`facet/`](facet) | The four faces one answer can wear: a set, a count, finished bytes, or a record stream. Formats nothing itself — it borrows the cold path's own renderer. |
| [`freshness/`](freshness) | May the session serve the bytes it already holds? The fail-closed barrier, its seqlock, the exact dirty log, and the O(changed) resolver. |
| [`watch/`](watch) | Can that barrier skip the walk — and how narrowly? A pure accelerator (Linux inotify · macOS kqueue), never a correctness dependency. |
| [`conduit/`](conduit) | How a request reaches the daemon and an answer gets back: the UDS frame grammar, the shm carrier, and daemon auto-spawn. |

Tests live beside the code they exercise, and each folder's own `README.md`
carries its per-module table.

## The invariant

`resident matches == gist --no-index matches == rg matches`. It holds by
construction because both the base corpus and every reconcile re-derive their
file set from the cold path's own certified walk
(`surface/exec/cold/engine/serial.zig::defaultFileSet` — hidden-file exclusion,
`.gitignore`/`.ignore` precedence, `.git` skip, root scope), never
`haystack`'s coarse superset — and because per-file ingest is cold's own
(`warm/corpus.zig`): a binary doc is **admitted** with its first-NUL offset and each
mode applies cold's binary rule (`-l` observes only complete buffers before the
NUL one; `-c` suppresses the file; the line search emits pre-cut matches + the
WARNING), rather than being skipped by an approximate sniff. A query is
answered from resident bytes directly only in a watcher-proven-clean window;
otherwise the session reconciles before answering — **scoped** when it can
prove the drained dirty-path set covers every possible divergence (an exact
per-file backend, a doubt-free bounded log, one prior covering full pass, no
ignore-semantics path in the batch: verify exactly those paths via
`freshness/delta.zig` against the walk's own admission rules), else **full**
(re-walk the authoritative set and diff it against base + overlay: left the set →
tombstone; new → read in; mtime/ctime advanced → re-read). Every scoped-path
refusal degrades to the full walk — never to trusting stale bytes. A delete
that races the walk→report window is caught
by a per-match existence check whenever the session is not watcher-clean. A
rebuilt index (`pair.gen` drift) or an errored walk (unreadable directory —
cold reports it and exits 2) returns
`fault.Answer(T){ .declined = .freshness_unprovable }`, and the daemon sends a
decline frame so the client uses the certified cold path. Allocation exhaustion
remains `error.OutOfMemory`.

The daemon lifecycle, CLI routing, and clients live in
[`../../face/gist/daemon/serve`](../../face/gist/daemon/serve) and
[`../../face/gist/daemon/client`](../../face/gist/daemon/client); the persistent
client→daemon performance certificate lives in
[`../../../../bench/session`](../../../../bench/session).
