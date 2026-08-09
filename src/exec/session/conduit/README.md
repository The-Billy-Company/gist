# `conduit/` — how a request reaches the daemon and an answer gets back

The transport plane. Nothing here knows what a query _means_; it moves bytes and
descriptors between a client and a resident daemon, and starts the daemon when
none is listening. It is the one folder in this tier with a cross-language
contract: the Zig CLI, the Rust binding, and the Python binding all speak the
grammar `protocol/` defines.

| Module                   | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`protocol/`](protocol/) | The versioned UDS grammar, entered through `protocol.zig` and sealed: the length-prefixed frame codec (`[u32 len][u8 opcode][payload]`) + `SCM_RIGHTS` fd send/recv, fail-closed on oversized/truncated/unknown frames. A `lines` answer streams as `chunk` frames + a terminal `result` — unless the client advertised `cap_fd_transport` in its HELLO **and** the answer clears the `fd_transport_floor` (1 MiB), in which case it arrives as one `chunk_fd` frame carrying `{length, matched}` while the rendered bytes ride an anonymous-shm fd over the same `sendmsg` control channel. That capability is advertised, not assumed — a Windows client has no `SCM_RIGHTS` to advertise, never sets the bit, and is served the same bytes as `chunk` frames, which is why the whole fd path is additive rather than a platform fork. A `-q` answer is a single terminal `result` carrying one matched bit. See its own README for the chapter-per-opcode-family layout. |
| [`wire.zig`](wire.zig)   | The opcode-agnostic half of that grammar: framing, transport, and the `recvFramed` reader both frame paths share. Also owns `armNoSigpipe`, the single Darwin `SO_NOSIGPIPE` site, so a dead peer can never take the daemon down with a signal. Its leaf byte I/O is where the platform stops being assumed: POSIX keeps raw `read`/`write` on the descriptor, Windows goes through `std`'s socket vtable, and every frame above is the same bytes either way.                                                                                                                                                                                                                                                                     |
| [`vigil.zig`](vigil.zig) | The **readiness** question `loop.zig` asks of its listener, its idle clients, and its worker bell — `poll(2)` on POSIX, AFD's `IOCTL_AFD_POLL` on Windows, which is the same question (a handle set, an interest mask each, a timeout in the request) so the poll set, routing, worker pool, and two-stage idle policy port unchanged rather than forking into a second accept loop. The bell lives here too, because AFD knows only sockets: a pipe bell would be invisible to the Win32 wait, so the bell is a socket **pair** on both platforms — one fewer difference, not one more.                                                                                                                                            |
| `irregex/src/exec/session/conduit/shm.zig`     | The anonymous shared-memory buffer a large `lines` answer rides instead of the socket — bounded to the exact rendered length on both platforms (Linux `memfd` + seal · macOS `shm_open`→`ftruncate`→`shm_unlink`). Fail-**open**: every fallible call returns an error the caller turns back into byte-identical `chunk` frames. Windows hosts a resident session and is deliberately **not** here: it cannot pass a descriptor over the socket at all, so a handle-based buffer would be a second protocol rather than a second spelling, and its answers ride `chunk` frames.                                                                                                                                                     |
| [`spawn.zig`](spawn.zig) | Detached daemon auto-spawn, shared by both resident CLIs: only the mechanism lives here — `fork` → detach → `execv` on POSIX, a `DETACHED_PROCESS` `CreateProcessW` on Windows, which needs no double-fork because a Windows child was never in its parent's process group to leave. Each CLI keeps its own eligibility policy and socket probe, because the warm path only pays off if a daemon is already running and an agent's reflex is a one-shot command.                                                                                                                                                                                                                                                                   |
| [`image.zig`](image.zig) | Which **build** is on each end of the handshake — the executable's mtime, latched by the daemon at boot so its answer predates any rebuild landing while it stays resident, and reported in READY. That mtime is an **identity, not an order** (Zig's install preserves the cache artifact's timestamp, so switching builds moves it backwards), so a client on another build just runs cold. What retires the obsoleted daemon is `replaced`: it re-stats its own path and stands down once the bytes it runs are gone — `hosts` is only the tiebreak for a daemon that cannot observe that. Fail-open: a target that cannot name its own executable stamps `unknown`, and `unknown` abstains from every judgment.             |

`protocol/protocol_test.zig` sits beside its subject — frame codec round-trips
plus the adversarial truncation/oversize cases.

## Fail-closed on the frame, fail-open on the carrier

The two postures are deliberate and different. A malformed **frame** is a hard
error: an oversized, zero-length, or unknown-opcode frame is refused rather than
guessed at, and anything the server cannot serve warm comes back as an explicit
`decline` that sends the client to the cold path. A failed **carrier** is not an
error at all: if shm or `sendmsg` fails, or the client never advertised the
capability, or the answer sits below the floor, the identical bytes simply travel
as ordinary `chunk` frames.

## Two peers that frame alike may still not answer alike

`protocol_version` proves the grammar matches. It cannot prove the _engines_
match, because a correctness fix — a freshness barrier that stops vouching an
epoch it never counted — moves no byte on the wire and so earns no bump. A
daemon started before such a fix keeps serving freshly-rebuilt clients for as
long as it stays resident, and what it serves is the worst answer a search tool
can give: well-formed bytes that no longer exist on disk.

That is what `image.zig` closes, and why the daemon latches its stamp at **boot**
rather than reading it at handshake time. A resident daemon outlives rebuilds; a
stamp taken during the handshake would describe whichever binary a coworker last
installed, vouching for a build the answering process has never run.

Declining is only half an answer, though, because nothing would then retire the
obsolete daemon: the idle TTL wants ten _continuous_ minutes of quiet, which a
tree with ~10 coworker agents querying it never gets, so one `zig build`
would strand the warm tier for the rest of the day.

The temptation is to let the newer peer stop the older one, and for the wire
**version** that is exactly right — it only ever counts up in source, so it is a
real order. It is read straight off READY's byte zero rather than through
`decodeReady`, because a decoder can only parse the layout it was compiled for
while every version this protocol has ever had puts the version in the same
place — which is what lets a v8 daemon be retired by a v9 client instead of
merely declined.

A **build stamp** is not that kind of order. Zig's install copies the cache
artifact with its timestamp preserved, so reinstalling one build reproduces its
stamp and switching between two cached builds moves the mtime _backwards_: two
stamps can only answer "same build?", and a client waiting to be the newer one
would wait forever. So retirement here is decided against the filesystem instead
of against a peer. Our HELLO prompts the daemon to re-stat the executable it was
exec'd from, and a daemon whose own file has been rewritten is superseded as a
matter of fact — the bytes it is serving from are gone — so it stands down and
the next query spawns one from whatever is on disk now. Two live builds at one
rendezvous therefore never fight: each one's file is intact, neither is
`replaced`, and the loser simply stays cold.

That leaves one daemon self-retirement cannot reach — one exec'd from a
content-addressed build artifact, whose path embeds a hash of its own bytes and
so can never be rewritten. Measured: 10 such orphans resident at once, the warm
tier stranded, every eligible query 6-13x slower than the daemon beside it.
`hosts` settles that as a **tiebreak** rather than a recency claim: `>` over the
two stamps, so both sides compute the same winner from the same pair. Symmetry
is the trap — "we disagree" has an old shell and a new one taking turns killing
each other's daemons, where a strict order converges after exactly one cold
query, and the loser stays cold precisely as it does today.

Two peers are deliberately exempt. The **answer keep** never checks the stamp,
because `relate` and `blast` dial this same socket and three binaries from one
build are three different files — and it is safe there, since the daemon renders
no kept answer and `cli/reprise.zig` already folds the caller's own build into
the key. The **non-Zig bindings** never check it either: a Python or Rust caller
has no comparable image, reports `unknown`, and is served exactly as before.

`protocol/` is the native daemon's source of truth. The non-Zig bindings stay
outside that wire contract and report an unknown image instead. Bumping
`protocol_version` is a contract change, not an implementation detail.
