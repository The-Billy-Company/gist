//! gist resident session — the UDS wire-protocol codec suite.
//!
//! Pure encode/decode over byte slices (no socket). Round-trips are lossless;
//! malformed frames are hard errors.

const std = @import("std");
const protocol = @import("protocol.zig");
const request = @import("irregex").session.request;

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

test "query v2 round-trips the raw smart_case bit independently of ignore_case" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const req = request.Request{ .pattern = "Needle", .mode = .lines, .smart_case = true };
    try protocol.encodeQuery(&buf, gpa, req);

    const p = try roundTrip(&buf);
    const got = try protocol.decodeQuery(p.payload);
    try std.testing.expect(got.smart_case);
    try std.testing.expect(!got.ignore_case);
    try std.testing.expect(!got.fixed);
    try std.testing.expect(!got.word);
    try std.testing.expectEqualStrings("Needle", got.pattern);
}

test "query v2 round-trips the word bit (lane 2) independently of the rest" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const req = request.Request{ .pattern = "run", .mode = .count, .word = true };
    try protocol.encodeQuery(&buf, gpa, req);

    const p = try roundTrip(&buf);
    const got = try protocol.decodeQuery(p.payload);
    try std.testing.expect(got.word);
    try std.testing.expect(!got.fixed and !got.ignore_case and !got.smart_case and !got.line_num);
    try std.testing.expectEqualStrings("run", got.pattern);
}

test "query v2 round-trips the quiet bit (lane 4) independently of the rest" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const req = request.Request{ .pattern = "err", .mode = .lines, .quiet = true };
    try protocol.encodeQuery(&buf, gpa, req);

    const p = try roundTrip(&buf);
    const got = try protocol.decodeQuery(p.payload);
    try std.testing.expect(got.quiet);
    try std.testing.expectEqual(@as(?u64, null), got.max_count);
    try std.testing.expect(!got.fixed and !got.word and !got.ignore_case and !got.smart_case);
    try std.testing.expectEqualStrings("err", got.pattern);
}

test "query v2 round-trips the max_count u64 (lane 4) at 0, 1, and > u32" {
    inline for (.{ @as(u64, 0), @as(u64, 1), @as(u64, 4_294_967_301) }) |m| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        const req = request.Request{ .pattern = "needle", .mode = .count, .max_count = m };
        try protocol.encodeQuery(&buf, gpa, req);

        const p = try roundTrip(&buf);
        const got = try protocol.decodeQuery(p.payload);
        try std.testing.expectEqual(@as(?u64, m), got.max_count);
        try std.testing.expect(!got.quiet);
        try std.testing.expectEqualStrings("needle", got.pattern);
    }
    // Absent max_count leaves the field null (no bit 7, no u64 on the wire).
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(gpa);
    try protocol.encodeQuery(&buf2, gpa, .{ .pattern = "x", .mode = .lines });
    try std.testing.expectEqual(@as(?u64, null), (try protocol.decodeQuery((try roundTrip(&buf2)).payload)).max_count);
}

test "decodeQuery round-trips the invert bit; the flag byte is now fully assigned" {
    // Lane 3b: bit 4 (`-v`) joins `known_flags` — the set-complement makes it
    // warm-eligible, so a set invert bit decodes to `invert = true` (no longer
    // UnexpectedFrame → cold).
    const payload = [_]u8{ @intFromEnum(request.Mode.lines), 1 << 4, 'n' };
    const got = try protocol.decodeQuery(&payload);
    try std.testing.expect(got.invert);
    try std.testing.expectEqualStrings("n", got.pattern);
    // Every bit 0..7 now carries an engine semantic, so `known_flags` spans the
    // whole byte — fail-closed on a malformed query now rests on the version
    // handshake plus the length/opcode gates, not a spare reserved bit.
    try std.testing.expectEqual(@as(u8, 0xFF), protocol.known_flags);
    // A full encode→decode preserves invert alongside the rest of the family.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeQuery(&buf, gpa, .{ .pattern = "needle", .mode = .files, .invert = true, .word = true });
    const rt = try protocol.decodeQuery((try roundTrip(&buf)).payload);
    try std.testing.expect(rt.invert and rt.word);
}

test "decodeQuery fails closed on a max_count flag with a truncated or pattern-less u64" {
    // Bit 7 set but < 8 bytes for the u64 ⇒ UnexpectedFrame (a truncated frame, not an
    // empty-pattern one). Hand-built: mode, flags=max_count_present, 3 bytes.
    const trunc = [_]u8{ @intFromEnum(request.Mode.files), 1 << 7, 1, 2, 3 };
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeQuery(&trunc));
    // A full 8-byte u64 but no pattern after it ⇒ empty-pattern UnexpectedFrame.
    const no_pat = [_]u8{ @intFromEnum(request.Mode.files), 1 << 7 } ++ [_]u8{0} ** 8;
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeQuery(&no_pat));
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
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeResult(&.{@intFromEnum(request.Mode.lines)}));
}

test "chunk_fd payload encode/decode preserves length + matched, fails closed short" {
    // The daemon builds the fixed 14-byte control frame by hand (see
    // `sendChunkFd`); parse it back through the shared frame reader + decoder.
    inline for (.{ .{ @as(u64, 1 << 20), true }, .{ @as(u64, 4_294_967_301), false } }) |c| {
        var frame: [14]u8 = undefined;
        std.mem.writeInt(u32, frame[0..4], 1 + 8 + 1, .little);
        frame[4] = @intFromEnum(protocol.Opcode.chunk_fd);
        std.mem.writeInt(u64, frame[5..13], c[0], .little);
        frame[13] = @intFromBool(c[1]);
        const p = (try protocol.parseFrame(&frame)).?;
        try std.testing.expectEqual(protocol.Opcode.chunk_fd, p.op);
        const cf = try protocol.decodeChunkFd(p.payload);
        try std.testing.expectEqual(c[0], cf.length);
        try std.testing.expectEqual(c[1], cf.matched);
    }
    // A payload shorter than [u64 length][u8 matched] fails closed.
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeChunkFd(&.{ 0, 0, 0, 0 }));
}

test "fd-transport capability advertises exactly where the shm path exists" {
    const shm = @import("irregex").inner.session.shm;
    // The advertised set is the fd bit iff this target has the anonymous-shm +
    // SCM_RIGHTS path — a peer on an unsupported target advertises nothing and
    // stays on chunk frames automatically.
    const expect_fd = shm.supported;
    try std.testing.expectEqual(expect_fd, (protocol.caps_supported & protocol.cap_fd_transport) != 0);
    // It is a session/transport capability, NOT a query-flag bit (that byte is full).
    try std.testing.expectEqual(@as(u8, 0xFF), protocol.known_flags);
    try std.testing.expect(protocol.fd_transport_floor > 0);
}

test "ready handshake encode/decode preserves both generations, the image, and the index gen" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeReady(&buf, gpa, 7, 42, 0xDEADBEEFCAFEF00D, "gen-abc123");

    const p = try roundTrip(&buf);
    try std.testing.expectEqual(protocol.Opcode.ready, p.op);
    const r = try protocol.decodeReady(p.payload);
    try std.testing.expectEqual(protocol.protocol_version, r.proto);
    try std.testing.expectEqual(@as(u64, 7), r.daemon_gen);
    try std.testing.expectEqual(@as(u64, 42), r.session_gen);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEFCAFEF00D), r.image);
    try std.testing.expectEqualStrings("gen-abc123", r.index_gen);
}

test "ready decode fails closed on a v8-shaped payload (no image field)" {
    // The exact bytes a pre-v9 daemon would send for `(7, 42, "gen-abc123")`:
    // 21 header bytes instead of 29. It must not silently reinterpret the index
    // gen's length prefix as an image — a mis-parse here is how a stale daemon
    // would slip past the very check this field exists to make.
    var v8: std.ArrayList(u8) = .empty;
    defer v8.deinit(gpa);
    try v8.append(gpa, 8);
    try v8.appendNTimes(gpa, 0, 16); // daemon_gen + session_gen
    try v8.appendSlice(gpa, &.{ 10, 0, 0, 0 }); // u32 len = 10
    try v8.appendSlice(gpa, "gen-abc123");
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeReady(v8.items));
}

test "parseFrame fails closed on a zero-length or oversized frame" {
    var zero = [_]u8{ 0, 0, 0, 0, 1 }; // len == 0
    try std.testing.expectError(protocol.WireError.StreamTooLong, protocol.parseFrame(&zero));

    var huge: [5]u8 = undefined;
    std.mem.writeInt(u32, huge[0..4], protocol.max_frame + 1, .little);
    huge[4] = 1;
    try std.testing.expectError(protocol.WireError.StreamTooLong, protocol.parseFrame(&huge));
}

test "parseFrame rejects an unknown opcode" {
    var bad = [_]u8{ 1, 0, 0, 0, 250 }; // len 1, opcode 250 ∉ Opcode
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.parseFrame(&bad));
}

test "decodeQuery / decodeResult reject truncated payloads" {
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeQuery(&.{})); // < 2 bytes
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeQuery(&.{ @intFromEnum(request.Mode.files), 0 })); // empty pattern
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeResult(&.{})); // no mode byte
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeResult(&.{@intFromEnum(request.Mode.count)})); // count < 9 bytes
}

test "FileIter fails closed on a truncated path length" {
    // mode=files, n=1, then a path length of 8 with only 2 bytes behind it.
    var payload = [_]u8{ @intFromEnum(request.Mode.files), 1, 0, 0, 0, 8, 0, 0, 0, 'a', 'b' };
    var view = try protocol.decodeResult(&payload);
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, view.files.next());
}

test "query_ext round-trips the PathFilter and the --rank trailer" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // A scoped rank query: regex pattern, `-i`, a PATH root, and `--rank=5`.
    const sent: request.Request = .{
        .pattern = "WalletService",
        .mode = .lines,
        .ignore_case = true,
        .rank_k = 5,
        .filter = .{ .roots = &.{"services/ai"}, .includes = &.{"*.py"}, .excludes = &.{"*_pb2.py"}, .exts = &.{} },
    };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeQueryExt(&buf, gpa, sent);

    const p = try roundTrip(&buf);
    try std.testing.expectEqual(protocol.Opcode.query_ext, p.op);
    const got = try protocol.decodeQueryExt(arena.allocator(), p.payload);
    try std.testing.expectEqualStrings("WalletService", got.pattern);
    try std.testing.expect(got.ignore_case);
    try std.testing.expectEqual(@as(?usize, 5), got.rank_k);
    try std.testing.expectEqualStrings("services/ai", got.filter.roots[0]);
    try std.testing.expectEqualStrings("*.py", got.filter.includes[0]);
    try std.testing.expectEqualStrings("*_pb2.py", got.filter.excludes[0]);

    // A bare `--rank` (default top-20 sentinel 0) survives; and a non-rank scoped
    // query decodes back to `rank_k == null` (the presence byte is 0).
    {
        var b2: std.ArrayList(u8) = .empty;
        defer b2.deinit(gpa);
        var s2 = sent;
        s2.rank_k = 0;
        try protocol.encodeQueryExt(&b2, gpa, s2);
        const p2 = try roundTrip(&b2);
        const g2 = try protocol.decodeQueryExt(arena.allocator(), p2.payload);
        try std.testing.expectEqual(@as(?usize, 0), g2.rank_k);
    }
    {
        var b3: std.ArrayList(u8) = .empty;
        defer b3.deinit(gpa);
        var s3 = sent;
        s3.rank_k = null;
        try protocol.encodeQueryExt(&b3, gpa, s3);
        const p3 = try roundTrip(&b3);
        const g3 = try protocol.decodeQueryExt(arena.allocator(), p3.payload);
        try std.testing.expectEqual(@as(?usize, null), g3.rank_k);
        // No window ⇒ the context trailer is one `0` presence byte, decoding to
        // a zero window (never a spurious `-A`/`-B`).
        try std.testing.expectEqual(@as(u64, 0), g3.before);
        try std.testing.expectEqual(@as(u64, 0), g3.after);
    }
    // A `-A`/`-B`/`-C` window round-trips through the context trailer.
    {
        var b4: std.ArrayList(u8) = .empty;
        defer b4.deinit(gpa);
        var s4 = sent;
        s4.rank_k = null;
        s4.before = 3;
        s4.after = 2;
        try protocol.encodeQueryExt(&b4, gpa, s4);
        const p4 = try roundTrip(&b4);
        const g4 = try protocol.decodeQueryExt(arena.allocator(), p4.payload);
        try std.testing.expectEqual(@as(u64, 3), g4.before);
        try std.testing.expectEqual(@as(u64, 2), g4.after);
    }
}

test "query_ext round-trips the -P engine trailer" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // A `-P` query (rootless is fine — the client routes every `-P` through
    // query_ext because the classic `query` flags byte is full).
    const sent: request.Request = .{ .pattern = "foo(?=bar)", .mode = .lines, .pcre = true };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeQueryExt(&buf, gpa, sent);
    const p = try roundTrip(&buf);
    const got = try protocol.decodeQueryExt(arena.allocator(), p.payload);
    try std.testing.expect(got.pcre);
    try std.testing.expectEqualStrings("foo(?=bar)", got.pattern);

    // A non-`-P` scoped query decodes back to `pcre == false`.
    {
        var b2: std.ArrayList(u8) = .empty;
        defer b2.deinit(gpa);
        try protocol.encodeQueryExt(&b2, gpa, .{ .pattern = "x", .mode = .files, .filter = .{ .roots = &.{"libs"} } });
        const p2 = try roundTrip(&b2);
        const g2 = try protocol.decodeQueryExt(arena.allocator(), p2.payload);
        try std.testing.expect(!g2.pcre);
    }
    // The classic `query` opcode never carries the engine bit (always linear).
    {
        var b3: std.ArrayList(u8) = .empty;
        defer b3.deinit(gpa);
        try protocol.encodeQuery(&b3, gpa, .{ .pattern = "x", .mode = .lines });
        const p3 = try roundTrip(&b3);
        try std.testing.expect(!(try protocol.decodeQuery(p3.payload)).pcre);
    }
}

test "changed encode/decode round-trips the since instant (negative included)" {
    inline for (.{ @as(i64, 0), @as(i64, 1_753_000_000_000_000_000), @as(i64, -7) }) |since| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try protocol.encodeChanged(&buf, gpa, since);
        const p = try roundTrip(&buf);
        try std.testing.expectEqual(protocol.Opcode.changed, p.op);
        try std.testing.expectEqual(since, try protocol.decodeChanged(p.payload));
    }
    // Truncated instant fails closed.
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeChanged("short"));
}

test "annals encode/decode: vouched answer round-trips prefix + paths losslessly" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const paths = [_][]const u8{ "src/a.zig", "docs/b.md", "" };
    try protocol.encodeAnnals(&buf, gpa, .{ .prefix = "/repo", .paths = &paths });
    const p = try roundTrip(&buf);
    try std.testing.expectEqual(protocol.Opcode.annals, p.op);
    const view = (try protocol.decodeAnnals(p.payload)) orelse return error.TestExpectedVouch;
    try std.testing.expectEqualStrings("/repo", view.prefix);
    var it = view.paths;
    for (paths) |want| try std.testing.expectEqualStrings(want, (try it.next()) orelse return error.TestExpectedPath);
    try std.testing.expectEqual(@as(?[]const u8, null), try it.next());
}

test "annals encode/decode: decline round-trips as null; malformed payloads fail closed" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeAnnals(&buf, gpa, null);
    const p = try roundTrip(&buf);
    try std.testing.expectEqual(@as(?protocol.AnnalsView, null), try protocol.decodeAnnals(p.payload));

    // Empty payload / truncated prefix / truncated count all fail closed.
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeAnnals(""));
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeAnnals(&[_]u8{ 1, 9, 0, 0, 0, 'x' })); // prefix len 9, 1 byte follows
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeAnnals(&[_]u8{ 1, 1, 0, 0, 0, 'x', 2 })); // count truncated
    // A path list shorter than its declared count fails closed at iteration.
    {
        var b2: std.ArrayList(u8) = .empty;
        defer b2.deinit(gpa);
        const one = [_][]const u8{"a"};
        try protocol.encodeAnnals(&b2, gpa, .{ .prefix = "/r", .paths = &one });
        const p2 = try roundTrip(&b2);
        const raw = p2.payload;
        // Bump the declared count past the encoded list: prefix is "/r" (len 2),
        // so the count u32 sits at offset 1 + 4 + 2.
        var mangled = try gpa.dupe(u8, raw);
        defer gpa.free(mangled);
        std.mem.writeInt(u32, mangled[7..11], 2, .little);
        const v = (try protocol.decodeAnnals(mangled)) orelse return error.TestExpectedVouch;
        var it2 = v.paths;
        _ = try it2.next(); // the real path
        try std.testing.expectError(protocol.WireError.UnexpectedFrame, it2.next()); // the phantom one
    }
}

test "query_ext round-trips the corpus-partition trailer" {
    const genus = @import("irregex").commands.scope.genus;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Every combination of selected × negated genus survives the wire, because a
    // dropped genus would answer a DIFFERENT query warm than cold — silently.
    inline for (.{ genus.Genus.docs, .code, .data }) |g| {
        var sel: genus.Set = .empty;
        sel.add(g);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try protocol.encodeQueryExt(&buf, gpa, .{ .pattern = "x", .mode = .files, .filter = .{ .genera = sel } });
        const got = try protocol.decodeQueryExt(arena.allocator(), (try roundTrip(&buf)).payload);
        try std.testing.expectEqual(sel, got.filter.genera);
        try std.testing.expect(!got.filter.neg_genera.any());

        var nbuf: std.ArrayList(u8) = .empty;
        defer nbuf.deinit(gpa);
        try protocol.encodeQueryExt(&nbuf, gpa, .{ .pattern = "x", .mode = .files, .filter = .{ .neg_genera = sel } });
        const ngot = try protocol.decodeQueryExt(arena.allocator(), (try roundTrip(&nbuf)).payload);
        try std.testing.expectEqual(sel, ngot.filter.neg_genera);
        try std.testing.expect(!ngot.filter.genera.any());
    }
    // A union rides intact alongside the other trailers it shares a frame with.
    {
        var both: genus.Set = .empty;
        both.add(.docs);
        both.add(.data);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try protocol.encodeQueryExt(&buf, gpa, .{
            .pattern = "needle",
            .mode = .lines,
            .before = 2,
            .after = 3,
            .pcre = true,
            .filter = .{ .roots = &.{"libs"}, .genera = both },
        });
        const got = try protocol.decodeQueryExt(arena.allocator(), (try roundTrip(&buf)).payload);
        try std.testing.expectEqual(both, got.filter.genera);
        try std.testing.expectEqual(@as(u64, 2), got.before);
        try std.testing.expectEqual(@as(u64, 3), got.after);
        try std.testing.expect(got.pcre);
    }
    // An unfiltered scoped query decodes to no constraint at all.
    {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try protocol.encodeQueryExt(&buf, gpa, .{ .pattern = "x", .mode = .files, .filter = .{ .roots = &.{"libs"} } });
        const got = try protocol.decodeQueryExt(arena.allocator(), (try roundTrip(&buf)).payload);
        try std.testing.expect(!got.filter.genera.any() and !got.filter.neg_genera.any());
    }
}

test "a genus byte claiming an unknown genus fails closed" {
    const genus = @import("irregex").commands.scope.genus;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sel: genus.Set = .empty;
    sel.add(.docs);
    try protocol.encodeQueryExt(&buf, gpa, .{ .pattern = "x", .mode = .files, .filter = .{ .genera = sel } });
    // The trailer is the last two bytes; set a bit no genus owns. Dropping an
    // unrecognized constraint would silently widen the answer, so this must be a
    // hard frame error (→ decline → cold), never a lenient parse.
    buf.items[buf.items.len - 2] |= 0x80;
    const p = try roundTrip(&buf);
    try std.testing.expectError(protocol.WireError.UnexpectedFrame, protocol.decodeQueryExt(arena.allocator(), p.payload));
}

test "genus Set bits round-trip every subset, and reject the impossible" {
    const genus = @import("irregex").commands.scope.genus;
    // All 8 subsets of the 3-genus partition survive bits→fromBits unchanged.
    for (0..8) |raw| {
        const b: u8 = @intCast(raw);
        const s = genus.Set.fromBits(b) orelse return error.SubsetRejected;
        try std.testing.expectEqual(b, s.bits());
    }
    // Every byte above the partition's width is refused rather than truncated.
    for (8..256) |raw| try std.testing.expectEqual(@as(?genus.Set, null), genus.Set.fromBits(@intCast(raw)));
}
