//! gist resident session — the UDS wire-protocol codec suite (ADR-352 rung 2.5).
//!
//! The codec is pure (encode into / decode from byte slices), so the whole
//! frame grammar is proven without opening a socket. Two properties matter: a
//! round-trip is lossless (every request/result/handshake survives encode →
//! decode byte-for-byte), and every malformed frame is a hard `error`, never a
//! partial parse — the fail-closed contract that lets the daemon reject a
//! hostile or truncated peer instead of answering garbage.

const std = @import("std");
const protocol = @import("protocol.zig");
const request = @import("request.zig");

const gpa = std.testing.allocator;

/// Encode one frame and return the parser's view of it (the round-trip the
/// server and client each perform over the socket).
fn roundTrip(buf: *std.ArrayList(u8)) !protocol.Parsed {
    return (try protocol.parseFrame(buf.items)) orelse return error.TestExpectedFrame;
}

test "writeFrame ↔ parseFrame round-trips opcode + payload" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.writeFrame(&buf, gpa, .ping, "hello");

    const p = try roundTrip(&buf);
    try std.testing.expectEqual(protocol.Opcode.ping, p.op);
    try std.testing.expectEqualStrings("hello", p.payload);
    try std.testing.expectEqual(buf.items.len, p.consumed);
}

test "parseFrame returns null until a whole frame is buffered" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.writeFrame(&buf, gpa, .query, "payload-bytes");

    // Every strict prefix is an incomplete frame → keep reading, never a parse.
    for (0..buf.items.len) |n| {
        try std.testing.expectEqual(@as(?protocol.Parsed, null), try protocol.parseFrame(buf.items[0..n]));
    }
    try std.testing.expect((try protocol.parseFrame(buf.items)) != null);
}

test "query encode/decode preserves mode, flags, and pattern" {
    inline for (.{ request.Mode.files, request.Mode.count, request.Mode.lines }) |mode| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const req = request.Request{ .pattern = "needle", .mode = mode, .fixed = true, .ignore_case = true, .line_num = true };
        try protocol.encodeQuery(&buf, gpa, req);

        const p = try roundTrip(&buf);
        try std.testing.expectEqual(protocol.Opcode.query, p.op);
        const got = try protocol.decodeQuery(p.payload);
        try std.testing.expectEqual(mode, got.mode);
        try std.testing.expect(got.fixed);
        try std.testing.expect(got.ignore_case);
        try std.testing.expect(got.line_num);
        try std.testing.expectEqualStrings("needle", got.pattern);
    }
}

test "files result encode/decode yields every path in order" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const files = [_][]const u8{ "a/x.zig", "b/y.zig", "c/z.zig" };
    try protocol.encodeFiles(&buf, gpa, &files);

    const p = try roundTrip(&buf);
    try std.testing.expectEqual(protocol.Opcode.result, p.op);
    const view = try protocol.decodeResult(p.payload);
    var iter = view.files;
    for (files) |want| {
        const got = (try iter.next()) orelse return error.TestMissingPath;
        try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), try iter.next());
}

test "count result encode/decode preserves the u64" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeCount(&buf, gpa, 4_294_967_301); // > u32 to prove the width

    const p = try roundTrip(&buf);
    const view = try protocol.decodeResult(p.payload);
    try std.testing.expectEqual(@as(u64, 4_294_967_301), view.count);
}

/// Reassemble a chunk-streamed `lines` answer from a raw frame byte stream —
/// the exact loop the warm client runs over the socket.
fn reassembleLines(bytes: []const u8, out: *std.ArrayList(u8)) !bool {
    var rest = bytes;
    while (true) {
        const p = (try protocol.parseFrame(rest)) orelse return error.TestTruncatedStream;
        rest = rest[p.consumed..];
        switch (p.op) {
            .chunk => try out.appendSlice(gpa, p.payload),
            .result => {
                try std.testing.expectEqual(@as(usize, 0), rest.len); // terminal frame is last
                return (try protocol.decodeResult(p.payload)).lines;
            },
            else => return error.TestUnexpectedFrame,
        }
    }
}

test "lines answer: chunk framing reassembles byte-identically, split at chunk_bytes" {
    // A body larger than one chunk budget must split into ⌈len/chunk_bytes⌉
    // chunks and reassemble to the exact original bytes.
    const body = try gpa.alloc(u8, protocol.chunk_bytes + 1234);
    defer gpa.free(body);
    for (body, 0..) |*b, i| b.* = @truncate(i *% 251);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeLines(&buf, gpa, body, true);

    // First frame is a full-budget chunk, proving the split boundary.
    const first = (try protocol.parseFrame(buf.items)).?;
    try std.testing.expectEqual(protocol.Opcode.chunk, first.op);
    try std.testing.expectEqual(protocol.chunk_bytes, first.payload.len);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    try std.testing.expect(try reassembleLines(buf.items, &got));
    try std.testing.expectEqualSlices(u8, body, got.items);
}

test "lines answer: a no-match reply is zero chunks + a terminal matched=false" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeLines(&buf, gpa, "", false);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    try std.testing.expect(!try reassembleLines(buf.items, &got));
    try std.testing.expectEqualStrings("", got.items);
}

test "decodeResult(lines) rejects a truncated terminal frame" {
    try std.testing.expectError(protocol.WireError.BadFrame, protocol.decodeResult(&.{@intFromEnum(request.Mode.lines)}));
}

test "ready handshake encode/decode preserves both generations and the index gen" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeReady(&buf, gpa, 7, 42, "gen-abc123");

    const p = try roundTrip(&buf);
    try std.testing.expectEqual(protocol.Opcode.ready, p.op);
    const r = try protocol.decodeReady(p.payload);
    try std.testing.expectEqual(protocol.protocol_version, r.proto);
    try std.testing.expectEqual(@as(u64, 7), r.daemon_gen);
    try std.testing.expectEqual(@as(u64, 42), r.session_gen);
    try std.testing.expectEqualStrings("gen-abc123", r.index_gen);
}

test "parseFrame fails closed on a zero-length or oversized frame" {
    var zero = [_]u8{ 0, 0, 0, 0, 1 }; // len == 0
    try std.testing.expectError(protocol.WireError.FrameTooLarge, protocol.parseFrame(&zero));

    var huge: [5]u8 = undefined;
    std.mem.writeInt(u32, huge[0..4], protocol.max_frame + 1, .little);
    huge[4] = 1;
    try std.testing.expectError(protocol.WireError.FrameTooLarge, protocol.parseFrame(&huge));
}

test "parseFrame rejects an unknown opcode" {
    var bad = [_]u8{ 1, 0, 0, 0, 250 }; // len 1, opcode 250 ∉ Opcode
    try std.testing.expectError(protocol.WireError.BadOpcode, protocol.parseFrame(&bad));
}

test "decodeQuery / decodeResult reject truncated payloads" {
    try std.testing.expectError(protocol.WireError.BadFrame, protocol.decodeQuery(&.{})); // < 2 bytes
    try std.testing.expectError(protocol.WireError.BadFrame, protocol.decodeQuery(&.{ @intFromEnum(request.Mode.files), 0 })); // empty pattern
    try std.testing.expectError(protocol.WireError.BadFrame, protocol.decodeResult(&.{})); // no mode byte
    try std.testing.expectError(protocol.WireError.BadFrame, protocol.decodeResult(&.{@intFromEnum(request.Mode.count)})); // count < 9 bytes
}

test "FileIter fails closed on a truncated path length" {
    // mode=files, n=1, then a path length of 8 with only 2 bytes behind it.
    var payload = [_]u8{ @intFromEnum(request.Mode.files), 1, 0, 0, 0, 8, 0, 0, 0, 'a', 'b' };
    var view = try protocol.decodeResult(&payload);
    try std.testing.expectError(protocol.WireError.BadFrame, view.files.next());
}
