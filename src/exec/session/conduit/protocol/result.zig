//! The answer codec — how a served query gets back.
//!
//! One `result` frame per mode: `files` carries its own path list, `count` a
//! single u64, and `lines` a terminal matched bit after zero or more `chunk`
//! frames. A large `lines` answer instead arrives as one `chunk_fd` frame while
//! the rendered bytes ride a shared-memory fd — the carrier changes, the bytes
//! do not, and either path decodes to the same `ResultView`.

const std = @import("std");
const request = @import("irregex").session.request;
const wire = @import("../wire.zig");
const frame = @import("opcodes.zig");

const WireError = frame.WireError;

pub fn encodeFiles(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, files: []const []const u8) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.append(gpa, @intFromEnum(request.Mode.files));
    try wire.appendInt(u32, &body, gpa, @intCast(files.len));
    for (files) |f| {
        try wire.appendInt(u32, &body, gpa, @intCast(f.len));
        try body.appendSlice(gpa, f);
    }
    try frame.writeFrame(buf, gpa, .result, body.items);
}

pub fn encodeCount(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, count: u64) !void {
    var body: [9]u8 = undefined;
    body[0] = @intFromEnum(request.Mode.count);
    std.mem.writeInt(u64, body[1..9], count, .little);
    try frame.writeFrame(buf, gpa, .result, &body);
}

/// Frame a pre-rendered `lines` answer: `out` split into ≤`chunk_bytes` `chunk`
/// frames, then a terminal `result` with the matched flag. Zero chunks is legal.
pub fn encodeLines(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, out: []const u8, matched: bool) !void {
    var rest = out;
    while (rest.len > 0) {
        const n = @min(rest.len, frame.chunk_bytes);
        try frame.writeFrame(buf, gpa, .chunk, rest[0..n]);
        rest = rest[n..];
    }
    const body = [_]u8{ @intFromEnum(request.Mode.lines), @intFromBool(matched) };
    try frame.writeFrame(buf, gpa, .result, &body);
}

/// Hand a rendered `lines` answer to the client as a shared-memory fd: one
/// terminal `chunk_fd` frame carries `{length, matched}` while the answer bytes
/// ride an SCM_RIGHTS fd (`shm_fd`, already filled + frozen by the caller), so
/// they never traverse the socket. REPLACES the `chunk` stream + terminal
/// `result` for this answer. The caller owns the shm buffer (closes it after);
/// the client owns the received fd until it has written stdout. Returns `false`
/// on a dead peer / sendmsg failure — the caller drops the connection.
pub fn sendChunkFd(fd: std.posix.fd_t, len: u64, matched: bool, shm_fd: std.posix.fd_t) bool {
    // [u32 len=10][op][u64 length][u8 matched] — a fixed 14-byte control frame.
    var buf: [14]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1 + 8 + 1, .little);
    buf[4] = @intFromEnum(frame.Opcode.chunk_fd);
    std.mem.writeInt(u64, buf[5..13], len, .little);
    buf[13] = @intFromBool(matched);
    return wire.sendWithFd(fd, &buf, shm_fd);
}

pub const ChunkFd = struct { length: u64, matched: bool };

/// Decode a `chunk_fd` payload (`[u64 length][u8 matched]`); the fd arrives
/// separately via `recvFrameWithFd`.
pub fn decodeChunkFd(payload: []const u8) WireError!ChunkFd {
    if (payload.len < 9) return WireError.UnexpectedFrame;
    return .{ .length = std.mem.readInt(u64, payload[0..8], .little), .matched = payload[8] != 0 };
}

pub const ResultView = union(request.Mode) {
    files: FileIter,
    count: u64,
    /// Terminal `lines` frame: whether any file matched (bytes arrived in prior `chunk`s).
    lines: bool,
};

/// Zero-copy view over a decoded `result` payload; `FileIter` yields slices into `payload`.
pub fn decodeResult(payload: []const u8) WireError!ResultView {
    if (payload.len < 1) return WireError.UnexpectedFrame;
    const mode = std.enums.fromInt(request.Mode, payload[0]) orelse return WireError.UnexpectedFrame;
    return switch (mode) {
        .count => if (payload.len < 9) WireError.UnexpectedFrame else .{ .count = std.mem.readInt(u64, payload[1..9], .little) },
        .files => if (payload.len < 5) WireError.UnexpectedFrame else .{ .files = .{ .rest = payload[5..], .remaining = std.mem.readInt(u32, payload[1..5], .little) } },
        .lines => if (payload.len < 2) WireError.UnexpectedFrame else .{ .lines = payload[1] != 0 },
    };
}

pub const FileIter = struct {
    rest: []const u8,
    remaining: u32,

    pub fn next(self: *FileIter) WireError!?[]const u8 {
        if (self.remaining == 0) return null;
        if (self.rest.len < 4) return WireError.UnexpectedFrame;
        const len = std.mem.readInt(u32, self.rest[0..4], .little);
        if (self.rest.len < 4 + @as(usize, len)) return WireError.UnexpectedFrame;
        const s = self.rest[4 .. 4 + len];
        self.rest = self.rest[4 + len ..];
        self.remaining -= 1;
        return s;
    }
};
