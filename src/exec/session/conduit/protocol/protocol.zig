//! gist resident session — the Unix-domain-socket wire protocol.
//!
//! Length-prefixed framing over a stream socket: `[u32 len][u8 opcode][payload…]`,
//! where `len` counts the opcode + payload. One request per query, one response
//! back; a persistent client keeps the connection open across many queries.
//! The codec is pure (encode/decode byte slices) with thin `sendFrame`/
//! `recvFrame` helpers over a POSIX fd, so the frame grammar is unit-tested
//! without opening a socket.
//!
//! Fail-closed: oversized/truncated frames and unknown opcodes are hard errors.
//! Anything the server cannot serve warm comes back as `decline` (client → cold).
//!
//! This file is the whole contract's face: the negotiated version, the session
//! capabilities, the HELLO/READY handshake that decides warm-or-cold, and the
//! one name every caller imports. The codec chapters beneath it —
//! `frame` (the opcode spine + transport), `query`, `result`, `keep`,
//! `annals` — are its internals, sealed so a caller cannot bind to half a
//! contract.

const std = @import("std");
const wire = @import("../wire.zig");
const shm = @import("irregex").inner.session.shm;
const frame = @import("opcodes.zig");
const query = @import("query.zig");
const result = @import("result.zig");
const keep = @import("keep.zig");
const annals = @import("annals.zig");

/// Wire version. Unknown flag bits outside `known_flags` fail closed (UnexpectedFrame
/// → decline → cold); a version-mismatched READY handshake also falls open cold.
///
/// fd-transport is negotiated as an ADDITIVE capability (see `cap_fd_transport`),
/// not a version bump: an old client sends a 1-byte HELLO and an old daemon
/// ignores the extra byte, so no peer is forced cold by the change.
///
/// v5 grew the `query_ext` `[u8 pcre]` engine trailer (`-P`/`--pcre2` served
/// warm). The bump makes the handshake fail-open: a v5 client meeting a stale
/// v4 daemon (or vice versa) sees the version mismatch in READY and runs cold,
/// so no peer ever reads the new trailer without agreeing to it.
///
/// v6 grew the `changed`/`annals` opcode pair (the `gist index` amend consult).
/// An old daemon receiving `changed` would UnexpectedFrame-drop the whole connection
/// mid-session; the bump lets a v6 client see the stale daemon in READY and
/// skip the consult entirely (fallback: journal replay → stat walk).
///
/// v7 grew the `diag` frame (S→C): a warm query ships the timing/trace
/// diagnostics it produced (captured off the worker's `assay` buffer sink) back
/// to the client, which relays them to its own stderr — so a warm `--rank`/query
/// is as measurable as cold. It rides ahead of the answer frames; the bump makes
/// a stale peer fail open cold in the READY check rather than meet the new
/// opcode, exactly like the v5/v6 additions.
///
/// v8 grew the `recall`/`recalled`/`retain` triple — the answer keep, which
/// holds a sibling face's whole rendered answer against the corpus change
/// epoch. Unlike every opcode above it this one carries no query grammar at
/// all: the daemon never parses, plans, or recomputes a kinship question, it
/// only reports whether the corpus has moved since a caller last answered one.
/// Same fail-open bump as v5/v6/v7 — a stale peer is sent cold by READY before
/// it can meet the new frames.
///
/// v9 grew the READY `[u64 image]` field, and it is the one bump here that adds
/// no frame and no verb. Every version above says two peers FRAME alike; none
/// of them could say the peers ANSWER alike, because a correctness fix that
/// changes what a warm answer IS moves no byte on the wire and so earns no
/// bump — and a daemon started before that fix keeps serving freshly-rebuilt
/// clients for as long as it stays resident. v9 closes that by making the
/// daemon name its own build (`conduit/image.zig`), so a client running a
/// different one declines to cold instead of trusting an engine it no longer
/// shares. The bump itself is the last time this problem needs one.
pub const protocol_version: u8 = 9;

/// Session/transport capabilities the peers agree on in the HELLO frame. NOT
/// query flags — the flags byte is fully assigned; this is a separate handshake
/// byte the daemon reads once per connection. Additive and fail-open: a peer
/// that advertises nothing (or an old peer sending no caps byte) gets exactly
/// the classic `chunk`-frame path.
pub const cap_fd_transport: u8 = 1 << 0; // client can receive a shm fd for a large `lines` answer

/// The capability set this build advertises (client) and honors (daemon). Zero
/// on a target without the anonymous-shm + SCM_RIGHTS path, so those peers stay
/// on `chunk` frames automatically.
pub const caps_supported: u8 = if (shm.supported) cap_fd_transport else 0;

/// `image` is the daemon's executable identity, latched at ITS boot rather than
/// read here — the whole value is that it predates any rebuild that happened
/// while this daemon stayed resident. `conduit/image.unknown` (0) means the
/// daemon could not identify itself, which clients read as "cannot judge".
pub fn encodeReady(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, daemon_gen: u64, session_gen: u64, image: u64, index_gen: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, protocol_version);
    try wire.appendInt(u64, &body, gpa, daemon_gen);
    try wire.appendInt(u64, &body, gpa, session_gen);
    try wire.appendInt(u64, &body, gpa, image);
    try wire.appendInt(u32, &body, gpa, @intCast(index_gen.len));
    try body.appendSlice(gpa, index_gen);
    try frame.writeFrame(buf, gpa, .ready, body.items);
}

pub const Ready = struct { proto: u8, daemon_gen: u64, session_gen: u64, image: u64, index_gen: []const u8 };

/// Every fixed field sits ahead of the one variable-length tail, so the header
/// is a constant 29 bytes: `[u8 proto][u64 daemon_gen][u64 session_gen][u64 image][u32 n]`.
const ready_header = 29;

pub fn decodeReady(payload: []const u8) WireError!Ready {
    if (payload.len < ready_header) return WireError.UnexpectedFrame;
    const n = std.mem.readInt(u32, payload[25..29], .little);
    if (payload.len < ready_header + @as(usize, n)) return WireError.UnexpectedFrame;
    return .{
        .proto = payload[0],
        .daemon_gen = std.mem.readInt(u64, payload[1..9], .little),
        .session_gen = std.mem.readInt(u64, payload[9..17], .little),
        .image = std.mem.readInt(u64, payload[17..25], .little),
        .index_gen = payload[ready_header .. ready_header + n],
    };
}

// ── the contract surface ──
//
// Every name a caller may bind to, gathered here from the chapters below. Zig
// has no visibility rules between files in a package, so this list — plus the
// `seal` on this directory in `charter.zone` — is what makes the
// chapters internals rather than five more public modules.

// The typed frame: opcode vocabulary, framing, and fd transport.
pub const max_frame = frame.max_frame;
pub const WireError = frame.WireError;
pub const Opcode = frame.Opcode;
pub const chunk_bytes = frame.chunk_bytes;
pub const fd_transport_floor = frame.fd_transport_floor;
pub const writeFrame = frame.writeFrame;
pub const Parsed = frame.Parsed;
pub const parseFrame = frame.parseFrame;
pub const writeAll = frame.writeAll;
pub const sendFrame = frame.sendFrame;
pub const Frame = frame.Frame;
pub const recvFrame = frame.recvFrame;
pub const FdFrame = frame.FdFrame;
pub const recvFrameWithFd = frame.recvFrameWithFd;
pub const sendWithFd = frame.sendWithFd;

// The request codec.
pub const known_flags = query.known_flags;
pub const encodeQuery = query.encodeQuery;
pub const encodeQueryExt = query.encodeQueryExt;
pub const decodeQuery = query.decodeQuery;
pub const decodeQueryExt = query.decodeQueryExt;

// The answer codec.
pub const encodeFiles = result.encodeFiles;
pub const encodeCount = result.encodeCount;
pub const encodeLines = result.encodeLines;
pub const sendChunkFd = result.sendChunkFd;
pub const ChunkFd = result.ChunkFd;
pub const decodeChunkFd = result.decodeChunkFd;
pub const ResultView = result.ResultView;
pub const decodeResult = result.decodeResult;
pub const FileIter = result.FileIter;

// The answer keep (v8).
pub const encodeRecall = keep.encodeRecall;
pub const Hit = keep.Hit;
pub const Vouched = keep.Vouched;
pub const Recalled = keep.Recalled;
pub const encodeRecalled = keep.encodeRecalled;
pub const decodeRecalled = keep.decodeRecalled;
pub const encodeRetain = keep.encodeRetain;
pub const Retention = keep.Retention;
pub const decodeRetain = keep.decodeRetain;

// The watcher consult.
pub const encodeChanged = annals.encodeChanged;
pub const decodeChanged = annals.decodeChanged;
pub const encodeAnnals = annals.encodeAnnals;
pub const AnnalsView = annals.AnnalsView;
pub const decodeAnnals = annals.decodeAnnals;
