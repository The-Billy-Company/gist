//! gist resident daemon — `gist serve` (ADR-352 rung 2.5).
//!
//! Holds one `ResidentSession` warm behind a Unix-domain socket so a persistent
//! client answers an eligible query without re-paying the cold subprocess's
//! process + index-mmap + candidate-read startup on every call — the whole
//! reason the warm certificate can post a geomean the cold path never could. It
//! is the transport shell only; the correctness (freshness, parity) lives in the
//! session (`src/session/`).
//!
//! Lifecycle: grab the single-instance lock, build the session, arm the
//! freshness watcher, bind the socket (unlinking a stale one), then a
//! **poll-multiplexed** accept loop — one `poll` set over the listener plus
//! every connected client, serving one frame per readable client per wakeup.
//! Queries still execute one at a time on this single thread (the session's
//! mutation overlay stays single-threaded without a per-connection thread to
//! join on teardown; the concurrency-safety of the engine itself is proven
//! directly in `resident` under `std.Thread`, not through the socket) — but an
//! **idle persistent client no longer starves new connections**. Under the old
//! serial loop, one agent's long-lived warm `Session` parked every other
//! client in the listen backlog until it disconnected; ~10 coworker agents
//! share this daemon, so that turned a microsecond warm probe into a
//! minutes-long block for everyone else. Every failure is fail-open toward
//! cold: a declined/again-errored query costs the client a fallback
//! subprocess, never a wrong answer.
//!
//! Two self-management properties make the daemon safe to auto-spawn (the cold
//! CLI forks one on the first eligible miss, so ~10 coworker CLIs may each race
//! to start one):
//!
//!   * **Single-instance** — before touching the socket, `run` takes an advisory
//!     `flock` on `<socket>.lock`. Exactly one racer wins; the losers return at
//!     once *without* unlinking the winner's live socket. The lock is taken
//!     first precisely so a loser never runs the stale-socket cleanup below.
//!   * **Idle-TTL self-exit** — the accept loop `poll`s with a timeout; if no
//!     client dials within `idle_ttl_ms` the daemon exits so an abandoned
//!     session doesn't pin RAM forever. The next query just re-spawns it.
//!
//! An explicit `shutdown` frame also stops the loop; a client merely
//! disconnecting just frees the daemon for the next one.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../../../../exec/session/resident.zig");
const protocol = @import("../../../../exec/session/protocol.zig");
const watch = @import("../../../../exec/session/watch.zig");
const corpus = @import("../../../../../corpus/tree/corpus.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

extern "c" fn flock(fd: std.posix.fd_t, operation: c_int) c_int;
extern "c" fn close(fd: std.posix.fd_t) c_int;

/// What one served frame tells the multiplexed loop to do with its connection:
/// keep it registered, drop it (closed/errored peer), or stop the daemon.
const After = enum { keep, drop, stop };

/// One registered client connection. `gen` is the per-connection session
/// generation the READY frame reports (monotonic across accepts); `caps` is the
/// transport capabilities it advertised in its HELLO (0 until then / for a peer
/// that sent no caps byte — that peer stays on the classic `chunk` path).
const Client = struct { stream: net.Stream, gen: u64, caps: u8 = 0 };

/// Registered-connection cap. Beyond it a new connection is closed at accept
/// and the client falls back to the certified cold path — fail-open, never a
/// hang. Generous: the realistic local population is ~10 coworker agents.
const max_clients: usize = 64;

/// Operator-facing lifecycle line on stderr. Silenced under `zig build test`:
/// the daemon is spawned in-process by `serve_test.zig`, and any stderr from a
/// passing unit-test binary makes the build runner dump the step tree with a
/// spurious "failed command:" banner — a green run must read green.
fn note(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt, args);
}

/// Idle window with zero connections before a warm daemon self-exits: the
/// resident index/corpus stops earning its RAM once nobody is querying, and a
/// fresh query re-spawns one in the background anyway (see `client/spawn.zig`).
const idle_ttl_ms: i32 = 10 * 60 * 1000;

/// Serve `roots` warm on `socket_path` until it goes idle, a client sends
/// `shutdown`, or the listener dies. Owns the session + socket for its whole
/// lifetime. Returns immediately (no-op) if another daemon already holds the
/// single-instance lock, so it is safe to auto-spawn or run twice.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, socket_path: []const u8) !void {
    // Singleton FIRST — before any socket mutation — so a losing racer never
    // unlinks the winner's live socket during the stale-socket cleanup below.
    const lock_fd = acquireSingleton(io, socket_path) orelse {
        note("gist serve: another daemon already warm on {s}\n", .{socket_path});
        return;
    };
    defer _ = close(lock_fd); // closing releases the advisory flock

    var session = try ResidentSession.init(gpa, io, roots);
    defer session.deinit();
    session.daemon_gen = @bitCast(@as(i64, @truncate(std.Io.Clock.now(.real, io).nanoseconds)));

    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    watcher.start();
    defer watcher.stop();
    note("gist serve: watcher {s}, exact dirty log {s}\n", .{
        if (session.seqlock.active) "armed" else "unavailable (reconcile-always)",
        if (session.dirty_log.exact) "on" else "off",
    });

    if (std.fs.path.dirnamePosix(socket_path)) |dir| Dir.cwd().createDirPath(io, dir) catch {};
    Dir.cwd().deleteFile(io, socket_path) catch {}; // clear a stale socket from a crashed daemon
    const ua = try net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);
    defer Dir.cwd().deleteFile(io, socket_path) catch {};

    note("gist serve: warm on {s} ({d} roots)\n", .{ socket_path, roots.len });

    // Poll-multiplexed loop: slot 0 is the listener, slots 1.. mirror `clients`.
    // One frame is served per readable client per wakeup, so a long-lived idle
    // `Session` never blocks a new connection behind it in the listen backlog.
    var clients: std.ArrayList(Client) = .empty;
    defer {
        for (clients.items) |c| c.stream.close(io);
        clients.deinit(gpa);
    }
    var pfds: std.ArrayList(std.posix.pollfd) = .empty;
    defer pfds.deinit(gpa);

    var session_gen: u64 = 0;
    var last_scoped: u64 = 0;
    var last_full: u64 = 0;
    serve_loop: while (true) {
        pfds.clearRetainingCapacity();
        try pfds.append(gpa, .{ .fd = server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 });
        for (clients.items) |c|
            try pfds.append(gpa, .{ .fd = c.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 });

        // Idle-TTL only applies to a daemon with zero clients: a connected
        // (even if quiet) client pins the warm session — dropping it under a
        // client's feet would cost that client a reconnect per query.
        const timeout: i32 = if (clients.items.len == 0) idle_ttl_ms else -1;
        const ready = std.posix.poll(pfds.items, timeout) catch break;
        if (ready == 0) break; // idle with no clients → self-exit

        // Serve every readable client (one frame each). Drops are only MARKED
        // during the sweep — `clients` must stay index-aligned with the `pfds`
        // snapshot until it ends, or a removal would misroute the next
        // client's readiness onto the wrong fd (and a blocking `recvFrame` on
        // a non-readable fd is exactly the hang this loop exists to prevent).
        var dropped = false;
        for (clients.items, pfds.items[1..]) |*c, pfd| {
            if (pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) continue;
            const after = serveFrame(&session, gpa, c);
            if (session.scoped_reconciles != last_scoped or session.full_reconciles != last_full) {
                last_scoped = session.scoped_reconciles;
                last_full = session.full_reconciles;
                note("gist serve: reconciled (scoped={d} full={d})\n", .{ last_scoped, last_full });
            }
            switch (after) {
                .keep => {},
                .drop => {
                    c.stream.close(io);
                    c.gen = 0; // tombstone; swept below
                    dropped = true;
                },
                .stop => break :serve_loop,
            }
        }
        if (dropped) {
            var i: usize = 0;
            while (i < clients.items.len) {
                if (clients.items[i].gen == 0) {
                    _ = clients.swapRemove(i); // order is not load-bearing
                } else i += 1;
            }
        }

        if (pfds.items[0].revents & std.posix.POLL.IN != 0) {
            const stream = server.accept(io) catch break;
            if (clients.items.len >= max_clients) {
                stream.close(io); // over cap → the client answers cold
            } else {
                session_gen +%= 1;
                try clients.append(gpa, .{ .stream = stream, .gen = session_gen });
            }
        }
    }
}

/// Take the advisory single-instance lock on `<socket_path>.lock`. Returns the
/// held fd (keep it open for the daemon's lifetime — closing releases the lock),
/// or `null` if another daemon owns it or the lock file can't be opened (in
/// which case the caller declines to start rather than fight over the socket).
fn acquireSingleton(io: std.Io, socket_path: []const u8) ?std.posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&buf, "{s}.lock", .{socket_path}) catch return null;
    if (std.fs.path.dirnamePosix(lock_path)) |dir| Dir.cwd().createDirPath(io, dir) catch {};
    const fd = std.posix.openat(std.posix.AT.FDCWD, lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch return null;
    if (flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        _ = close(fd); // held by a live daemon → this racer stands down
        return null;
    }
    return fd;
}

/// Serve ONE frame from a readable client. Called only after `poll` reported
/// the fd readable, so the blocking `recvFrame` returns promptly (a whole
/// small request frame arrives in one segment on a local Unix socket; a
/// half-written frame from a dying peer ends as `ConnClosed` → `.drop`).
/// Returns `.stop` only on an explicit `shutdown` opcode.
fn serveFrame(session: *ResidentSession, gpa: std.mem.Allocator, client: *Client) After {
    const fd = client.stream.socket.handle;
    var frame = protocol.recvFrame(gpa, fd) catch return .drop; // closed/oversized/bad → drop peer
    defer frame.deinit();
    switch (frame.op) {
        // HELLO carries an optional caps byte after the version — latch it for
        // this connection so its queries can use fd-transport (`status` is a
        // re-handshake that never advertises, so it leaves caps untouched).
        .hello => {
            const p = frame.payload();
            client.caps = if (p.len >= 2) p[1] else 0;
            sendReady(session, gpa, fd, client.gen) catch return .drop;
        },
        .status => sendReady(session, gpa, fd, client.gen) catch return .drop,
        .ping => protocol.sendFrame(gpa, fd, .pong, "") catch return .drop,
        .query => handleQuery(session, gpa, fd, frame.payload(), client.caps, false) catch return .drop,
        // The scoped query (`query_ext`) — same dispatch, decoded with a roots
        // trailer. An old daemon never reaches here (the opcode is unknown to
        // it → `.decline` below → client cold).
        .query_ext => handleQuery(session, gpa, fd, frame.payload(), client.caps, true) catch return .drop,
        .shutdown => return .stop,
        // Anything server→client, or an unknown verb, is not a request: refuse
        // it as decline so a confused client falls back cold rather than hangs.
        else => protocol.sendFrame(gpa, fd, .decline, "") catch return .drop,
    }
    return .keep;
}

/// Answer a `hello`/`status` frame with the READY triple (daemon gen, session
/// gen, index gen) the client's handshake validates against its own protocol.
fn sendReady(session: *ResidentSession, gpa: std.mem.Allocator, fd: std.posix.fd_t, session_gen: u64) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try protocol.encodeReady(&buf, gpa, session.daemon_gen, session_gen, session.index_gen);
    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
}

/// Decode + answer one query. A malformed frame or an unservable request
/// (`error.Stale` from a lost freshness anchor / rebuilt index, OOM) comes back
/// as `decline` — the client re-runs it on the certified cold path. `caps` is
/// the connection's advertised transport capabilities (see `Client.caps`).
fn handleQuery(session: *ResidentSession, gpa: std.mem.Allocator, fd: std.posix.fd_t, payload: []const u8, caps: u8, ext: bool) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // `query_ext` carries a roots trailer whose slice headers live in the arena;
    // `query` is rootless. A malformed frame → decline (client → cold).
    const req = (if (ext) protocol.decodeQueryExt(arena.allocator(), payload) else protocol.decodeQuery(payload)) catch
        return protocol.sendFrame(gpa, fd, .decline, "");
    // Served-scope soundness: a scoped request is only answerable warm when its
    // roots are a subset of what THIS daemon mirrors — otherwise the resident
    // set is missing files cold would search, so warm could report empty where
    // cold matches. The common auto-spawned daemon is rootless (serves the whole
    // CWD tree) and admits every relative root; an explicitly-scoped daemon
    // declines a query that reaches outside its subtree.
    if (!session.servesScope(req.filter.roots))
        return protocol.sendFrame(gpa, fd, .decline, "");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (req.rank_k) |k| {
        // `--rank`: gist's definition-first ranked view, dispatched before the
        // mode (it overrides it). The rendered top-K rides the SAME `chunk`+
        // terminal-`result` transport as a `lines` answer, with `matched=true` so
        // the client exits 0 — cold `--rank` always exits 0 (only a path error is
        // 2, and the client's `rootsExist` gate already sent those cold).
        const bytes = session.queryRank(arena.allocator(), req, k) catch
            return protocol.sendFrame(gpa, fd, .decline, "");
        try protocol.encodeLines(&buf, gpa, bytes, true);
    } else if (req.quiet) {
        // `-q`: an existence-only answer regardless of the mode byte. The walk
        // halts at the first hit (`queryExists`); framed as a zero-chunk `lines`
        // result carrying just the matched flag, so the client prints nothing
        // and exits 0/1 on it. `-m0` resolves to `matched=false` inside.
        const found = session.queryExists(req) catch
            return protocol.sendFrame(gpa, fd, .decline, "");
        try protocol.encodeLines(&buf, gpa, "", found);
    } else if (req.mode == .lines) {
        // The default line search. A client that advertised fd-transport gets the
        // ZERO-COPY path when the answer clears `fd_transport_floor`: it is
        // rendered STRAIGHT into shared memory and handed over as one `chunk_fd`
        // frame + the shm fd, so the multi-MB bytes never traverse the socket.
        // Below the floor — or on any shm failure — `renderLinesShm` returns the
        // rendered bytes to stream as ordinary `chunk` frames, byte-identical and
        // never a new failure mode. A peer that didn't advertise takes the plain
        // `queryLines` + `chunk` path unchanged.
        if ((caps & protocol.caps_supported & protocol.cap_fd_transport) != 0) {
            switch (session.queryLinesShm(arena.allocator(), req, protocol.fd_transport_floor) catch
                return protocol.sendFrame(gpa, fd, .decline, "")) {
                .fd => |shl| {
                    var buffer = shl.buffer;
                    defer buffer.close();
                    buffer.freeze(); // drop the daemon's writable view, seal (Linux)
                    if (!protocol.sendChunkFd(fd, shl.len, shl.matched, buffer.fd)) return error.ConnClosed;
                    return;
                },
                .chunk => |c| {
                    try protocol.encodeLines(&buf, gpa, c.bytes, c.matched);
                    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
                    return;
                },
            }
        }
        const ans = session.queryLines(arena.allocator(), req) catch
            return protocol.sendFrame(gpa, fd, .decline, "");
        try protocol.encodeLines(&buf, gpa, ans.out, ans.matched);
    } else {
        const result = session.query(arena.allocator(), req) catch
            return protocol.sendFrame(gpa, fd, .decline, "");
        switch (result.mode) {
            .files => try protocol.encodeFiles(&buf, gpa, result.files),
            .count => try protocol.encodeCount(&buf, gpa, result.count),
            .lines => unreachable, // routed above
        }
    }
    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
}

/// The socket path a daemon binds / a client dials: `$GIST_SESSION_SOCK` when
/// set, else the per-repo default beside the index (`corpus.outDir()`, itself
/// `$GIST_DIR`-overridable). The returned slice is gpa-owned.
pub fn socketPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("GIST_SESSION_SOCK")) |p| return gpa.dupe(u8, p);
    return std.fmt.allocPrint(gpa, "{s}/gistd.sock", .{corpus.outDir()});
}
