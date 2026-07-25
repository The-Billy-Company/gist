<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/surface/exec/session/conduit/protocol.zig
    - pkg/kernels/irregex/src/surface/exec/session/conduit/wire.zig
    - pkg/kernels/irregex/src/surface/exec/session/conduit/shm.zig
    - pkg/kernels/irregex/src/surface/exec/session/conduit/spawn.zig
  sentinels:
    - file: pkg/kernels/irregex/src/surface/exec/session/conduit/protocol.zig
      contains: ["chunk = 11", "protocol_version: u8 = 6", "known_flags", "flag_word", "flag_invert", "flag_smart_case", "flag_quiet", "flag_max_count_present"]
-->

# `conduit/` — how a request reaches the daemon and an answer gets back

The transport plane. Nothing here knows what a query _means_; it moves bytes and
descriptors between a client and a resident daemon, and starts the daemon when
none is listening. It is the one folder in this tier with a cross-language
contract: the Zig CLI, the Rust binding, and the Python binding all speak the
grammar `protocol.zig` defines.

| Module                         | Role                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`protocol.zig`](protocol.zig) | The length-prefixed UDS frame codec (`[u32 len][u8 opcode][payload]`) + `SCM_RIGHTS` fd send/recv, fail-closed on oversized/truncated/unknown frames. A `lines` answer streams as `chunk` frames + a terminal `result` — unless the client advertised `cap_fd_transport` in its HELLO **and** the answer clears the `fd_transport_floor` (1 MiB), in which case it arrives as one `chunk_fd` frame carrying `{length, matched}` while the rendered bytes ride an anonymous-shm fd over the same `sendmsg` control channel. A `-q` answer is a single terminal `result` carrying one matched bit. v2 grew the query flags byte with the flag-family table — `word`/`invert`/`smart_case`/`quiet`/`max_count` are all live, so the byte is now fully assigned — and `decodeQuery` rejects any bit outside `known_flags` or a truncated cap (BadFrame → decline → cold), so a flag is never silently dropped server-side. |
| [`wire.zig`](wire.zig)         | The opcode-agnostic half of that grammar: framing, transport, and the `recvFramed` reader both frame paths share. Also owns `armNoSigpipe`, the single Darwin `SO_NOSIGPIPE` site, so a dead peer can never take the daemon down with a signal.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| [`shm.zig`](shm.zig)           | The anonymous shared-memory buffer a large `lines` answer rides instead of the socket — bounded to the exact rendered length on both platforms (Linux `memfd` + seal · macOS `shm_open`→`ftruncate`→`shm_unlink`). Fail-**open**: every fallible call returns an error the caller turns back into byte-identical `chunk` frames.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| [`spawn.zig`](spawn.zig)       | Detached daemon auto-spawn, shared by both resident CLIs: only the `fork` → detach → `execv` mechanism lives here. Each CLI keeps its own eligibility policy and socket probe, because the warm path only pays off if a daemon is already running and an agent's reflex is a one-shot command.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |

`protocol_test.zig` sits beside its subject — frame codec round-trips plus the
adversarial truncation/oversize cases.

## Fail-closed on the frame, fail-open on the carrier

The two postures are deliberate and different. A malformed **frame** is a hard
error: an oversized, zero-length, or unknown-opcode frame is refused rather than
guessed at, and anything the server cannot serve warm comes back as an explicit
`decline` that sends the client to the cold path. A failed **carrier** is not an
error at all: if shm or `sendmsg` fails, or the client never advertised the
capability, or the answer sits below the floor, the identical bytes simply travel
as ordinary `chunk` frames.

Because the grammar is a cross-language contract, `protocol.zig` is the source of
truth for all three bindings — see
[`bindings/rust/src/runtime/session.rs`](../../../../../bindings/rust/src/runtime/session.rs)
and the Python daemon client. Bumping `protocol_version` is a contract change,
not an implementation detail.
