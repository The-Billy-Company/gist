//! The watcher consult — `changed` · `annals`.
//!
//! The `gist index` amend fast path: "which corpus files changed at/after
//! instant S?", answered off the daemon's never-drained watcher ledger rather
//! than a stat walk. The answer is all-or-nothing by construction — a daemon
//! that cannot causally vouch says so with one byte instead of returning a
//! partial list the caller would mistake for the whole truth.

const std = @import("std");
const wire = @import("../wire.zig");
const frame = @import("frame.zig");
const result = @import("result.zig");

const WireError = frame.WireError;

/// Encode the annals consult: one signed instant. `since_ns` is the amend's
/// last freshness anchor (`built.ns`), which is already bounded to i64.
pub fn encodeChanged(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, since_ns: i64) !void {
    var body: [8]u8 = undefined;
    std.mem.writeInt(i64, &body, since_ns, .little);
    try frame.writeFrame(buf, gpa, .changed, &body);
}

pub fn decodeChanged(payload: []const u8) WireError!i64 {
    if (payload.len < 8) return WireError.UnexpectedFrame;
    return std.mem.readInt(i64, payload[0..8], .little);
}

/// Encode an annals answer. `vouched == null` ⇒ the single `ok=0` byte (the
/// ledger cannot vouch); otherwise the armed prefix + the changed-path list.
pub fn encodeAnnals(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, vouched: ?struct { prefix: []const u8, paths: []const []const u8 }) !void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const v = vouched orelse {
        try body.append(gpa, 0);
        return frame.writeFrame(buf, gpa, .annals, body.items);
    };
    try body.append(gpa, 1);
    try wire.appendInt(u32, &body, gpa, @intCast(v.prefix.len));
    try body.appendSlice(gpa, v.prefix);
    try wire.appendInt(u32, &body, gpa, @intCast(v.paths.len));
    for (v.paths) |p| {
        try wire.appendInt(u32, &body, gpa, @intCast(p.len));
        try body.appendSlice(gpa, p);
    }
    try frame.writeFrame(buf, gpa, .annals, body.items);
}

/// A vouched annals answer: the daemon's armed watch prefix + a path iterator
/// (both alias the frame buffer — caller keeps it alive while iterating).
pub const AnnalsView = struct { prefix: []const u8, paths: result.FileIter };

/// Decode an `annals` payload. Null ⇒ the daemon declined to vouch (the
/// caller runs its fallback); truncation fails closed as `UnexpectedFrame`.
pub fn decodeAnnals(payload: []const u8) WireError!?AnnalsView {
    if (payload.len < 1) return WireError.UnexpectedFrame;
    if (payload[0] == 0) return null;
    var rest = payload[1..];
    const prefix = try frame.takeLenPrefixed(&rest);
    if (rest.len < 4) return WireError.UnexpectedFrame;
    const n = std.mem.readInt(u32, rest[0..4], .little);
    return .{ .prefix = prefix, .paths = .{ .rest = rest[4..], .remaining = n } };
}
