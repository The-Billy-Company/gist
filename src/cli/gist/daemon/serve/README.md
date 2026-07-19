---
doc_radar:
  sentinels:
    - description: "daemon socket path stays contract-pinned"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["GIST_SESSION_SOCK", "gistd.sock"]
    - description: "serve loop stays poll-multiplexed and decline-on-unservable"
      file: pkg/kernels/irregex/src/gist/faces/cli/daemon/serve/serve.zig
      contains: ["pub fn run", "pub fn socketPath", "decline"]
---

# gist/faces/cli/daemon/serve — `gist serve`

Keeps one [`ResidentSession`](../../../../session/resident.zig) warm behind a
Unix-domain socket so a persistent client answers an eligible query without
re-paying the cold subprocess's process + index-mmap + candidate-read startup —
the mechanism behind the warm session certificate.

`run(gpa, io, roots, socket_path)` builds the session, arms the freshness
watcher, binds the socket (unlinking a stale one), then runs a
**poll-multiplexed** accept loop: one `poll` set over the listener plus every
connected client, one frame served per readable client per wakeup. Queries still
execute one at a time on the single daemon thread, but an idle persistent client
never starves a new connection. Only an explicit `shutdown` frame stops the
loop. Every unservable request is answered `decline`, so a client only ever
loses a warm acceleration, never correctness.

`socketPath` resolves `$GIST_SESSION_SOCK`, else `.local/gist-verify/gistd.sock`.

The wire grammar is [`session/protocol.zig`](../../../../session/protocol.zig);
the client that dials it is [`../client`](../client). End-to-end lifecycle is
pinned in [`serve_test.zig`](serve_test.zig).
