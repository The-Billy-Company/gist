//! Warm-client fail-open deadlines — a wedged daemon must not hang the CLI.
//!
//! The cold path is always correct; the warm path is a pure accelerator. If a
//! peer accepts the connection but never speaks READY, `attempt` must return
//! `.cold` within `client_io_timeout_ms` rather than parking forever on recv.

const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
const image = @import("../../conduit/image.zig");
const protocol = @import("../../conduit/protocol/protocol.zig");
const vigil = @import("../../conduit/vigil.zig");
const fault = @import("irregex").fault;
const rendezvous = @import("../../conduit/rendezvous.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const WedgedArgs = struct {
    io: std.Io,
    socket: []const u8,
    ready: []const u8,
};

/// Listen, publish a ready marker, accept one connection, never write and never
/// close until the peer gives up (the client's poll deadline). Reading even one
/// byte of the client's HELLO and returning would close the socket and look
/// like an instant cold miss instead of a deadline wait.
fn wedgedMain(args: WedgedArgs) void {
    const ua = rendezvous.address(args.socket) catch return;
    var server = ua.listen(args.io, .{}) catch return;
    defer server.deinit(args.io);

    Dir.cwd().writeFile(args.io, .{ .sub_path = args.ready, .data = "1" }) catch return;

    var pfd = [_]std.posix.pollfd{.{
        .fd = server.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&pfd, 10_000) catch return;
    if (n == 0) return;

    const stream = server.accept(args.io) catch return;
    defer stream.close(args.io);

    // Hold the connection open in silence until the client closes after timeout.
    var buf: [64]u8 = undefined;
    while (true) {
        const got = std.posix.system.read(stream.socket.handle, &buf, buf.len);
        if (got <= 0) break;
        // Discard client bytes (HELLO / query) — never reply.
    }
}

test "client: wedged daemon times out to cold" {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try std.fmt.allocPrint(a, "/tmp/gist_client_wedge_{x}", .{@intFromPtr(&threaded)});
    fault.spare("clear leftover fixture", Dir.cwd().deleteTree(io, root));
    try Dir.cwd().createDirPath(io, root);
    defer fault.spare("remove fixture", Dir.cwd().deleteTree(io, root));

    const socket = try std.fmt.allocPrint(a, "{s}/wedged.sock", .{root});
    const ready = try std.fmt.allocPrint(a, "{s}/ready", .{root});

    const t = try std.Thread.spawn(.{}, wedgedMain, .{WedgedArgs{
        .io = io,
        .socket = socket,
        .ready = ready,
    }});
    defer t.join();

    for (0..400) |_| {
        if (Dir.cwd().access(io, ready, .{}) catch null) |_| break;
        try io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .real);
    } else return error.WedgedNeverReady;

    // `attemptWithin` routes on the process's real stdin (rg's `is_readable_stdin`):
    // a readable stdin *stream* is a cold-only STREAM search, so it short-circuits
    // to `.cold` before the wedged exchange this test targets. Under
    // `zig build test --listen=-` fd 0 is the runner's own IPC pipe (a FIFO —
    // correctly classified a stream), which would make the assertion below pass
    // vacuously. Point fd 0 at /dev/null (a char device, never a stream: the
    // ordinary warm scenario) so the poll/recv deadline is genuinely exercised,
    // then restore the runner's channel — the saved read end keeps the pipe (and
    // any buffered command) alive across the swap.
    const saved_stdin = std.c.dup(0);
    defer if (saved_stdin >= 0) {
        _ = std.c.dup2(saved_stdin, 0);
        _ = std.c.close(saved_stdin);
    };
    if (std.posix.openat(std.posix.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY }, 0) catch null) |nul| {
        _ = std.c.dup2(nul, 0);
        _ = std.c.close(nul);
    }

    // Exercise the same poll/recv path with a short deadline. The server keeps
    // the socket open until the client closes, so returning `.cold` itself
    // proves the deadline fired; an upper wall-clock bound only tests scheduler
    // load and was observed to flake despite correct client behavior.
    const test_timeout_ms: i32 = 20;
    const outcome = client.test_api.attemptWithin(gpa, io, &.{ "needle", "-l" }, socket, test_timeout_ms);

    try std.testing.expect(outcome == .cold);
}

// ── skew: who retires whom ──────────────────────────────────────────────────
//
// A daemon on another protocol version answers correctly-framed nonsense, so
// the client runs cold. The question these tests pin is what it does on the way
// out — because "decline and say nothing" would strand the warm tier (the idle
// TTL wants ten CONTINUOUS minutes of quiet, which this repo never has), while
// "always retire" would let two live builds kill each other's daemons all
// afternoon. Only the strictly newer peer writes the frame, and the version is
// the one thing here that genuinely counts up.
//
// BUILD skew has no such order (a stamp is an mtime, and Zig's install
// preserves the cache artifact's, so it can move backwards between two cached
// builds). Self-retirement covers it whenever the daemon's own executable was
// rewritten — proved end to end in `serve/serve_test.zig` — but NOT when that
// file can never be rewritten, which is exactly a content-addressed build
// artifact. So build skew gets a tiebreak (`image.hosts`) whose only required
// property is that both sides compute the same winner; the tests below pin
// convergence and abstention rather than any reading of "newer".

/// A connected local pair and the `Io` both ends speak through — the cheapest
/// stand-in for "a daemon is on the other end": no listener, no filesystem,
/// nothing to race.
///
/// `vigil.Pair` rather than a bare `socketpair(2)` so these three tests exercise
/// the same channel the daemon's bell does, and so they still run on a platform
/// that has no such call. The caller owns `threaded` (an `Io` holds a pointer
/// into it, so it may not move) and closes via `deinit`.
const Duplex = struct {
    io: std.Io,
    channel: vigil.Pair,

    fn open(threaded: *std.Io.Threaded) !Duplex {
        const io = threaded.io();
        return .{ .io = io, .channel = vigil.Pair.open(io) catch return error.SkipZigTest };
    }

    fn deinit(self: *const Duplex) void {
        self.channel.close(self.io);
    }

    /// The end a client writes its retirement frame to.
    fn near(self: *const Duplex) std.posix.fd_t {
        return self.channel.clapper;
    }

    /// Whatever landed on the peer end, without blocking indefinitely. Empty when
    /// nothing was written — the assertion the anti-thrash tests need.
    fn peerBytes(self: *const Duplex, buf: []u8) []u8 {
        if (!vigil.readable(self.channel.ear, 200)) return buf[0..0];
        return self.channel.read(self.io, buf);
    }
};

test "skew: the newer peer retires the resident daemon it has obsoleted" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const pair = try Duplex.open(&threaded);
    defer pair.deinit();

    client.test_api.retireOn(std.testing.allocator, pair.io, pair.near(), true);

    var buf: [64]u8 = undefined;
    const got = pair.peerBytes(&buf);
    // `[u32 len][u8 opcode]` — one shutdown frame, nothing more.
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, got[0..4], .little));
    try std.testing.expectEqual(protocol.Opcode.shutdown, @as(protocol.Opcode, @enumFromInt(got[4])));
}

test "skew: a peer that is not strictly newer leaves the daemon alone" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const pair = try Duplex.open(&threaded);
    defer pair.deinit();

    client.test_api.retireOn(std.testing.allocator, pair.io, pair.near(), false);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pair.peerBytes(&buf).len);
}

test "skew: the version byte is read before the layout that may not parse" {
    // A pre-v9 READY has a 21-byte header, so `decodeReady` cannot speak for it
    // — yet its version byte is in the same place it has always been, and that
    // is what makes an old daemon retirable rather than merely declined. Read
    // it off the wire directly; every past and future version agrees on byte 0.
    const v8 = [_]u8{8} ++ [_]u8{0} ** 20;
    try std.testing.expectEqual(@as(?u8, 8), client.test_api.peerProtocolOf(&v8));
    try std.testing.expect(protocol.decodeReady(&v8) catch null == null);
    try std.testing.expect(8 < protocol.protocol_version); // hence: superseded

    // A peer that says nothing at all is not one we get to judge.
    try std.testing.expectEqual(@as(?u8, null), client.test_api.peerProtocolOf(""));
}

test "skew: the build tiebreak converges instead of oscillating" {
    const t = std.testing;
    // The property the whole rule rests on: for any two DIFFERENT stamps exactly
    // one side hosts, so both peers pick the same winner and no pair can take
    // turns evicting each other. Asserted over the pair, not over one call, and
    // over the boundary values a u64 mtime can actually reach.
    const stamps = [_]u64{ 1, 2, 41, 1785212232, 1785218598, std.math.maxInt(u64) };
    for (stamps) |a| for (stamps) |b| {
        if (a == b) {
            // Same build: nobody hosts, because nobody is superseded — the
            // agreeing path never reaches the tiebreak at all.
            try t.expect(!image.hosts(a, b));
            try t.expect(image.agrees(a, b));
            continue;
        }
        try t.expect(!image.agrees(a, b)); // skew, so the tiebreak is consulted
        try t.expect(image.hosts(a, b) != image.hosts(b, a)); // exactly one wins
    };
}

test "skew: a side that cannot identify itself never evicts one that can" {
    const t = std.testing;
    // `unknown` means "this check could not be made", and the fail-open rule in
    // `image.zig` is that such a side abstains. Were it to win the tiebreak, a
    // target with no self-exe path would evict every healthy daemon it dialed.
    try t.expect(!image.hosts(image.unknown, 7));
    try t.expect(!image.hosts(7, image.unknown));
    try t.expect(!image.hosts(image.unknown, image.unknown));
    // And abstention is agreement, so the tiebreak is not even reached.
    try t.expect(image.agrees(image.unknown, 7));
}

test "skew: an immortal orphan daemon loses the rendezvous to a fresh install" {
    const t = std.testing;
    // The measured failure this rule exists for, as the two stamps it was
    // observed with: an orphan daemon exec'd from a content-addressed build
    // artifact (whose bytes can never be rewritten, so it never self-retires)
    // against the freshly installed binary every client is actually running.
    const orphan: u64 = 1785212232; // .cache/.../o/<hash>/gist
    const installed: u64 = 1785218598; // zig-out/bin/gist
    try t.expect(!image.agrees(installed, orphan)); // the client declines...
    try t.expect(image.hosts(installed, orphan)); // ...and hands the socket over

    // A retirement is one shutdown frame and nothing else, so the daemon stops
    // and the next eligible query auto-spawns from what is on disk now.
    var threaded = std.Io.Threaded.init(t.allocator, .{});
    defer threaded.deinit();
    const pair = try Duplex.open(&threaded);
    defer pair.deinit();
    client.test_api.retireOn(t.allocator, pair.io, pair.near(), image.hosts(installed, orphan));
    var buf: [64]u8 = undefined;
    const got = pair.peerBytes(&buf);
    try t.expectEqual(@as(usize, 5), got.len);
    try t.expectEqual(protocol.Opcode.shutdown, @as(protocol.Opcode, @enumFromInt(got[4])));
}
