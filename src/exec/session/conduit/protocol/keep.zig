//! The answer keep (v8) — `recall` · `recalled` · `retain`.
//!
//! The one chapter of this protocol that carries no query grammar at all. A
//! caller asks whether the daemon still holds the answer it minted for an
//! opaque `key`, and the daemon answers a question about the CORPUS EPOCH, not
//! about the query: it never parses, plans, or recomputes the verb being
//! cached, so it cannot recompute it wrongly. `retain` offers a computed answer
//! back stamped with the epoch it was read at, and the daemon keeps it only if
//! the corpus has not moved since.

const std = @import("std");
const wire = @import("../wire.zig");
const frame = @import("opcodes.zig");

const WireError = frame.WireError;

/// Ask whether the daemon still holds an answer for `key`. The key is the whole
/// payload: it is opaque to the wire — the client mints it and the daemon only
/// compares it — so no query grammar crosses this frame.
pub fn encodeRecall(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, key: []const u8) !void {
    try frame.writeFrame(buf, gpa, .recall, key);
}

/// A held answer: the face's own result code plus the bytes it rendered. Named
/// rather than anonymous because both peers build one — an anonymous parameter
/// struct is a type only the callee can spell, so a caller assembling the value
/// before the call cannot hand it over.
pub const Hit = struct { code: u8, answer: []const u8 };

/// What the daemon knows about a recalled key. `epoch` is meaningful whenever
/// `ok`, hit or miss: on a miss it is what to stamp the eventual `retain` with,
/// which is how a client proves its cold answer was computed over corpus bytes
/// that had not moved since.
pub const Recalled = struct {
    ok: bool,
    epoch: u64 = 0,
    hit: ?Hit = null,
};

/// An epoch the daemon can stand behind, and the answer it holds at it (if any).
pub const Vouched = struct { epoch: u64, hit: ?Hit };

/// Encode a recall answer. `vouched == null` ⇒ the single `ok=0` byte: the
/// daemon cannot name an epoch, so this run must not use the keep at all.
pub fn encodeRecalled(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, vouched: ?Vouched) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const v = vouched orelse {
        try body.append(gpa, 0);
        return frame.writeFrame(buf, gpa, .recalled, body.items);
    };
    try body.append(gpa, 1);
    try body.append(gpa, @intFromBool(v.hit != null));
    try wire.appendInt(u64, &body, gpa, v.epoch);
    if (v.hit) |h| {
        try body.append(gpa, h.code);
        try wire.appendInt(u32, &body, gpa, @intCast(h.answer.len));
        try body.appendSlice(gpa, h.answer);
    }
    try frame.writeFrame(buf, gpa, .recalled, body.items);
}

/// Decode a `recalled` payload. The answer bytes alias the frame buffer, so the
/// caller keeps it alive until it has written them out.
pub fn decodeRecalled(payload: []const u8) WireError!Recalled {
    if (payload.len < 1) return WireError.UnexpectedFrame;
    if (payload[0] == 0) return .{ .ok = false };
    if (payload.len < 10) return WireError.UnexpectedFrame;
    const epoch = std.mem.readInt(u64, payload[2..10], .little);
    if (payload[1] == 0) return .{ .ok = true, .epoch = epoch };
    if (payload.len < 15) return WireError.UnexpectedFrame;
    const len = std.mem.readInt(u32, payload[11..15], .little);
    if (payload.len - 15 != len) return WireError.UnexpectedFrame;
    return .{ .ok = true, .epoch = epoch, .hit = .{ .code = payload[10], .answer = payload[15..] } };
}

/// Offer a computed answer back to the keep, stamped with the epoch the client
/// read BEFORE it started computing.
pub fn encodeRetain(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    epoch: u64,
    code: u8,
    key: []const u8,
    answer: []const u8,
) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try wire.appendInt(u64, &body, gpa, epoch);
    try body.append(gpa, code);
    try wire.appendInt(u32, &body, gpa, @intCast(key.len));
    try body.appendSlice(gpa, key);
    try body.appendSlice(gpa, answer);
    try frame.writeFrame(buf, gpa, .retain, body.items);
}

/// A retention offer. Both slices alias the frame buffer.
pub const Retention = struct { epoch: u64, code: u8, key: []const u8, answer: []const u8 };

pub fn decodeRetain(payload: []const u8) WireError!Retention {
    if (payload.len < 13) return WireError.UnexpectedFrame;
    const klen = std.mem.readInt(u32, payload[9..13], .little);
    if (payload.len - 13 < klen) return WireError.UnexpectedFrame;
    return .{
        .epoch = std.mem.readInt(u64, payload[0..8], .little),
        .code = payload[8],
        .key = payload[13 .. 13 + klen],
        .answer = payload[13 + klen ..],
    };
}
