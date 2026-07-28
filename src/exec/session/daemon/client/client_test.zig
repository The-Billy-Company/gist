//! Warm-client fail-open deadlines — a wedged daemon must not hang the CLI.
//!
//! The cold path is always correct; the warm path is a pure accelerator. If a
//! peer accepts the connection but never speaks READY, `attempt` must return
//! `.cold` within `client_io_timeout_ms` rather than parking forever on recv.

const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
const protocol = @import("../../conduit/protocol/protocol.zig");
const fault = @import("../../../../fault.zig");
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
    const ua = net.UnixAddress.init(args.socket) catch return;
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
// builds). The client only declines; the daemon stands itself down when its own
// executable is replaced — proved end to end in `serve/serve_test.zig`.

/// A connected local pair, the cheapest stand-in for "a daemon is on the other
/// end" — no listener, no filesystem, nothing to race.
fn duplex() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds) != 0) return error.SkipZigTest;
    return fds;
}

/// Read whatever landed on the peer end without blocking. Returns an empty
/// slice when nothing was written — the assertion the anti-thrash tests need.
fn peerBytes(fd: std.posix.fd_t, buf: []u8) []u8 {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfd, 200) catch return buf[0..0];
    if (n == 0 or (pfd[0].revents & std.posix.POLL.IN) == 0) return buf[0..0];
    const got = std.c.read(fd, buf.ptr, buf.len);
    return if (got > 0) buf[0..@intCast(got)] else buf[0..0];
}

test "skew: the newer peer retires the resident daemon it has obsoleted" {
    const pair = try duplex();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);

    client.test_api.retireOn(std.testing.allocator, pair[0], true);

    var buf: [64]u8 = undefined;
    const got = peerBytes(pair[1], &buf);
    // `[u32 len][u8 opcode]` — one shutdown frame, nothing more.
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, got[0..4], .little));
    try std.testing.expectEqual(protocol.Opcode.shutdown, @as(protocol.Opcode, @enumFromInt(got[4])));
}

test "skew: a peer that is not strictly newer leaves the daemon alone" {
    const pair = try duplex();
    defer _ = std.c.close(pair[0]);
    defer _ = std.c.close(pair[1]);

    client.test_api.retireOn(std.testing.allocator, pair[0], false);

    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), peerBytes(pair[1], &buf).len);
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
