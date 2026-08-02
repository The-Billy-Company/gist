# `src/exec/session/daemon/` — warm Unix-socket transport

Moved here from `exec/session/daemon/` so the resident session owns its
transport. The CLI's optional accelerator: a
`ResidentSession` (`irregex/src/exec/session/warm/resident.zig`) stays warm behind a Unix socket so
the next eligible `gist <pattern>` can skip process + index-mmap +
candidate-read startup — and still emit **cold's own bytes and exit code**.

Warm is never a dependency. Ineligible argv, no daemon, a `decline`, a wedged
peer, a TTY stdout, or readable stdin all fall through to the certified cold
engine unchanged.

| Package | Role |
| ------- | ---- |
| [`serve/`](serve) | `gist serve` — bind the socket, multiplex clients on one readiness wait, answer or `decline` |
| [`client/`](client) | dial / emit / cold fallback; best-effort detached autoserve on a cold miss |

"Unix socket" is literal on all three platforms, not a POSIX-only shorthand:
Windows has had `AF_UNIX` since 1803, which is why the package declares that as
its floor rather than porting the transport to named pipes. What differs is only
the two mechanisms a socket cannot supply by itself — the readiness wait and the
descriptor handoff — and both are seams in [`../conduit/`](../conduit/README.md)
rather than branches in here. Descriptor passing is the one capability Windows
genuinely lacks; it is advertised per-connection, so the answer travels as `chunk`
frames there and the bytes are identical.

The in-process sibling for embedding hosts is [`../../../surface/ffi/`](../../../surface/ffi) —
same session, C ABI, no socket. The wire grammar lives in
[`../conduit/protocol/`](../conduit/protocol/README.md).
