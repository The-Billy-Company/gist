//! gist resident client — the CLI's warm fast path (ADR-352 rung 2.5).
//!
//! `attempt` is the thin, fail-open bridge between the bare `gist <pattern>`
//! front door and the resident daemon: it classifies the argv, and only when the
//! request is one the warm path can answer *byte-identically to cold* does it
//! dial the socket, run the query, and emit the result in the exact shape the
//! cold engine would. Anything else — an ineligible argv, no daemon listening, a
//! `decline`, any wire hiccup — returns `.cold`, and the caller runs the
//! certified cold path unchanged. The daemon never becomes a new source of truth
//! or a new failure mode; it is a pure accelerator that can always be skipped.
//!
//! Parity scope: `-l`/`--files-with-matches` (the sorted path list) and the
//! default `lines` search (bare `gist <pattern> [-n]`, whose `path:[line:]text`
//! bytes the daemon pre-renders through the cold Emitter itself) are routed
//! warm. Per-file bytes and the exit code are identical to cold; the FILE
//! emission order is the deterministic `pathLess` canonicalization of cold's
//! parallel worker-discovery order — the same convention warm `-l` has always
//! used, and the equivalence the rgsuite oracle certifies (`sort_lines(gist)
//! == sort_lines(rg)`). `-c` (per-file `path:count`) and every richer shape
//! stay cold: the daemon speaks `count` on the wire as a corpus-wide total for
//! embedders, but the CLI never claims rg's per-file `-c` layout from it.
//!
//! Two environment guards keep the warm answer inside its parity envelope:
//!
//!   * **TTY stdout → cold.** An interactive cold run adds ANSI color and the
//!     16 KiB long-line cap (`--color auto` + the TTY `max_cols` default); the
//!     daemon renders the PIPED frame only. Agents and pipes — the entire warm
//!     workload — are unaffected.
//!   * **Readable stdin → cold.** A rootless query with data on stdin is a
//!     STREAM search in the cold engine; the daemon's tree corpus can never
//!     answer it. Same fd-type rules as cold (`run.readableStdin`), checked
//!     only after a daemon connection exists so the common no-daemon path
//!     never pays the FIFO poll.

const std = @import("std");
const request = @import("../../../../runtime/session/request.zig");
const protocol = @import("../../../../runtime/session/protocol.zig");
const corpus = @import("../../../../runtime/corpus/corpus.zig");
const run = @import("../../search/engine/serial.zig");
const net = std.Io.net;

/// Best-effort detached daemon auto-spawn: when an eligible query finds no
/// daemon, `maybeSpawn` forks one so the *next* query lands warm (`spawn.zig`).
pub const spawn = @import("spawn.zig");

/// Soft deadline (ms) for every warm-client wait after connect. A wedged daemon
/// (accepted but never READY, stuck reconcile, half-closed peer) must not park
/// an agent shell forever — timeout → `.cold` and the certified path runs.
/// Keep short: cold is always correct and typically finishes well under this
/// budget for eligible queries. Exposed for the wedge regression test.
pub const client_io_timeout_ms: i32 = 2_000;

/// The outcome of a warm attempt. `.served` means the result was fully emitted
/// to stdout with the given exit code (0 = matched, 1 = no match — rg's codes);
/// `.cold` means the caller must run the cold engine (nothing was emitted).
pub const Outcome = union(enum) {
    served: u8,
    cold,
};

/// Wait until `fd` is readable or the client deadline elapses. `false` means
/// timed out / poll error — caller falls through to cold. Prefer `poll` over
/// `SO_RCVTIMEO`: the latter's `timeval` ABI is easy to get wrong across libc
/// cuts, and a silent setsockopt failure used to leave the CLI blocked forever.
fn waitReadable(fd: std.posix.fd_t) bool {
    var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const n = std.posix.poll(&pfd, client_io_timeout_ms) catch return false;
    // Only IN means "bytes ready". HUP/ERR alone must not look like a READY
    // frame — that would skip the deadline and race a closing peer to cold.
    return n > 0 and (pfd[0].revents & std.posix.POLL.IN) != 0;
}

/// Receive one frame, but never block longer than `client_io_timeout_ms`.
fn recvFrameDeadline(gpa: std.mem.Allocator, fd: std.posix.fd_t) !protocol.Frame {
    if (!waitReadable(fd)) return error.TimedOut;
    return protocol.recvFrame(gpa, fd);
}

/// Try to answer `argv` warm. Never errors: any failure is `.cold`.
pub fn attempt(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, socket_path: []const u8) Outcome {
    const req = request.classify(argv) catch return .cold;
    // The wire count is a corpus-wide total; rg's `-c` is per-file — cold owns it.
    if (req.mode == .count) return .cold;
    // Cold's interactive presentation (color, TTY long-line cap) is out of the
    // daemon's piped-frame envelope — the certified path owns the terminal.
    // Same detection cold's `--color auto` resolution uses (run.zig).
    if (std.Io.File.stdout().isTty(io) catch false) return .cold;

    const ua = net.UnixAddress.init(socket_path) catch return .cold;
    const stream = ua.connect(io) catch return .cold; // no daemon → cold
    defer stream.close(io);
    const fd = stream.socket.handle;

    // A readable stdin makes this a STREAM search cold — the tree daemon must
    // decline. Checked after the dial so a daemonless query never pays the
    // FIFO poll (`readableStdin` may wait up to its short poll window).
    if (run.readableStdin()) return .cold;

    return exchange(gpa, fd, req) catch .cold;
}

/// One request/response over an open connection: handshake, send the query, and
/// emit the answer — a `result(files)` frame becomes the sorted path list; a
/// chunk-streamed `lines` answer buffers every `chunk` frame and emits on the
/// terminal `result(lines)` frame (buffer-then-emit keeps the fallback atomic:
/// nothing reaches stdout unless the whole warm answer arrived, so a mid-stream
/// wire failure still degrades to a clean cold run with no duplicated output).
/// A `decline`/`err` frame (or any wire error / deadline) propagates so
/// `attempt` degrades to cold.
fn exchange(gpa: std.mem.Allocator, fd: std.posix.fd_t, req: request.Request) !Outcome {
    // Handshake: HELLO → READY. A daemon speaking another protocol version is
    // not one we can trust to frame-match, so bail to cold.
    try protocol.sendFrame(gpa, fd, .hello, &.{protocol.protocol_version});
    {
        var ready = try recvFrameDeadline(gpa, fd);
        defer ready.deinit();
        if (ready.op != .ready) return .cold;
        const r = protocol.decodeReady(ready.payload()) catch return .cold;
        if (r.proto != protocol.protocol_version) return .cold;
    }

    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeQuery(&qbuf, gpa, req);
    if (!protocol.writeAll(fd, qbuf.items)) return .cold;

    var lines_out: std.ArrayList(u8) = .empty;
    defer lines_out.deinit(gpa);
    while (true) {
        var resp = try recvFrameDeadline(gpa, fd);
        defer resp.deinit();
        switch (resp.op) {
            // A `lines` answer streams as chunks; accumulate until the terminal
            // result frame. (An old v1 daemon never emits `chunk` — it declines
            // the unknown mode byte first — so this arm is dead against it.)
            .chunk => try lines_out.appendSlice(gpa, resp.payload()),
            .result => {
                const view = protocol.decodeResult(resp.payload()) catch return .cold;
                return switch (view) {
                    // Chunks before a files/count result are a protocol violation.
                    .files => |files_iter| if (lines_out.items.len > 0) .cold else emitFiles(gpa, files_iter),
                    .lines => |matched| emitRaw(lines_out.items, matched),
                    .count => .cold, // CLI never emits count warm (see file header)
                };
            },
            else => return .cold, // decline / err → cold
        }
    }
}

/// Emit the matched paths one per line and return rg's exit code (0 matched /
/// 1 none). The set AND order are identical to cold `-l` (the daemon sorts with
/// the same separator-aware `pathLess` cold's file sort applies). One batched
/// write mirrors the cold path's buffered emit.
fn emitFiles(gpa: std.mem.Allocator, files_iter: protocol.FileIter) Outcome {
    var it = files_iter;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var any = false;
    while (it.next() catch return .cold) |path| {
        any = true;
        out.appendSlice(gpa, path) catch return .cold;
        out.append(gpa, '\n') catch return .cold;
    }
    if (out.items.len > 0) _ = corpus.writeStdout(out.items);
    return .{ .served = if (any) 0 else 1 };
}

/// Emit a fully-assembled pre-rendered `lines` answer verbatim (the daemon
/// already produced cold's exact bytes) and return rg's exit code.
fn emitRaw(bytes: []const u8, matched: bool) Outcome {
    if (bytes.len > 0) _ = corpus.writeStdout(bytes);
    return .{ .served = if (matched) 0 else 1 };
}
