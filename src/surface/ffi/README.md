---
doc_radar:
  sentinels:
    - description: "C ABI session symbols stay exported from the package root"
      file: pkg/kernels/irregex/src/root.zig
      contains: ["export fn irregex_open", "export fn irregex_search", "export fn irregex_close"]
    - description: "public header mirrors the session surface"
      file: pkg/kernels/irregex/include/irregex.h
      contains: ["int32_t irregex_open(", "int32_t irregex_search(", "void irregex_close("]
---

# surface/ffi — in-process C-ABI search session (ADR-352 rung 3)

The package binding for non-Zig hosts. `session.zig` exposes
`irregex_open` / `irregex_search` / `irregex_close` so a caller (the Python `cffi` transport in
`bindings/python/irregex/_ffi.py`, or any C host) can hold one corpus warm **in its
own process** and stream match records over a callback — no subprocess, Unix
socket, `stdout`, or `exit`.

It is the in-process sibling of the socket-served resident daemon
([`../face/gist/daemon/serve`](../face/gist/daemon/serve)) and draws on the same shared
search core ([`../../kernel/match/query.zig`](../../kernel/match/query.zig)),
so an in-process answer is byte-identical to cold `gist --json` and to the UDS
daemon.

## Why this face exists

[ADR-352](../../../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md)
gates the C search ABI on one property: **a bad query must never terminate the
embedding host.** The whole warm path returns typed status codes instead of
calling `die()` / `exit`. `IRREGEX_STALE` means "answer cold"; it is never a
dead process. The cold CLI keeps its fatal shell; this path does not touch it.

## Shape

| Symbol                                         | Role                                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------------------ |
| `irregex_open(roots, nroots, out)`             | stand up a warm session (its own I/O + corpus + index)                         |
| `irregex_search(s, pattern, len, opts, cb, …)` | execute one complete size-checked shape and stream typed match/context records |
| `irregex_close(s)`                             | tear down corpus, index, I/O pool, and handle                                  |

The three `export fn` shims live in [`../../root.zig`](../../root.zig).
`contract.zig` owns stable statuses, flags, options, and `extern` layouts;
`relay.zig` translates resident records across the callback boundary; and
`session.zig` owns only handle lifecycle plus request execution. C declarations
mirror that contract in
[`../../../include/irregex.h`](../../../include/irregex.h), exercised by
the C-ABI smoke test in [`../../../build.zig`](../../../build.zig).

Every pointer handed to the callback (`path`, `line`, each submatch `text`)
aliases session/scratch memory valid **only** for that callback invocation —
the caller copies anything it keeps. Index _build_ stays a CLI verb; a session
searches the live tree.
