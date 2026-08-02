---
doc_radar:
  sentinels:
    - description: "C ABI session symbols stay exported from the package root"
      file: src/root.zig
      contains: ["export fn gist_open", "export fn gist_search", "export fn gist_close", "export fn gist_run"]
    - description: "public header declares the session surface and includes the substrate"
      file: include/gist.h
      contains: ["int32_t gist_open(", "int32_t gist_search(", "void gist_close(", "int32_t gist_run(", "#include <irgx.h>"]
    - description: "gist's contract keeps search-owned types and re-exports the substrate"
      file: src/surface/ffi/contract.zig
      contains: ["pub const SearchOptions", "pub const SearchRequest", "pub const flag_quiet", "const substrate"]
    - description: "push entry points never terminate the embedding host"
      file: src/surface/ffi/session.zig
      absent: ["std.process.exit", "@panic", "catch unreachable"]
    - description: "pull entry points never terminate the embedding host"
      file: src/surface/ffi/cursor.zig
      absent: ["std.process.exit", "@panic", "catch unreachable"]
    - description: "the seam's adverse allocation-failure suite drives the entry under a failing allocator"
      file: src/surface/ffi/oom_test.zig
      contains: ["FailingAllocator", "session.openWith", "OutOfMemory"]
---

# surface/ffi — in-process C-ABI search session

The package binding for non-Zig hosts. `session.zig` exposes
`gist_open` / `gist_search` / `gist_close` so a caller (the Python `cffi`
transport in `bindings/python/gist/runtime/native.py`, or any C host) can hold
one corpus warm **in its own process** and stream match records over a callback
— no subprocess, Unix socket, `stdout`, or `exit`.

It is the in-process sibling of the socket-served resident daemon
([`../../exec/session/daemon/serve`](../../exec/session/daemon/serve)) and draws
on the same shared search core in the `irregex` package, so an in-process answer
is byte-identical to cold `gist --json` and to the UDS daemon.

## Why this face exists

The C search ABI is gated on one property: **a bad query must never terminate the
embedding host.** The whole warm path returns typed status codes instead of
calling `die()` / `exit`. `IRGX_STALE` means "answer cold"; it is never a
dead process. The cold CLI keeps its fatal shell; this path does not touch it.

## Shape

Two planes share the session handle. The **exact plane** streams match records
through a push callback (or a pull cursor). The **rank producer** materializes
the definition-first view of an exact query into a pull cursor of
self-describing rows — produced here, walked by `libirgx`. Kinship and
sweep live in `librelate`; compose lives in `libblast`.

### Exact plane

| Symbol | Role |
| --- | --- |
| `gist_open` / `gist_search` / `gist_close` | push-callback warm session |
| `gist_engine_open` / `gist_search_cursor` / `gist_cursor_*` | pull-cursor sibling |

### Rank producer

| Symbol | Role |
| --- | --- |
| `gist_run(engine, GIST_OP_RANK, params, cancel, out)` | materialize rank into an `irgx_rows *` |
| `irgx_rows_next` / `_next_batch` / `_stats` / `_close` | walk that cursor (`libirgx`) |

A verb this build cannot answer in-process returns `IRGX_STALE`. Bindings
shell the CLI for that verb unchanged. An op this library does not own is
`IRGX_INVALID`.

### Files

The `export fn` shims live in [`../../root.zig`](../../root.zig).

| File | Owns |
| --- | --- |
| `session.zig` | Handle lifecycle + exact-plane request execution |
| `contract.zig` | Search-owned types + flags; re-exports substrate status/fault |
| `relay.zig` | Translates resident match records across the callback boundary |
| `cursor.zig` | Exact-plane pull cursor |
| `analytic.zig` | Rank dispatch — builds an `irregex.ffi.answer.Answer` |
| `oom_test.zig` | Adverse allocation-failure suite |

Row layout, schema table, and the answer cursor live in
`@import("irregex").ffi` (`rows` / `answer`). C declarations mirror
[`../../../include/gist.h`](../../../include/gist.h).

## Error channels

Status codes and the last-fault pull are substrate vocabulary from
`libirgx` (`IRGX_OK` … `IRGX_INVALID`, `irgx_last_fault`). This
package translates search failures into that vocabulary once, in
`contract.zig`'s re-exported `report` / `beginCall` helpers.
