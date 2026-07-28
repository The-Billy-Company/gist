---
doc_radar:
  counts:
    - description: "daemon is serve + client only"
      glob: pkg/kernels/irregex/src/exec/session/daemon/*/
      equals: 2
      unit: dirs
  sentinels:
    - description: "warm path stays fail-open to cold"
      file: pkg/kernels/irregex/src/exec/session/daemon/client/client.zig
      contains: [".cold", "attempt"]
---

# `src/exec/session/daemon/` — warm Unix-socket transport

Moved here from `exec/session/daemon/` so the resident session owns its
transport. The CLI's optional accelerator: a
[`ResidentSession`](../warm/resident.zig) stays warm behind a Unix socket so
the next eligible `gist <pattern>` can skip process + index-mmap +
candidate-read startup — and still emit **cold's own bytes and exit code**.

Warm is never a dependency. Ineligible argv, no daemon, a `decline`, a wedged
peer, a TTY stdout, or readable stdin all fall through to the certified cold
engine unchanged.

| Package | Role |
| ------- | ---- |
| [`serve/`](serve) | `gist serve` — bind the socket, poll-multiplex clients, answer or `decline` |
| [`client/`](client) | dial / emit / cold fallback; best-effort detached autoserve on a cold miss |

The in-process sibling for embedding hosts is [`../../../surface/ffi/`](../../../surface/ffi) —
same session, C ABI, no socket. The wire grammar lives in
[`../conduit/protocol/`](../conduit/protocol/README.md).
