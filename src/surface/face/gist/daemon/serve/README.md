---
doc_radar:
  sentinels:
    - description: "daemon socket path stays contract-pinned"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["GIST_SESSION_SOCK", "gistd.sock"]
    - description: "serve.zig stays the lifecycle face, not the machinery"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/serve/serve.zig
      contains: ["pub fn run", "pub fn socketPath"]
    - description: "the accept loop stays poll-multiplexed with in-flight work off the set"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/serve/loop.zig
      contains: ["std.posix.poll", "drainCompletions"]
    - description: "an unservable request is declined, never answered wrong"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/serve/answer.zig
      contains: ["decline", "servesScope"]
    - description: "idle release stays two-stage: watch set before session"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/serve/idle.zig
      contains: ["pub const ttl_ms", "pub const shed_ms", "pub fn nextStep"]
---

# surface/face/gist/daemon/serve — `gist serve`

Keeps one [`ResidentSession`](../../../../exec/session/warm/resident.zig) warm behind a
Unix-domain socket so a persistent client answers an eligible query without
re-paying the cold subprocess's process + index-mmap + candidate-read startup —
the mechanism behind the warm session certificate.

`run(gpa, io, roots, socket_path)` is the whole public surface (plus
`socketPath`). It builds the session, arms the freshness watcher, binds the
socket (unlinking a stale one), raises the worker pool, and hands the apparatus
to the loop — then unwinds it in the one order that is safe. Only an explicit
`shutdown` frame or an expired idle deadline stops it. Every unservable request
is answered `decline`, so a client only ever loses a warm acceleration, never
correctness.

## The five layers behind `run`

Each file is one level of abstraction, and only `serve.zig` is reached from
outside this folder.

[`crew.zig`](crew.zig) is the division of labour: the fixed-slot connection
table (stable across accept/drop churn, so a worker can hold a slot) and the
bounded worker pool. [`loop.zig`](loop.zig) is the poll multiplexer over the
listener, the worker self-pipe, and every idle client — plus the only quiescent
window the daemon has, which is why the idle policy and the annals seed both
run there. [`route.zig`](route.zig) decides what one readable client costs: a
control frame is a few bytes and answers inline on the poll thread, while a
search goes to the pool and its connection leaves the poll set until the worker
reports back — the reason one slow query never stalls the other coworkers.
[`answer.zig`](answer.zig) turns a query frame into an answer (ranked view,
existence flag, lines over the socket or over shared memory, files/count) and
holds the per-query wall-clock budget that reclaims a runaway or abandoned scan.
[`idle.zig`](idle.zig) is what an idle daemon gives back, and when.

## Idle release is ordered by what the resource costs the machine

The macOS watch set is one descriptor per watched vnode — ~26k here, out of a
system file table every sibling daemon shares — so it goes first, at `shed_ms`,
dropping the session to the reconcile-always baseline (slower, never staler) and
re-registering only once returning traffic settles again. The resident session
itself is this process's own RAM, so it lives until `ttl_ms` of continuous
idleness and then exits; the next query re-spawns one.

## One socket, one tree

`socketPath` resolves `$GIST_SESSION_SOCK`, else `.local/gist-verify/gistd.sock`.

Because that default sits _inside_ the artifact directory, an absolute
`$GIST_DIR` shared by two checkouts aims both at one **rendezvous** — and a warm
answer names files by paths that resolve in either tree, so a crossed dial is
invisible in the output. So the daemon records the tree it went resident over
in a hidden `.<socket>.tree` beside the socket
([`frame.socketBindingPath`](../../../../../corpus/index/frame/frame.zig)), and the client
re-proves it before dialing; a socket bound to another tree reads as no daemon
at all and the query answers cold.

The wire grammar is [`exec/session/conduit/protocol.zig`](../../../../exec/session/conduit/protocol.zig);
the client that dials it is [`../client`](../client). End-to-end lifecycle is
pinned in [`serve_test.zig`](serve_test.zig).
