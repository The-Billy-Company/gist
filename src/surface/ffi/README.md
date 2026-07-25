---
doc_radar:
  sentinels:
    - description: "C ABI session symbols stay exported from the package root"
      file: pkg/kernels/irregex/src/root.zig
      contains: ["export fn irregex_open", "export fn irregex_search", "export fn irregex_close"]
    - description: "public header mirrors the session surface plus the last-fault pull"
      file: pkg/kernels/irregex/include/irregex.h
      contains: ["int32_t irregex_open(", "int32_t irregex_search(", "void irregex_close(", "int32_t irregex_last_fault("]
    - description: "the seam owns the one Fault → Status translation and the pull that carries the detail (ADR-373 law 7)"
      file: pkg/kernels/irregex/src/surface/ffi/contract.zig
      contains: ["pub fn ofFault", "pub fn disposition", "pub fn lastFault"]
    - description: "ADR-373 law 6: the push entry points never terminate the embedding host"
      file: pkg/kernels/irregex/src/surface/ffi/session.zig
      absent: ["std.process.exit", "@panic", "catch unreachable"]
    - description: "ADR-373 law 6: the pull entry points never terminate the embedding host"
      file: pkg/kernels/irregex/src/surface/ffi/cursor.zig
      absent: ["std.process.exit", "@panic", "catch unreachable"]
    - description: "ADR-373 rung 1: the cold file-set walk the warm session reuses answers OOM with a value"
      file: pkg/kernels/irregex/src/surface/exec/cold/quarry/walk.zig
      contains: ["pub fn defaultFileSetExtras", "Oom!FileSet"]
    - description: "ADR-373 rung 1: the ignore matcher's construction is fallible, not fatal"
      file: pkg/kernels/irregex/src/corpus/tree/ignore.zig
      contains: ["Oom!Ignore", "Oom!void"]
    - description: "the seam's adverse allocation-failure suite drives the entry under a failing allocator"
      file: pkg/kernels/irregex/src/surface/ffi/oom_test.zig
      contains: ["FailingAllocator", "session.openWith", "OutOfMemory"]
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

## Error channels

[ADR-373](../../../../../../docs/architecture/3-decisions/373-irregex-error-channels.md)
splits an outcome three ways, and `contract.zig` is where that split becomes a
status. `Disposition` makes the contract's own `disposition` column executable,
so the distinction a consumer would otherwise re-derive from the sign of an
integer is a property a switch proves: `IRREGEX_STALE` is negative but is a
**declinature** — answer cold and get the identical result — while
`Status.ofFault` maps every member of the kernel's taxonomy onto a `fault`
status, exhaustively, so a new fault member is a compile error rather than a
failure reported as a clean run.

A status names a kind; `irregex_last_fault` names the incident (which fault,
which file, which byte) — a **pull**, asked after a non-OK status, and
deliberately not a second copy of assay's push sink, which this session scopes
`.dark`. It is per thread and last-fault-wins, its `path` borrows thread-local
storage until that thread's next call, and reading does not consume. Every
entry that _starts_ work opens the window first, so asking after a successful
call reports `IRREGEX_OK`; the destructors and both readers leave the slot
alone, so a cleanup path can still report the fault that got it there.

Allocation failure was the last channel this seam could not speak, and it is now
closed at the only place it could be. The warm session reuses the cold walkers
(`defaultFileSetExtras`, the swarm `collectFileSet`, the ignore matcher, the
fused corpus loader), and those used to answer an out-of-memory with
`process.exit(2)` — killing the embedding host from inside a call it had made,
with the notice swallowed by this session's `dark` sink. They now **return**
`error.OutOfMemory` (ADR-373 rung 1) and the terminal decision belongs to the
caller: the command plane absorbs it at its own top level (`collectFiles`'
`catch oom()`, so the CLI's exit 2 and OOM notice are byte-identical to before),
while this seam reports `IRREGEX_OOM` with `name == "OutOfMemory"`.

That line is held adversarially, not by inspection: `oom_test.zig` drives
`irregex_open` and the cursor ABI's engine open under a failing allocator at
every failure index, and sweeps the three walkers directly. Its assertions are
only reachable because the process is still there to make them — a walker that
went back to exiting would take the test binary down instead of failing it.

### What a binding must get right about the pull

Four traps, each one a way to hold the pull correctly at the C level and still
be wrong one layer up:

- **`struct_size` is the caller's job.** The layout is append-only, so the seam
  refuses a struct it cannot identify: set it to your own `sizeof` before every
  call or get `IRREGEX_INVALID` by design.
- **`path` borrows thread-local storage** and dies at this thread's next call.
  Copy it into owned memory _before_ returning across any boundary, and note it
  is not NUL-terminated — use `path_len`. Repository paths are not guaranteed
  UTF-8, so decode lossily (Python: `surrogateescape`; Rust: `OsStr`), never
  strictly.
- **The slot is per thread, not per handle.** A detail fetched from a different
  thread than the failing call correctly reports `IRREGEX_OK`. Anything running
  the FFI in a thread pool or executor must read the detail on the thread that
  made the failing call, before it returns to the pool.
- **`IRREGEX_STALE` must not become an error value.** Mirror `Disposition` and
  branch on the channel rather than on the sign of the integer.

And one loss of resolution to expect: `open_failed` carries three fault domains
(`corpus`, `persist`, `wire`), so status alone cannot tell a corrupt artifact
from a tree that would not open. Read `name` when the distinction matters.

Every pointer handed to the callback (`path`, `line`, each submatch `text`)
aliases session/scratch memory valid **only** for that callback invocation —
the caller copies anything it keeps. Index _build_ stays a CLI verb; a session
searches the live tree.
