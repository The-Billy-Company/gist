//! gist resident session — the Unix-domain-socket wire protocol (ADR-352 rung 2.5).
//!
//! A tiny length-prefixed framing over a stream socket: every frame is
//! `[u32 len][u8 opcode][payload…]`, where `len` counts the opcode + payload.
//! One request per query, one response back; a persistent client keeps the
//! connection open across many queries (that reuse is the whole warm-session
//! win). The codec is pure and transport-agnostic — encode into / decode from
//! byte slices — with thin `sendFrame`/`recvFrame` helpers over a POSIX fd
//! (raw `read`/`write`, the same blocking-syscall idiom the search path uses),
//! so the frame grammar is unit-tested without opening a socket.
//!
//! Fail-closed by construction: a frame longer than `max_frame` or a truncated
//! payload is a hard `error`, never a partial parse; an unknown opcode is
//! rejected. The server answers only `query`/`ping`/`shutdown`; anything it
//! cannot serve warm comes back as `decline` and the client falls back to the
//! certified cold subprocess.

const std = @import("std");
const builtin = @import("builtin");
const request = @import("request.zig");

pub const protocol_version: u8 = 1;

/// Frames larger than this are refused before allocation (a 16 MiB ceiling
/// dwarfs any real file-set response while capping a hostile/looping peer).
pub const max_frame: u32 = 16 << 20;

pub const Opcode = enum(u8) {
    hello = 1, // C→S: [u8 proto_version]
    ready = 2, // S→C: [u8 proto][u64 daemon_gen][u64 session_gen][u32 n][gen bytes]
    query = 3, // C→S: [u8 mode][u8 flags][pattern bytes]
    result = 4, // S→C: [u8 mode] then files/count/lines body
    decline = 5, // S→C: (no payload) — answer this request cold
    err = 6, // S→C: [message bytes]
    shutdown = 7, // C→S: (no payload)
    status = 8, // C→S: (no payload) → S replies `ready`
    ping = 9, // C→S: (no payload)
    pong = 10, // S→C: (no payload)
    // ADDITIVE (protocol stays v1): a `lines` answer streams as zero or more
    // `chunk` frames of raw pre-rendered output bytes, then one terminal
    // `result` frame `[mode=lines][u8 matched]`. Chunking keeps every frame
    // under `max_frame` for an arbitrarily large answer; an OLD daemon never
    // emits `chunk` (it declines the unknown `lines` mode byte first), and an
    // old client never requests it — so v1 peers interop unchanged.
    chunk = 11, // S→C: [raw output bytes]

    pub fn fromByte(b: u8) ?Opcode {
        return std.enums.fromInt(Opcode, b);
    }
};

const flag_fixed: u8 = 1 << 0;
const flag_ignore_case: u8 = 1 << 1;
const flag_line_num: u8 = 1 << 2; // `-n` (meaningful for `lines` mode only)

/// Chunk payload budget for a streamed `lines` answer — comfortably under
/// `max_frame` while keeping per-frame overhead negligible.
pub const chunk_bytes: usize = 4 << 20;

pub const WireError = error{ FrameTooLarge, Truncated, BadOpcode, BadFrame, ConnClosed, Io, OutOfMemory };

// ─────────────────────────── frame codec ───────────────────────────

/// Append a `[len][opcode][payload]` frame to `buf`.
pub fn writeFrame(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, op: Opcode, payload: []const u8) !void {
    const len: u32 = @intCast(1 + payload.len);
    var hdr: [4]u8 = undefined;
    std.mem.writeInt(u32, &hdr, len, .little);
    try buf.appendSlice(gpa, &hdr);
    try buf.append(gpa, @intFromEnum(op));
    try buf.appendSlice(gpa, payload);
}

pub const Parsed = struct { op: Opcode, payload: []const u8, consumed: usize };

/// Parse one frame from the front of `bytes`, or `null` when `bytes` doesn't yet
/// hold a whole frame (the caller reads more). `FrameTooLarge`/`BadOpcode` are
/// hard errors (fail-closed).
pub fn parseFrame(bytes: []const u8) WireError!?Parsed {
    if (bytes.len < 4) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0 or len > max_frame) return WireError.FrameTooLarge;
    const total = 4 + @as(usize, len);
    if (bytes.len < total) return null;
    const op = Opcode.fromByte(bytes[4]) orelse return WireError.BadOpcode;
    return .{ .op = op, .payload = bytes[5..total], .consumed = total };
}

// ─────────────────────────── query encode/decode ───────────────────────────

pub fn encodeQuery(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, req: request.Request) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(req.mode));
    var flags: u8 = 0;
    if (req.fixed) flags |= flag_fixed;
    if (req.ignore_case) flags |= flag_ignore_case;
    if (req.line_num) flags |= flag_line_num;
    try body.append(gpa, flags);
    try body.appendSlice(gpa, req.pattern);
    try writeFrame(buf, gpa, .query, body.items);
}

/// Decode a `query` payload. `pattern` aliases into `payload` (the caller keeps
/// the frame buffer alive for the query's duration).
pub fn decodeQuery(payload: []const u8) WireError!request.Request {
    if (payload.len < 2) return WireError.BadFrame;
    const mode = std.enums.fromInt(request.Mode, payload[0]) orelse return WireError.BadFrame;
    const flags = payload[1];
    const pattern = payload[2..];
    if (pattern.len == 0) return WireError.BadFrame;
    return .{
        .pattern = pattern,
        .mode = mode,
        .fixed = flags & flag_fixed != 0,
        .ignore_case = flags & flag_ignore_case != 0,
        .line_num = flags & flag_line_num != 0,
    };
}

// ─────────────────────────── result encode/decode ───────────────────────────

pub fn encodeFiles(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, files: []const []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(request.Mode.files));
    try appendU32(&body, gpa, @intCast(files.len));
    for (files) |f| {
        try appendU32(&body, gpa, @intCast(f.len));
        try body.appendSlice(gpa, f);
    }
    try writeFrame(buf, gpa, .result, body.items);
}

pub fn encodeCount(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, count: u64) !void {
    var body: [9]u8 = undefined;
    body[0] = @intFromEnum(request.Mode.count);
    std.mem.writeInt(u64, body[1..9], count, .little);
    try writeFrame(buf, gpa, .result, &body);
}

/// Frame a whole pre-rendered `lines` answer: `out` split into `chunk` frames
/// of at most `chunk_bytes`, then the terminal `result` frame carrying only the
/// matched flag (the exit-code boolean). Zero chunks for a no-output answer is
/// legal — the terminal frame alone says "ran warm, nothing matched".
pub fn encodeLines(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, out: []const u8, matched: bool) !void {
    var rest = out;
    while (rest.len > 0) {
        const n = @min(rest.len, chunk_bytes);
        try writeFrame(buf, gpa, .chunk, rest[0..n]);
        rest = rest[n..];
    }
    const body = [_]u8{ @intFromEnum(request.Mode.lines), @intFromBool(matched) };
    try writeFrame(buf, gpa, .result, &body);
}

pub const ResultView = union(request.Mode) {
    files: FileIter,
    count: u64,
    /// The terminal frame of a chunk-streamed `lines` answer: whether any file
    /// matched (the output bytes themselves arrived in prior `chunk` frames).
    lines: bool,
};

/// Zero-copy view over a decoded `result` payload; `FileIter` yields each path
/// as a slice into `payload`.
pub fn decodeResult(payload: []const u8) WireError!ResultView {
    if (payload.len < 1) return WireError.BadFrame;
    const mode = std.enums.fromInt(request.Mode, payload[0]) orelse return WireError.BadFrame;
    return switch (mode) {
        .count => blk: {
            if (payload.len < 9) return WireError.BadFrame;
            break :blk .{ .count = std.mem.readInt(u64, payload[1..9], .little) };
        },
        .files => blk: {
            if (payload.len < 5) return WireError.BadFrame;
            const n = std.mem.readInt(u32, payload[1..5], .little);
            break :blk .{ .files = .{ .rest = payload[5..], .remaining = n } };
        },
        .lines => blk: {
            if (payload.len < 2) return WireError.BadFrame;
            break :blk .{ .lines = payload[1] != 0 };
        },
    };
}

pub const FileIter = struct {
    rest: []const u8,
    remaining: u32,

    pub fn next(self: *FileIter) WireError!?[]const u8 {
        if (self.remaining == 0) return null;
        if (self.rest.len < 4) return WireError.BadFrame;
        const len = std.mem.readInt(u32, self.rest[0..4], .little);
        if (self.rest.len < 4 + @as(usize, len)) return WireError.BadFrame;
        const s = self.rest[4 .. 4 + len];
        self.rest = self.rest[4 + len ..];
        self.remaining -= 1;
        return s;
    }
};

pub fn encodeReady(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, daemon_gen: u64, session_gen: u64, index_gen: []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, protocol_version);
    try appendU64(&body, gpa, daemon_gen);
    try appendU64(&body, gpa, session_gen);
    try appendU32(&body, gpa, @intCast(index_gen.len));
    try body.appendSlice(gpa, index_gen);
    try writeFrame(buf, gpa, .ready, body.items);
}

pub const Ready = struct { proto: u8, daemon_gen: u64, session_gen: u64, index_gen: []const u8 };

pub fn decodeReady(payload: []const u8) WireError!Ready {
    if (payload.len < 21) return WireError.BadFrame;
    const n = std.mem.readInt(u32, payload[17..21], .little);
    if (payload.len < 21 + @as(usize, n)) return WireError.BadFrame;
    return .{
        .proto = payload[0],
        .daemon_gen = std.mem.readInt(u64, payload[1..9], .little),
        .session_gen = std.mem.readInt(u64, payload[9..17], .little),
        .index_gen = payload[21 .. 21 + n],
    };
}

fn appendU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

fn appendU64(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try buf.appendSlice(gpa, &b);
}

// ─────────────────────────── fd transport ───────────────────────────

/// Write every byte of `bytes` to `fd`, retrying short writes; false on a dead
/// peer (EPIPE) or error — the caller drops the connection. The send never
/// raises SIGPIPE: a write to a half-closed socket must cost the daemon/client
/// one dropped connection, never a fatal signal that kills the whole process.
/// Linux uses MSG_NOSIGNAL per send; Darwin/BSD has no such flag, so SO_NOSIGPIPE
/// is armed on the fd (idempotent — kept here so server, client, and tests
/// inherit the guard without touching each socket's birthplace). Only the socket
/// path is affected; the CLI's stdout SIGPIPE (the `gist | head` early exit) is
/// deliberately left intact.
pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    if (comptime builtin.os.tag.isDarwin()) {
        const on: c_int = 1;
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.NOSIGPIPE, std.mem.asBytes(&on)) catch {};
    }
    var off: usize = 0;
    while (off < bytes.len) {
        const sent = sendNoSigpipe(fd, bytes.ptr + off, bytes.len - off);
        if (sent <= 0) return false;
        off += @intCast(sent);
    }
    return true;
}

/// One SIGPIPE-safe `send` (see `writeAll`); byte count, ≤ 0 on a dead peer/error.
/// Both paths use `sendto` so the `[*]const u8` buffer type matches without
/// `@ptrCast` — Darwin has no MSG_NOSIGNAL (SO_NOSIGPIPE is armed in `writeAll`).
fn sendNoSigpipe(fd: std.posix.fd_t, ptr: [*]const u8, len: usize) isize {
    const flags: u32 = if (comptime builtin.os.tag == .linux) std.posix.MSG.NOSIGNAL else 0;
    return @bitCast(std.posix.system.sendto(fd, ptr, len, flags, null, 0));
}

/// Send one framed message on `fd`.
pub fn sendFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t, op: Opcode, payload: []const u8) WireError!void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    writeFrame(&buf, gpa, op, payload) catch return WireError.OutOfMemory;
    if (!writeAll(fd, buf.items)) return WireError.ConnClosed;
}

/// A framed message read off `fd`, owning its bytes (payload aliases into it).
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

/// Read exactly `n` bytes into `dst`, false on EOF/short read (closed peer).
fn readExact(fd: std.posix.fd_t, dst: []u8) bool {
    var off: usize = 0;
    while (off < dst.len) {
        const n = std.posix.system.read(fd, dst.ptr + off, dst.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// Receive one whole frame from `fd`, allocating its backing bytes. `ConnClosed`
/// on a clean/again-truncated peer; `FrameTooLarge`/`BadOpcode` fail closed.
pub fn recvFrame(gpa: std.mem.Allocator, fd: std.posix.fd_t) WireError!Frame {
    var hdr: [4]u8 = undefined;
    if (!readExact(fd, &hdr)) return WireError.ConnClosed;
    const len = std.mem.readInt(u32, &hdr, .little);
    if (len == 0 or len > max_frame) return WireError.FrameTooLarge;
    const total = 4 + @as(usize, len);
    const bytes = gpa.alloc(u8, total) catch return WireError.OutOfMemory;
    errdefer gpa.free(bytes);
    @memcpy(bytes[0..4], &hdr);
    if (!readExact(fd, bytes[4..])) return WireError.ConnClosed;
    const op = Opcode.fromByte(bytes[4]) orelse return WireError.BadOpcode;
    return .{ .op = op, .bytes = bytes, .gpa = gpa };
}
