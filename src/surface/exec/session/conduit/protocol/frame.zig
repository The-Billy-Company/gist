//! The typed frame — what an opcode means, and how one crosses the socket.
//!
//! `wire.zig` owns the opcode-agnostic half of the grammar (the `[u32 len]
//! [u8 opcode][payload…]` envelope, the stream reader, SIGPIPE-safe writes).
//! This is the layer that gives that opcode byte a meaning: every codec chapter
//! beside it mints frames through `writeFrame`/`sendFrame` and reads them
//! through `parseFrame`/`recvFrame`, so an opcode byte is spelled in one place
//! and the chapters cannot drift on what one is.
//!
//! Fail-closed: an opcode byte outside the enum is `UnexpectedFrame`, never a
//! guess at what the peer meant.

const std = @import("std");
const wire = @import("../wire.zig");

/// Frame ceiling + error set are the shared `wire` plumbing's; re-exported so
/// existing `protocol.max_frame` / `protocol.WireError` call sites are stable.
pub const max_frame = wire.max_frame;
pub const WireError = wire.WireError;

pub const Opcode = enum(u8) {
    hello = 1, // C→S: [u8 proto_version]
    ready = 2, // S→C: [u8 proto][u64 daemon_gen][u64 session_gen][u64 image][u32 n][gen bytes]
    query = 3, // C→S: [u8 mode][u8 flags][if flags&max_count_present: u64 LE][pattern bytes]
    result = 4, // S→C: [u8 mode] then files/count/lines body
    decline = 5, // S→C: (no payload) — answer this request cold
    err = 6, // S→C: [message bytes]
    shutdown = 7, // C→S: (no payload)
    status = 8, // C→S: (no payload) → S replies `ready`
    ping = 9, // C→S: (no payload)
    pong = 10, // S→C: (no payload)
    // `lines` streams as zero+ `chunk` frames then a terminal `result`
    // `[mode=lines][u8 matched]`. Keeps every frame under `max_frame`.
    chunk = 11, // S→C: [raw output bytes]
    // Zero-copy terminal `lines` answer: `[u64 LE length][u8 matched]` while the
    // rendered bytes ride a shared-memory fd in the same sendmsg's SCM_RIGHTS
    // control message (see `shm.zig` + `wire.sendWithFd`). REPLACES the `chunk`
    // stream + terminal `result` for this answer. Sent only when the client
    // advertised `cap_fd_transport` AND the answer exceeds `fd_transport_floor`.
    chunk_fd = 12, // S→C: [u64 length][u8 matched] (+ fd via SCM_RIGHTS)
    // The scoped query: the classic `query` body (mode/flags/opt max_count) but
    // with a LENGTH-PREFIXED pattern so a `PathFilter` trailer can follow — four
    // string lists in a fixed order: positional roots, `-g` includes, `-g '!…'`
    // excludes, and `-t <type>` extension globs. ADDITIVE — a daemon that
    // predates this opcode hits the `else` decline / `UnexpectedFrame` drop and the
    // client fails open to cold, exactly like an unknown flag bit. The classic
    // `query` opcode still carries every unscoped request, so an old daemon
    // keeps serving those warm.
    query_ext = 13, // C→S: [u8 mode][u8 flags][opt u64 max_count][u32 plen][pattern] then 4×([u8 n]{[u32 len][bytes]}) = roots,includes,excludes,exts, then [u8 rank_present][opt u64 rank_k], then [u8 ctx_present][opt u64 before][opt u64 after], then [u8 pcre] (`-P`/`--pcre2`; self-describing, absent tail ⇒ 0)
    // The annals consult (`gist index` amend fast path): "which corpus files
    // changed at/after instant S?" — answered only when the daemon's
    // never-drained watcher ledger (`annals.zig`) can causally vouch, which both
    // syscall-synchronous backends (Linux inotify, macOS kqueue — ADR-372) can.
    // ADDITIVE like `query_ext`: an old daemon's `UnexpectedFrame` drop / `decline`
    // sends the client to its proven fallback (journal replay → stat walk).
    changed = 14, // C→S: [i64 since_ns]
    // The answer: ok=0 ⇒ the ledger cannot vouch (unarmed, poisoned, floor,
    // flush failure) — never a partial list. ok=1 ⇒ the daemon's armed absolute
    // watch prefix (the client verifies it matches its own repo root) + every
    // REPO-RELATIVE path noted at/after S (a sound superset; the client's stat
    // confirm prunes the extras).
    annals = 15, // S→C: [u8 ok][if ok: [u32 plen][prefix][u32 n]{[u32 len][path]}]
    // A warm query's diagnostics (timing summary / lens traces the worker
    // captured off its `assay` buffer sink), relayed to the client's stderr
    // verbatim. Payload is the already-rendered diagnostic bytes (text or
    // NDJSON, newline-terminated). Sent AHEAD of the answer frames, zero or more
    // times; a query with nothing to report sends none. Additive (v7): a stale
    // peer never reaches it — the READY version check sends it cold first.
    diag = 16, // S→C: [raw diagnostic bytes]
    // The answer keep (v8). `recall` asks whether the daemon still holds the
    // rendered answer a caller produced for `key` — a question about the CORPUS
    // EPOCH, not about the query, so the daemon needs no grammar for the verb
    // being cached and can never recompute it wrongly. `retain` offers one back,
    // stamped with the epoch it was computed at; the daemon keeps it only if the
    // corpus has not moved since. Additive like `changed`/`diag`: a stale daemon
    // never sees these frames because READY already sent the client cold.
    recall = 17, // C→S: [key bytes]
    // ok=0 ⇒ the ledger cannot vouch for an epoch (unarmed watcher, poisoned
    // ledger, no causal barrier) and the keep is unusable for this run — the
    // client computes cold and does not offer the result back. ok=1, hit=0 ⇒ no
    // (or stale) entry, and `epoch` is what to stamp a later `retain` with.
    recalled = 18, // S→C: [u8 ok][u8 hit][u64 epoch][if hit: [u8 code][u32 len][answer bytes]]
    retain = 19, // C→S: [u64 epoch][u8 code][u32 klen][key][answer bytes]
};

/// Chunk payload budget for a streamed `lines` answer — under `max_frame`.
pub const chunk_bytes: usize = 4 << 20;

/// Answer-size floor for the fd path. Below it the shm map + client mmap
/// page-fault fixed cost isn't earned back (measured on macOS: a sub-1-MiB
/// answer's chunk stream is well under a millisecond), so small emits stay on
/// `chunk` frames — the daemon already has the bytes mapped, so it streams them
/// with no extra render. At/above it the eliminated socket copy + client
/// accumulation dominate and the fd path wins (measured ~1.2× at 32 MB).
pub const fd_transport_floor: usize = 1 << 20;

/// Append a `[len][opcode][payload]` frame to `buf` (gist opcode → raw byte).
pub fn writeFrame(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, op: Opcode, payload: []const u8) !void {
    return wire.writeFrame(buf, gpa, @intFromEnum(op), payload);
}

pub const Parsed = struct { op: Opcode, payload: []const u8, consumed: usize };

/// Parse one frame from the front of `bytes`, or `null` when incomplete.
/// `StreamTooLong`/`UnexpectedFrame` are hard errors (an unknown opcode byte the
/// shared layer accepts fails closed here, where the enum is known).
pub fn parseFrame(bytes: []const u8) WireError!?Parsed {
    const p = (try wire.parseFrame(bytes)) orelse return null;
    const op = std.enums.fromInt(Opcode, p.op) orelse return WireError.UnexpectedFrame;
    return .{ .op = op, .payload = p.payload, .consumed = p.consumed };
}

/// Consume a `[u32 len][bytes]` field from the front of `rest`, advancing it.
/// The returned slice aliases the frame buffer. Truncation → `UnexpectedFrame`.
/// Shared by every codec whose payload carries one (the `query_ext` pattern and
/// path lists, the `annals` watch prefix), so the field grammar has one reader.
pub fn takeLenPrefixed(rest: *[]const u8) WireError![]const u8 {
    if (rest.len < 4) return WireError.UnexpectedFrame;
    const n = std.mem.readInt(u32, rest.*[0..4], .little);
    if (rest.len < 4 + @as(usize, n)) return WireError.UnexpectedFrame;
    const s = rest.*[4 .. 4 + n];
    rest.* = rest.*[4 + n ..];
    return s;
}

/// SIGPIPE-safe full write — re-exported from the shared plumbing so
/// `protocol.writeAll` call sites (serve/client) are stable.
pub const writeAll = wire.writeAll;

/// Send one framed message on `fd` (gist opcode → raw byte).
pub fn sendFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t, op: Opcode, payload: []const u8) WireError!void {
    return wire.sendFrame(gpa, fd, @intFromEnum(op), payload);
}

/// A framed message read off `fd`, owning its bytes (payload aliases into it).
/// The typed `op` is this protocol's enum; a byte outside it fails closed.
pub const Frame = struct {
    op: Opcode,
    bytes: []u8, // whole frame; payload is bytes[5..]
    gpa: std.mem.Allocator,

    pub fn payload(self: *const Frame) []const u8 {
        return self.bytes[5..];
    }
    pub fn deinit(self: *Frame) void {
        self.gpa.free(self.bytes);
    }
};

/// Receive one whole frame from `fd`. `ConnClosed` on truncated peer;
/// `StreamTooLong`/`UnexpectedFrame` fail closed.
pub fn recvFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!Frame {
    var raw = try wire.recvFrame(gpa, fd);
    const op = std.enums.fromInt(Opcode, raw.op) orelse {
        raw.deinit();
        return WireError.UnexpectedFrame;
    };
    return .{ .op = op, .bytes = raw.bytes, .gpa = raw.gpa };
}

/// A frame plus any fd the peer passed with it (via SCM_RIGHTS). Non-null only
/// for a `chunk_fd` answer; the caller owns and must close (or munmap+close) it.
pub const FdFrame = struct { frame: Frame, passed_fd: ?std.posix.fd_t };

/// Like `recvFrame`, but over `recvmsg` so a passed shm fd is captured. A client
/// that advertised `cap_fd_transport` uses this for the response so it can serve
/// either a `chunk_fd` answer or the classic `chunk`/`result` frames (which
/// simply arrive with `passed_fd == null`).
pub fn recvFrameWithFd(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!FdFrame {
    var raw = try wire.recvFrameWithFd(gpa, fd);
    const op = std.enums.fromInt(Opcode, raw.frame.op) orelse {
        raw.frame.deinit();
        if (raw.passed_fd) |p| _ = std.c.close(p);
        return WireError.UnexpectedFrame;
    };
    return .{ .frame = .{ .op = op, .bytes = raw.frame.bytes, .gpa = raw.frame.gpa }, .passed_fd = raw.passed_fd };
}

/// Send one framed message on `fd` carrying `pass_fd` over SCM_RIGHTS — the
/// zero-copy `chunk_fd` transport (see `result.sendChunkFd`). Re-exported so
/// serve/client call sites don't reach through `wire`.
pub const sendWithFd = wire.sendWithFd;
