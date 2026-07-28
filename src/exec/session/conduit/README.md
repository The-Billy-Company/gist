<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/exec/session/conduit/protocol/protocol.zig
    - pkg/kernels/irregex/src/exec/session/conduit/wire.zig
    - pkg/kernels/irregex/src/exec/session/conduit/shm.zig
    - pkg/kernels/irregex/src/exec/session/conduit/spawn.zig
    - pkg/kernels/irregex/src/exec/session/conduit/image.zig
  sentinels:
    - file: pkg/kernels/irregex/src/exec/session/conduit/protocol/protocol.zig
      contains: ["protocol_version: u8 = 9", "cap_fd_transport", "caps_supported", "image: u64"]
      description: The negotiated contract head the entry file owns — version, the additive HELLO capability byte, and the READY build stamp
    - file: pkg/kernels/irregex/src/exec/session/conduit/image.zig
      contains: ["pub fn stamp", "pub fn agrees", "pub fn supersedes", "pub const unknown"]
      description: The build-identity surface — equality decides warm-or-cold, order decides who may retire whom
    - file: pkg/kernels/irregex/src/exec/session/conduit/protocol/opcodes.zig
      contains: ["chunk = 11", "chunk_fd = 12", "recall = 17", "retain = 19"]
      description: The opcode spine is one enum in one file, so an opcode byte is minted exactly once
    - file: pkg/kernels/irregex/src/exec/session/conduit/protocol/query.zig
      contains: ["known_flags", "flag_word", "flag_invert", "flag_smart_case", "flag_quiet", "flag_max_count_present"]
      description: The query flags byte is fully assigned and lives with the codec that reads it
-->

# `conduit/` — how a request reaches the daemon and an answer gets back

The transport plane. Nothing here knows what a query _means_; it moves bytes and
descriptors between a client and a resident daemon, and starts the daemon when
none is listening. It is the one folder in this tier with a cross-language
contract: the Zig CLI, the Rust binding, and the Python binding all speak the
grammar `protocol/` defines.

| Module                   | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`protocol/`](protocol/) | The versioned UDS grammar, entered through `protocol.zig` and sealed: the length-prefixed frame codec (`[u32 len][u8 opcode][payload]`) + `SCM_RIGHTS` fd send/recv, fail-closed on oversized/truncated/unknown frames. A `lines` answer streams as `chunk` frames + a terminal `result` — unless the client advertised `cap_fd_transport` in its HELLO **and** the answer clears the `fd_transport_floor` (1 MiB), in which case it arrives as one `chunk_fd` frame carrying `{length, matched}` while the rendered bytes ride an anonymous-shm fd over the same `sendmsg` control channel. A `-q` answer is a single terminal `result` carrying one matched bit. See its own README for the chapter-per-opcode-family layout. |
| [`wire.zig`](wire.zig)   | The opcode-agnostic half of that grammar: framing, transport, and the `recvFramed` reader both frame paths share. Also owns `armNoSigpipe`, the single Darwin `SO_NOSIGPIPE` site, so a dead peer can never take the daemon down with a signal.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| [`shm.zig`](shm.zig)     | The anonymous shared-memory buffer a large `lines` answer rides instead of the socket — bounded to the exact rendered length on both platforms (Linux `memfd` + seal · macOS `shm_open`→`ftruncate`→`shm_unlink`). Fail-**open**: every fallible call returns an error the caller turns back into byte-identical `chunk` frames.                                                                                                                                                                                                                                                                                                                                                                                                |
| [`spawn.zig`](spawn.zig) | Detached daemon auto-spawn, shared by both resident CLIs: only the `fork` → detach → `execv` mechanism lives here. Each CLI keeps its own eligibility policy and socket probe, because the warm path only pays off if a daemon is already running and an agent's reflex is a one-shot command.                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| [`image.zig`](image.zig) | Which **build** is on each end of the handshake — the executable's mtime, so the stamp carries an order as well as an identity. The daemon latches its own at boot (the answer therefore predates any rebuild that lands while it stays resident) and reports it in READY; a gist client on a different build runs cold, and retires the daemon only if it is strictly newer. Fail-open: a target that cannot name its own executable stamps `unknown`, and `unknown` on either side abstains from both judgments.                                                                                                                                                                                                              |

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
tree with ~10 coworker agents querying it never gets, so one `make install-gist`
would strand the warm tier for the rest of the day. So the newer peer asks the
older one to stop on its way to the cold path — **only** the newer, which is why
both skew tests are strict orders rather than mere difference. Were disagreement
enough, an old shell and a new one would take turns killing each other's
daemons; ordered, the exchange converges after exactly one cold query.

There are two of those orders, and they compose. The **version** is read
straight off READY's byte zero rather than through `decodeReady`, because a
decoder can only parse the layout it was compiled for while every version this
protocol has ever had puts the version in the same place — that is precisely
what lets a v8 daemon be retired by a v9 client instead of merely declined. Only
once the versions agree does the **build stamp** decide, and mtime is the
ordering there.

Two peers are deliberately exempt. The **answer keep** never checks the stamp,
because `relate` and `irregex` dial this same socket and three binaries from one
build are three different files — and it is safe there, since the daemon renders
no kept answer and `cli/reprise.zig` already folds the caller's own build into
the key. The **non-Zig bindings** never check it either: a Python or Rust caller
has no comparable image, reports `unknown`, and is served exactly as before.

Because the grammar is a cross-language contract, `protocol/` is the source of
truth for all three bindings — see
[`bindings/rust/src/runtime/session.rs`](../../../../../bindings/rust/src/runtime/session.rs)
and the Python daemon client. Bumping `protocol_version` is a contract change,
not an implementation detail.
