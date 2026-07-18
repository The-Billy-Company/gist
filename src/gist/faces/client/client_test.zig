//! Warm-client fail-open deadlines — a wedged daemon must not hang the CLI.
//!
//! The cold path is always correct; the warm path is a pure accelerator. If a
//! peer accepts the connection but never speaks READY, `attempt` must return
//! `.cold` within `client_io_timeout_ms` rather than parking forever on recv.

const std = @import("std");
const builtin = @import("builtin");
const client = @import("client.zig");
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
    Dir.cwd().deleteTree(io, root) catch {};
    try Dir.cwd().createDirPath(io, root);
    defer Dir.cwd().deleteTree(io, root) catch {};

    const socket = try std.fmt.allocPrint(a, "{s}/wedged.sock", .{root});
    const ready = try std.fmt.allocPrint(a, "{s}/ready", .{root});

    const t = try std.Thread.spawn(.{}, wedgedMain, .{WedgedArgs{
        .io = io,
        .socket = socket,
        .ready = ready,
    }});
    defer t.join();

    var i: usize = 0;
    while (i < 400) : (i += 1) {
        if (Dir.cwd().access(io, ready, .{})) |_| break else |_| {}
        try io.sleep(.fromNanoseconds(5 * std.time.ns_per_ms), .real);
    } else return error.WedgedNeverReady;

    const t0 = std.Io.Clock.now(.real, io).nanoseconds;
    const outcome = client.attempt(gpa, io, &.{ "needle", "-l" }, socket);
    const delta_ns = std.Io.Clock.now(.real, io).nanoseconds - t0;
    const elapsed_ms: i64 = @divTrunc(@as(i64, @truncate(delta_ns)), std.time.ns_per_ms);

    try std.testing.expect(outcome == .cold);
    try std.testing.expect(elapsed_ms >= client.client_io_timeout_ms - 500);
    try std.testing.expect(elapsed_ms < client.client_io_timeout_ms + 2_500);
}
