<!--
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/exec/session/conduit/protocol/protocol.zig
  sentinels:
    - file: pkg/kernels/irregex/contract/irregex.ward
      contains: ["seal exec/session/conduit/protocol through protocol.zig"]
      description: The directory is a sealed deep module, so a caller cannot bind to half the versioned contract
    - file: pkg/kernels/irregex/src/exec/session/conduit/protocol/protocol.zig
      contains: ["protocol_version: u8 = 9"]
      absent: ["MONOLITHIC"]
      description: The entry file owns the negotiated version and is no longer a registered monolith
-->

# `protocol/` — the versioned wire grammar, entered as one

One contract, five chapters. Everything the resident daemon and its clients say
to each other is gated on a single negotiated `protocol_version`, so the pieces
below are internals of one agreement rather than five independent modules — the
directory is **sealed** in
[`contract/irregex.ward`](../../../../../../contract/irregex.ward), and
`protocol.zig` is the only door.

| Module                         | Chapter                                                                                                                                                                                                                                                            |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`protocol.zig`](protocol.zig) | The contract's face: `protocol_version` and its version history, the additive HELLO capability byte (`cap_fd_transport`), the READY handshake codec that decides warm-or-cold — including the v9 build stamp that says which _engine_ is answering, not just which grammar — and the gathered public surface every caller binds to. |
| [`opcodes.zig`](opcodes.zig)   | The opcode spine and the typed transport: the `Opcode` enum (each variant documenting its own payload shape), the frame-size budgets, `writeFrame`/`parseFrame`, and `sendFrame`/`recvFrame`/`recvFrameWithFd` over a POSIX fd including the `SCM_RIGHTS` fd pass. Renamed off `frame.zig` so it never puns with the artifact wire floor (`corpus/index/frame/`). |
| [`query.zig`](query.zig)       | The request codec: the query flags byte, the classic `query`, and the scoped `query_ext` with its length-prefixed pattern, four-list `PathFilter`, and self-describing rank / context / pcre trailers.                                                             |
| [`result.zig`](result.zig)     | The answer codec: `files`/`count`/`lines` results, the chunk stream, the zero-copy `chunk_fd` handoff, and the zero-copy `ResultView` / `FileIter` readers.                                                                                                        |
| [`keep.zig`](keep.zig)         | The answer keep (v8): `recall`/`recalled`/`retain`. The one chapter with no query grammar — the daemon answers about the corpus epoch, never about the query, so it cannot recompute a cached verb wrongly.                                                        |
| [`annals.zig`](annals.zig)     | The watcher consult: `changed`/`annals`. All-or-nothing by construction — a daemon that cannot causally vouch says so in one byte rather than return a partial list.                                                                                               |

## Why the cut falls here

The opcode spine is a **leaf**, not the roof. Every chapter imports
`opcodes.zig` downward and none imports another chapter's grammar, so an opcode
byte is minted in exactly one place and the split cannot produce two disagreeing
definitions of the same frame — the failure mode that kept this contract in one
file until now.

Encode and decode for a given frame stay in the same chapter, always. A trailer
whose writer and reader drift by one byte does not fail loudly; it silently
reinterprets everything after it. Reading the two halves side by side is the
cheapest defense there is, so `query.zig` carrying both directions is deliberate
rather than incidental.

`protocol.zig` re-exports rather than re-implements. Zig has no visibility rules
between files in a package, so the gathered surface plus the ward seal are what
make these chapters internals; a name that is not in that list is not part of
the contract.
