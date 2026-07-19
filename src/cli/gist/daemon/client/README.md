---
doc_radar:
  sentinels:
    - description: "warm client stays fail-open with an I/O deadline"
      file: pkg/kernels/irregex/src/cli/gist/daemon/client/client.zig
      contains: ["pub fn attempt", "client_io_timeout_ms", ".cold", ".served"]
    - description: "autoserve remains opt-out, not opt-in"
      file: pkg/kernels/irregex/src/cli/gist/daemon/client/spawn.zig
      contains: ["maybeSpawn", "GIST_NO_AUTOSERVE"]
---

# cli/gist/daemon/client — warm dial + cold fallback

The fail-open bridge from the bare `gist <pattern>` front door to the resident
daemon ([`../serve`](../serve)). Warm acceleration is opportunistic; correctness
always has the cold engine behind it.

`attempt(gpa, io, argv, socket_path)` classifies the argv
([`session/request.zig`](../../../../session/request.zig)) and only dials when
the request is one the warm path can answer with **cold's own per-file bytes
and exit code**:

- `-l` / `--files-with-matches` — sorted path list
- bare default line search (`gist <pattern> [-n]`) — `path:[line:]text` frames
  the daemon pre-renders through the cold `Emitter` and chunk-streams

File emission order is the deterministic `pathLess` canonicalization of cold's
parallel worker-discovery order (rgsuite certifies
`sort_lines(gist) == sort_lines(rg)`). Anything else — ineligible argv, no
daemon, a `decline`, any wire hiccup — returns `.cold` and the caller runs the
certified cold path unchanged.

**Parity guards.** TTY stdout declines to cold (interactive cold adds ANSI + the
16 KiB long-line cap; the daemon renders the piped frame only). Readable stdin
declines to cold (a rootless stream search the tree daemon can never answer).
`-c` and richer shapes stay cold.

**I/O deadline.** After connect, every warm `recvFrame` is gated by
`poll(…, client_io_timeout_ms)` (2s). A peer that accepts but never speaks READY
cannot park the CLI — timeout falls through to `.cold` (`client_test.zig`).

**Autoserve.** On a cold miss for an eligible shape, `spawn.zig::maybeSpawn`
best-effort forks a detached `gist serve` so the *next* query lands warm. The
current query still runs cold. Opt out with `GIST_NO_AUTOSERVE`. Ten agents
racing the socket is the normal case: the daemon takes an advisory `flock`, so
exactly one serve wins.
