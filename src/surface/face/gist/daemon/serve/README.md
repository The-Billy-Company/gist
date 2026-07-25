---
doc_radar:
  sentinels:
    - description: "daemon socket path stays contract-pinned"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["GIST_SESSION_SOCK", "gistd.sock"]
    - description: "serve loop stays poll-multiplexed and decline-on-unservable"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/serve/serve.zig
      contains: ["pub fn run", "pub fn socketPath", "decline"]
    - description: "idle release stays two-stage: watch set before session"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/serve/idle.zig
      contains: ["pub const ttl_ms", "pub const shed_ms", "pub fn nextStep"]
---

# surface/face/gist/daemon/serve — `gist serve`

Keeps one [`ResidentSession`](../../../../exec/session/resident.zig) warm behind a
Unix-domain socket so a persistent client answers an eligible query without
re-paying the cold subprocess's process + index-mmap + candidate-read startup —
the mechanism behind the warm session certificate.

`run(gpa, io, roots, socket_path)` builds the session, arms the freshness
watcher, binds the socket (unlinking a stale one), then runs a
**poll-multiplexed** accept loop: one `poll` set over the listener plus every
connected client, one frame served per readable client per wakeup. The poll
thread owns connection lifecycle and answers the cheap control frames inline; a
search — and its potentially multi-MB response write — goes to a bounded worker
pool, so one slow query never stalls the other coworkers sharing the daemon.
Only an explicit `shutdown` frame stops the loop. Every unservable request is
answered `decline`, so a client only ever loses a warm acceleration, never
correctness.

An idle daemon gives its two resources back in the order they cost the
**machine** rather than this process ([`idle.zig`](idle.zig)). The macOS watch
set is one descriptor per watched vnode — ~26k here, out of a system file table
every sibling daemon shares — so it goes first, at `shed_ms`, dropping the
session to the reconcile-always baseline (slower, never staler) and
re-registering only once returning traffic settles again. The resident session
itself is this process's own RAM, so it lives until `ttl_ms` of continuous
idleness and then exits; the next query re-spawns one.

`socketPath` resolves `$GIST_SESSION_SOCK`, else `.local/gist-verify/gistd.sock`.

Because that default sits *inside* the artifact directory, an absolute
`$GIST_DIR` shared by two checkouts aims both at one **rendezvous** — and a warm
answer names files by paths that resolve in either tree, so a crossed dial is
invisible in the output. So the daemon records the tree it went resident over
in a hidden `.<socket>.tree` beside the socket
([`frame.socketBindingPath`](../../../../../corpus/index/frame/frame.zig)), and the client
re-proves it before dialing; a socket bound to another tree reads as no daemon
at all and the query answers cold.

The wire grammar is [`exec/session/protocol.zig`](../../../../exec/session/protocol.zig);
the client that dials it is [`../client`](../client). End-to-end lifecycle is
pinned in [`serve_test.zig`](serve_test.zig).
