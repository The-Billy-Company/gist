---
doc_radar:
  counts:
    - description: "daemon face is serve + client only"
      glob: pkg/kernels/irregex/src/surface/face/gist/daemon/*/
      equals: 2
      unit: dirs
  sentinels:
    - description: "warm path stays fail-open to cold"
      file: pkg/kernels/irregex/src/surface/face/gist/daemon/client/client.zig
      contains: [".cold", "attempt"]
---

# surface/face/gist/daemon — warm Unix-socket path (ADR-352 rung 2.5)

The CLI's optional accelerator. A resident [`ResidentSession`](../../../exec/session/warm/resident.zig)
stays warm behind a Unix socket so the next eligible `gist <pattern>` can skip
process + index-mmap + candidate-read startup — and still emit **cold's own
bytes and exit code**.

Warm is never a dependency. Ineligible argv, no daemon, a `decline`, a wedged
peer, a TTY stdout, or readable stdin all fall through to the certified cold
engine unchanged. That fail-open contract is what makes ten agents racing the
same socket safe.

| Package             | Role                                                                        |
| ------------------- | --------------------------------------------------------------------------- |
| [`serve/`](serve)   | `gist serve` — bind the socket, poll-multiplex clients, answer or `decline` |
| [`client/`](client) | dial / emit / cold fallback; best-effort detached autoserve on a cold miss  |

The in-process sibling for embedding hosts is [`../../../ffi/`](../../../ffi) — same
session, C ABI, no socket. The wire grammar lives in
[`exec/session/conduit/protocol.zig`](../../../exec/session/conduit/protocol.zig).
