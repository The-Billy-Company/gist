//! gist resident daemon — end-to-end lifecycle over a real Unix socket.
//!
//! Spawns `serve.run` on its own OS thread against a throwaway tree, dials it
//! with the wire protocol a client speaks, and proves the full handshake →
//! query → result → shutdown round-trip: the daemon answers an eligible `-l`
//! query with the correct sorted file set, honors `ping`, and stops cleanly on
//! `shutdown` (the thread joins — no leaked listener, socket unlinked). This is
//! the transport counterpart to `session/resident_test.zig` (which proves the
//! engine's correctness directly); here we prove the socket carries it faithfully.

const std = @import("std");
const serve = @import("serve.zig");
const protocol = @import("../../../../exec/session/protocol.zig");
const request = @import("../../../../exec/session/request.zig");
const shm = @import("../../../../exec/session/shm.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const DaemonArgs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots: []const []const u8,
    socket: []const u8,
};

fn daemonMain(args: DaemonArgs) void {
    serve.run(args.gpa, args.io, args.roots, args.socket) catch {};
}

/// Dial the daemon, retrying to absorb the bind/listen race with the freshly
/// spawned thread. The budget is deliberately generous (~10 s) because this test
/// runs alongside several other test binaries under `zig build test`, and a
/// CPU-starved daemon thread must never turn a scheduling delay into a failure.
fn dial(io: std.Io, socket: []const u8) !net.Stream {
    const ua = try net.UnixAddress.init(socket);
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        if (ua.connect(io)) |s| return s else |_| {}
        try io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .real);
    }
    return error.DaemonNeverCameUp;
}

fn collectFiles(gpa: std.mem.Allocator, fd: std.posix.fd_t, arena: std.mem.Allocator, req: request.Request) ![]const []const u8 {
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    try std.testing.expect(protocol.writeAll(fd, qbuf.items));

    var resp = try protocol.recvFrame(gpa, fd);
    defer resp.deinit();
    try std.testing.expectEqual(protocol.Opcode.result, resp.op);
    const view = try protocol.decodeResult(resp.payload());

    var out: std.ArrayList([]const u8) = .empty;
    switch (view) {
        .files => |iter0| {
            var iter = iter0;
            while (try iter.next()) |p| try out.append(arena, try arena.dupe(u8, p));
        },
        .count => return error.UnexpectedCountFrame,
        .lines => return error.UnexpectedLinesFrame,
    }
    return out.toOwnedSlice(arena);
}

fn collectCount(gpa: std.mem.Allocator, fd: std.posix.fd_t, req: request.Request) !u64 {
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    try std.testing.expect(protocol.writeAll(fd, qbuf.items));

    var resp = try protocol.recvFrame(gpa, fd);
    defer resp.deinit();
    try std.testing.expectEqual(protocol.Opcode.result, resp.op);
    return switch (try protocol.decodeResult(resp.payload())) {
        .count => |c| c,
        else => error.UnexpectedResultMode,
    };
}

const LinesAnswer = struct { out: []const u8, matched: bool };

/// Send a `lines` query and reassemble its chunk-streamed answer: zero or more
/// `chunk` frames of raw pre-rendered bytes, then the terminal `result(lines)`
/// frame carrying the matched flag — the exact grammar the warm CLI client speaks.
fn collectLines(gpa: std.mem.Allocator, fd: std.posix.fd_t, arena: std.mem.Allocator, req: request.Request) !LinesAnswer {
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    try std.testing.expect(protocol.writeAll(fd, qbuf.items));

    var out: std.ArrayList(u8) = .empty;
    while (true) {
        var resp = try protocol.recvFrame(gpa, fd);
        defer resp.deinit();
        switch (resp.op) {
            .chunk => try out.appendSlice(arena, resp.payload()),
            .result => {
                const view = try protocol.decodeResult(resp.payload());
                return switch (view) {
                    .lines => |matched| .{ .out = out.items, .matched = matched },
                    else => error.UnexpectedResultMode,
                };
            },
            else => return error.UnexpectedFrame,
        }
    }
}

fn hasSuffix(files: []const []const u8, suffix: []const u8) bool {
    for (files) |f| if (std.mem.endsWith(u8, f, suffix)) return true;
    return false;
}

const FdLinesAnswer = struct { out: []const u8, matched: bool, via_fd: bool };

/// Send a `lines` query and reassemble its answer over the fd-AWARE receive path
/// (the exact shape the warm CLI client runs once it has advertised
/// `cap_fd_transport`): either a single `chunk_fd` frame — bytes mmap'd from the
/// passed shm fd, never off the socket — or the classic `chunk`+`result` stream.
/// `via_fd` reports which path served it; bytes are duped into `arena`.
fn collectLinesFd(gpa: std.mem.Allocator, fd: std.posix.fd_t, arena: std.mem.Allocator, req: request.Request) !FdLinesAnswer {
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    try std.testing.expect(protocol.writeAll(fd, qbuf.items));

    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const got = try protocol.recvFrameWithFd(gpa, fd);
        var resp = got.frame;
        defer resp.deinit();
        switch (resp.op) {
            .chunk => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                try out.appendSlice(arena, resp.payload());
            },
            .chunk_fd => {
                const cf = try protocol.decodeChunkFd(resp.payload());
                const shm_fd = got.passed_fd orelse return error.MissingPassedFd;
                defer _ = std.c.close(shm_fd);
                const len: usize = @intCast(cf.length);
                if (len > 0) {
                    const view = try shm.mapReadonly(shm_fd, len);
                    defer shm.unmap(view);
                    try out.appendSlice(arena, view[0..len]);
                }
                return .{ .out = out.items, .matched = cf.matched, .via_fd = true };
            },
            .result => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                return switch (try protocol.decodeResult(resp.payload())) {
                    .lines => |m| .{ .out = out.items, .matched = m, .via_fd = false },
                    else => error.UnexpectedResultMode,
                };
            },
            else => return error.UnexpectedFrame,
        }
    }
}

/// HELLO advertising `caps` → READY (the fd-transport negotiation the client does).
fn handshakeCaps(gpa: std.mem.Allocator, fd: std.posix.fd_t, caps: u8) !void {
    try protocol.sendFrame(gpa, fd, .hello, &.{ protocol.protocol_version, caps });
    var ready = try protocol.recvFrame(gpa, fd);
    defer ready.deinit();
    try std.testing.expectEqual(protocol.Opcode.ready, ready.op);
}

test "serve: fd-transport carries an emit-heavy answer byte-identically to chunk frames, honors floor + negotiation + forced fallback" {
    if (!shm.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_fd_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    // An emit-heavy fixture: enough matching lines that the rendered answer
    // clears `fd_transport_floor` (1 MiB) and takes the fd path.
    const line = "needle payload widening each rendered row past the fd-transport floor\n";
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    var rendered_estimate: usize = 0;
    while (rendered_estimate <= protocol.fd_transport_floor * 2) : (rendered_estimate += root.len + 9 + line.len)
        try big.appendSlice(gpa, line);
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/big.txt", .{root}), .data = big.items });
    // A tiny fixture whose answer stays below the floor (chunk frames even when
    // fd is advertised).
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/small.txt", .{root}), .data = "needle once\n" });

    const socket = try std.fmt.allocPrint(a, "{s}/gistd.sock", .{root});
    const roots = try a.dupe([]const u8, &.{root});

    const t = try std.Thread.spawn(.{}, daemonMain, .{DaemonArgs{ .gpa = gpa, .io = io, .roots = roots, .socket = socket }});
    defer t.join();
    defer shm.force_fail_for_test.store(false, .monotonic); // never leak the fault flag

    // "payload" occurs ONLY in big.txt, so the emit-heavy answer is a single doc
    // — one shard, deterministic doc order — which makes the fd==chunk byte
    // comparison airtight (the parallel render's cross-doc order is a separate,
    // sort-equal property owned by the render lane, not the transport).
    const q = request.Request{ .pattern = "payload", .mode = .lines, .fixed = true };

    // (1) Connection advertising fd-transport: the emit-heavy answer rides an fd.
    const fd_out = blk: {
        const s = try dial(io, socket);
        defer s.close(io);
        try handshakeCaps(gpa, s.socket.handle, protocol.caps_supported);
        const big_ans = try collectLinesFd(gpa, s.socket.handle, a, q);
        try std.testing.expect(big_ans.via_fd); // zero-copy path taken
        try std.testing.expect(big_ans.matched);
        try std.testing.expect(big_ans.out.len >= protocol.fd_transport_floor);
        // (2) Floor: a sub-floor answer on the SAME (advertising) connection
        // stays on chunk frames — shm setup isn't earned back for tiny emits.
        const small = try collectLinesFd(gpa, s.socket.handle, a, .{ .pattern = "once", .mode = .lines, .fixed = true });
        try std.testing.expect(!small.via_fd);
        try std.testing.expect(std.mem.endsWith(u8, small.out, "small.txt:needle once\n"));
        break :blk try a.dupe(u8, big_ans.out);
    };

    // (3) Negotiation OFF: a 1-byte HELLO (no caps) gets chunk frames — and the
    // bytes are IDENTICAL to the fd answer.
    {
        const s = try dial(io, socket);
        defer s.close(io);
        try handshakeCaps(gpa, s.socket.handle, 0);
        const ans = try collectLinesFd(gpa, s.socket.handle, a, q);
        try std.testing.expect(!ans.via_fd);
        try std.testing.expectEqualSlices(u8, fd_out, ans.out);
    }

    // (4) Forced fallback: shm path made to fail → daemon falls to chunk frames,
    // byte-identical, even though the client advertised and the answer clears the
    // floor. Proves the fail-open is not a new failure mode.
    {
        shm.force_fail_for_test.store(true, .monotonic);
        const s = try dial(io, socket);
        defer s.close(io);
        try handshakeCaps(gpa, s.socket.handle, protocol.caps_supported);
        const ans = try collectLinesFd(gpa, s.socket.handle, a, q);
        try std.testing.expect(!ans.via_fd); // fell back to chunk frames
        try std.testing.expectEqualSlices(u8, fd_out, ans.out);
        shm.force_fail_for_test.store(false, .monotonic);
    }
}

test "serve: handshake → -l query → ping → shutdown round-trips over the socket" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_serve_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.txt", .{root}), .data = "WalletService here\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/b.txt", .{root}), .data = "nothing\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/c.txt", .{root}), .data = "also WalletService\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/d.txt", .{root}), .data = "walletservice lower\n" });
    // Word-boundary fixtures (lane 2): e has a word-valid `run` per line (the
    // second only AFTER a word-rejected `rerun` occurrence), f only substring
    // hits, g only a Unicode-neighbor-rejected hit (`é` beside the match).
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/e.txt", .{root}), .data = "run runner\nrerun run\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/f.txt", .{root}), .data = "runner only\n" });
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/g.txt", .{root}), .data = "\xc3\xa9run here\n" });

    const socket = try std.fmt.allocPrint(a, "{s}/gistd.sock", .{root});
    const roots = try a.dupe([]const u8, &.{root});

    const t = try std.Thread.spawn(.{}, daemonMain, .{DaemonArgs{ .gpa = gpa, .io = io, .roots = roots, .socket = socket }});
    defer t.join();

    const stream = try dial(io, socket);
    defer stream.close(io);
    const fd = stream.socket.handle;

    // HELLO → READY (proto version echoes back).
    try protocol.sendFrame(gpa, fd, .hello, &.{protocol.protocol_version});
    {
        var ready = try protocol.recvFrame(gpa, fd);
        defer ready.deinit();
        try std.testing.expectEqual(protocol.Opcode.ready, ready.op);
        const r = try protocol.decodeReady(ready.payload());
        try std.testing.expectEqual(protocol.protocol_version, r.proto);
    }

    // Eligible `-l` query returns the sorted matching-file set.
    const files = try collectFiles(gpa, fd, a, .{ .pattern = "WalletService", .mode = .files, .fixed = true });
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expect(hasSuffix(files, "a.txt"));
    try std.testing.expect(hasSuffix(files, "c.txt"));
    try std.testing.expect(!hasSuffix(files, "b.txt"));

    // Bare `lines` query: chunk-streamed pre-rendered `path:text` rows in
    // cold's `pathLess` file order, then the terminal matched flag.
    {
        const lr = try collectLines(gpa, fd, a, .{ .pattern = "WalletService", .mode = .lines, .fixed = true });
        try std.testing.expect(lr.matched);
        const want = try std.fmt.allocPrint(a, "{s}/a.txt:WalletService here\n{s}/c.txt:also WalletService\n", .{ root, root });
        try std.testing.expectEqualStrings(want, lr.out);
    }
    // `-n` flips the same rows to `path:line:text`.
    {
        const lr = try collectLines(gpa, fd, a, .{ .pattern = "WalletService", .mode = .lines, .fixed = true, .line_num = true });
        try std.testing.expect(lr.matched);
        const want = try std.fmt.allocPrint(a, "{s}/a.txt:1:WalletService here\n{s}/c.txt:1:also WalletService\n", .{ root, root });
        try std.testing.expectEqualStrings(want, lr.out);
    }
    // A no-match `lines` query: zero chunks, terminal `matched = false`.
    {
        const lr = try collectLines(gpa, fd, a, .{ .pattern = "NoSuchNeedleAnywhere", .mode = .lines, .fixed = true });
        try std.testing.expect(!lr.matched);
        try std.testing.expectEqualStrings("", lr.out);
    }

    // v2 smart-case over the wire: a lowercase pattern under -S folds caseless
    // (all three casings match — identical to -i bytes), an uppercase pattern
    // stays case-sensitive (the raw bit crossed the socket; the SESSION
    // resolved it against the pattern).
    {
        const folded = try collectFiles(gpa, fd, a, .{ .pattern = "walletservice", .mode = .files, .fixed = true, .smart_case = true });
        try std.testing.expectEqual(@as(usize, 3), folded.len);
        try std.testing.expect(hasSuffix(folded, "a.txt"));
        try std.testing.expect(hasSuffix(folded, "c.txt"));
        try std.testing.expect(hasSuffix(folded, "d.txt"));
    }
    {
        const exact = try collectFiles(gpa, fd, a, .{ .pattern = "WalletService", .mode = .files, .fixed = true, .smart_case = true });
        try std.testing.expectEqual(@as(usize, 2), exact.len);
        try std.testing.expect(!hasSuffix(exact, "d.txt"));
    }

    // v2 `-w` over the wire (lane 2): the word bit crosses the socket and the
    // engine applies cold's post-match word rule — `runner` (substring hit)
    // and `érun` (Unicode word neighbor) never make the file set, and the
    // word-rejected `rerun` occurrence still finds the later ` run` on its line.
    {
        const w = try collectFiles(gpa, fd, a, .{ .pattern = "run", .mode = .files, .fixed = true, .word = true });
        try std.testing.expectEqual(@as(usize, 1), w.len);
        try std.testing.expect(hasSuffix(w, "e.txt"));
        // Without -w the same pattern reaches f.txt and g.txt too.
        const plain = try collectFiles(gpa, fd, a, .{ .pattern = "run", .mode = .files, .fixed = true });
        try std.testing.expectEqual(@as(usize, 3), plain.len);
    }
    {
        const lr = try collectLines(gpa, fd, a, .{ .pattern = "run", .mode = .lines, .fixed = true, .word = true });
        try std.testing.expect(lr.matched);
        const want = try std.fmt.allocPrint(a, "{s}/e.txt:run runner\n{s}/e.txt:rerun run\n", .{ root, root });
        try std.testing.expectEqualStrings(want, lr.out);
    }

    // v2 `-q` over the wire (lane 4): a quiet query answers as a zero-chunk
    // `lines` frame carrying only the matched flag — existence, no output. A
    // present pattern matches; an absent one does not; `-w` narrows it.
    {
        const yes = try collectLines(gpa, fd, a, .{ .pattern = "WalletService", .mode = .lines, .fixed = true, .quiet = true });
        try std.testing.expect(yes.matched);
        try std.testing.expectEqualStrings("", yes.out);
        const no = try collectLines(gpa, fd, a, .{ .pattern = "NoSuchNeedleAnywhere", .mode = .lines, .fixed = true, .quiet = true });
        try std.testing.expect(!no.matched);
        try std.testing.expectEqualStrings("", no.out);
        // `-q -w`: e.txt still holds a word-valid `run`, so it matches.
        const word_yes = try collectLines(gpa, fd, a, .{ .pattern = "run", .mode = .lines, .fixed = true, .quiet = true, .word = true });
        try std.testing.expect(word_yes.matched);
        try std.testing.expectEqualStrings("", word_yes.out);
    }
    // v2 `-m N` over the wire (lane 4): the u64 cap crosses the socket and the
    // lines face emits at most N rows per file (per-file reset). `-m0` nothing.
    {
        const capped = try collectLines(gpa, fd, a, .{ .pattern = "run", .mode = .lines, .fixed = true, .max_count = 1 });
        try std.testing.expect(capped.matched);
        // e.txt has two `run` lines; -m1 emits only the first. f/g have one each.
        const want = try std.fmt.allocPrint(a, "{s}/e.txt:run runner\n{s}/f.txt:runner only\n{s}/g.txt:\xc3\xa9run here\n", .{ root, root, root });
        try std.testing.expectEqualStrings(want, capped.out);
        const nothing = try collectLines(gpa, fd, a, .{ .pattern = "run", .mode = .lines, .fixed = true, .max_count = 0 });
        try std.testing.expect(!nothing.matched);
        try std.testing.expectEqualStrings("", nothing.out);
    }

    // v2 `-v` over the wire (lane 3b): the set-complement makes invert warm-
    // eligible, so the daemon now SERVES it (no longer DECLINE). `-v -l`
    // qualifies every file with a non-matching line — a/c (one line, all
    // matching) drop out; the other five stay.
    {
        const inv = try collectFiles(gpa, fd, a, .{ .pattern = "WalletService", .mode = .files, .fixed = true, .invert = true });
        try std.testing.expectEqual(@as(usize, 5), inv.len);
        try std.testing.expect(hasSuffix(inv, "b.txt") and hasSuffix(inv, "d.txt") and hasSuffix(inv, "e.txt"));
        try std.testing.expect(hasSuffix(inv, "f.txt") and hasSuffix(inv, "g.txt"));
        try std.testing.expect(!hasSuffix(inv, "a.txt") and !hasSuffix(inv, "c.txt"));
    }
    // `-v` emit streams the complementary lines in `pathLess` order: a/c hold
    // only matching lines (nothing emitted); the rest emit whole.
    {
        const lr = try collectLines(gpa, fd, a, .{ .pattern = "WalletService", .mode = .lines, .fixed = true, .invert = true });
        try std.testing.expect(lr.matched);
        const want = try std.fmt.allocPrint(a, "{s}/b.txt:nothing\n{s}/d.txt:walletservice lower\n{s}/e.txt:run runner\n{s}/e.txt:rerun run\n{s}/f.txt:runner only\n{s}/g.txt:\xc3\xa9run here\n", .{ root, root, root, root, root, root });
        try std.testing.expectEqualStrings(want, lr.out);
    }
    // `-c -v` is the corpus-wide complement Lever A serves warm over the wire:
    // TOTAL_CORPUS_LINES (8) − Σ matchCount (2) = 6 non-matching lines. (The CLI
    // routes `-c` cold for rg's per-file semantics; embedders reach this path.)
    {
        const total = try collectCount(gpa, fd, .{ .pattern = "WalletService", .mode = .count, .fixed = true });
        try std.testing.expectEqual(@as(u64, 2), total);
        const inv = try collectCount(gpa, fd, .{ .pattern = "WalletService", .mode = .count, .fixed = true, .invert = true });
        try std.testing.expectEqual(@as(u64, 6), inv);
    }
    // `-v -m1` caps the inverted emit at one row per file (e.txt drops its 2nd).
    {
        const capped = try collectLines(gpa, fd, a, .{ .pattern = "WalletService", .mode = .lines, .fixed = true, .invert = true, .max_count = 1 });
        try std.testing.expect(capped.matched);
        const want = try std.fmt.allocPrint(a, "{s}/b.txt:nothing\n{s}/d.txt:walletservice lower\n{s}/e.txt:run runner\n{s}/f.txt:runner only\n{s}/g.txt:\xc3\xa9run here\n", .{ root, root, root, root, root });
        try std.testing.expectEqualStrings(want, capped.out);
    }

    // PING → PONG.
    try protocol.sendFrame(gpa, fd, .ping, "");
    {
        var pong = try protocol.recvFrame(gpa, fd);
        defer pong.deinit();
        try std.testing.expectEqual(protocol.Opcode.pong, pong.op);
    }

    // SHUTDOWN stops the accept loop; the daemon thread joins via `defer`.
    try protocol.sendFrame(gpa, fd, .shutdown, "");
}

/// Wait until `fd` is readable, bounded — a regression back to the serial
/// accept loop must fail this test with a clear error, never hang the suite.
fn expectReadable(fd: std.posix.fd_t) !void {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfd, 10_000) catch 0;
    if (n == 0 or (pfd[0].revents & std.posix.POLL.IN) == 0) return error.SecondClientStarved;
}

fn handshake(gpa: std.mem.Allocator, fd: std.posix.fd_t) !void {
    try protocol.sendFrame(gpa, fd, .hello, &.{protocol.protocol_version});
    try expectReadable(fd);
    var ready = try protocol.recvFrame(gpa, fd);
    defer ready.deinit();
    try std.testing.expectEqual(protocol.Opcode.ready, ready.op);
}

test "serve: an idle persistent client does not starve a second connection" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_mux_{x}", .{@intFromPtr(&threaded)});
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/a.txt", .{root}), .data = "needle\n" });

    const socket = try std.fmt.allocPrint(a, "{s}/gistd.sock", .{root});
    const roots = try a.dupe([]const u8, &.{root});

    const t = try std.Thread.spawn(.{}, daemonMain, .{DaemonArgs{ .gpa = gpa, .io = io, .roots = roots, .socket = socket }});
    defer t.join();

    // Client A: handshake, then go idle WITHOUT disconnecting — the exact shape
    // of a long-lived warm `Session` an agent batch holds open for minutes.
    const a_stream = try dial(io, socket);
    defer a_stream.close(io);
    try handshake(gpa, a_stream.socket.handle);

    // Client B must connect, handshake, and get an answer while A idles. Under
    // the old serial accept loop B sat in the listen backlog until A hung up.
    const b_stream = try dial(io, socket);
    defer b_stream.close(io);
    const b_fd = b_stream.socket.handle;
    try handshake(gpa, b_fd);
    const files = try collectFiles(gpa, b_fd, a, .{ .pattern = "needle", .mode = .files, .fixed = true });
    try std.testing.expectEqual(@as(usize, 1), files.len);

    // Client A is still live after B's round-trip: PING → PONG.
    try protocol.sendFrame(gpa, a_stream.socket.handle, .ping, "");
    try expectReadable(a_stream.socket.handle);
    var pong = try protocol.recvFrame(gpa, a_stream.socket.handle);
    defer pong.deinit();
    try std.testing.expectEqual(protocol.Opcode.pong, pong.op);

    try protocol.sendFrame(gpa, b_fd, .shutdown, "");
}
