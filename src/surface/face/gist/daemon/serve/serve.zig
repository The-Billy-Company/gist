//! gist resident daemon — `gist serve` (ADR-352 rung 2.5).
//!
//! Holds one `ResidentSession` warm behind a Unix-domain socket so a persistent
//! client answers an eligible query without re-paying the cold subprocess's
//! process + index-mmap + candidate-read startup on every call — the whole
//! reason the warm certificate can post a geomean the cold path never could. It
//! is the transport shell only; the correctness (freshness, parity) lives in the
//! session (`src/surface/exec/session/`).
//!
//! This file is the **lifecycle**: grab the single-instance lock, build the
//! session, arm the freshness watcher, bind the socket (unlinking a stale one),
//! raise the worker pool, hand the whole apparatus to the loop, and unwind it
//! afterwards in the one order that is safe. The four peers it drives are each
//! one layer of the daemon:
//!
//!   * `crew.zig`   — the connection table and the bounded worker pool: who may
//!                    touch which fd, and when.
//!   * `loop.zig`   — the poll-multiplexed accept loop, the idle policy's only
//!                    quiescent window, and the annals seed.
//!   * `route.zig`  — one readable client's frame: answered inline if cheap,
//!                    dispatched to a worker if not.
//!   * `answer.zig` — a query's decode → session verb → response write, and the
//!                    per-query budget that bounds a runaway one.
//!   * `idle.zig`   — what an idle daemon gives back, and when.
//!
//! Two self-management properties make the daemon safe to auto-spawn (the cold
//! CLI forks one on the first eligible miss, so ~10 coworker CLIs may each race
//! to start one):
//!
//!   * **Single-instance** — before touching the socket, `run` takes an advisory
//!     `flock` on `<socket>.lock`. Exactly one racer wins; the losers return at
//!     once *without* unlinking the winner's live socket. The lock is taken
//!     first precisely so a loser never runs the stale-socket cleanup below.
//!   * **Idle self-release, in two stages** (`idle.zig`) — the accept loop
//!     `poll`s with a timeout and gives resources back in the order they cost
//!     the MACHINE rather than this process. First the watch set: macOS holds
//!     one descriptor per watched vnode (~26k here, a real slice of the
//!     system-wide file table) and several trees each keep their own daemon, so
//!     a quiet daemon releases every one of them and drops to the
//!     reconcile-always baseline — pure speed, never correctness (ADR-372) —
//!     re-registering once returning traffic settles. Then the session: at
//!     `idle.ttl_ms` of continuous idleness the daemon exits so an abandoned
//!     session doesn't pin RAM forever. The next query just re-spawns it.
//!
//! An explicit `shutdown` frame also stops the loop; a client merely
//! disconnecting just frees the daemon for the next one.

const std = @import("std");
const resident = @import("../../../../exec/session/warm/resident.zig");
const watch = @import("../../../../exec/session/watch/watch.zig");
const keep_mod = @import("../../../../exec/session/answer/keep.zig");
const answer = @import("answer.zig");
const crew = @import("crew.zig");
const loop = @import("loop.zig");
const corpus = @import("../../../../../corpus/tree/corpus.zig");
// `frame` is taken by the protocol frames threaded through the daemon.
const frame_mod = @import("../../../../../corpus/index/frame/frame.zig");
const fault = @import("../../../../../fault.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

extern "c" fn flock(fd: std.posix.fd_t, operation: c_int) c_int;
extern "c" fn close(fd: std.posix.fd_t) c_int;
extern "c" fn pipe(fds: *[2]std.posix.fd_t) c_int;

/// Serve `roots` warm on `socket_path` until it goes idle, a client sends
/// `shutdown`, or the listener dies. Owns the session + socket for its whole
/// lifetime. Returns immediately (no-op) if another daemon already holds the
/// single-instance lock, so it is safe to auto-spawn or run twice.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, socket_path: []const u8) !void {
    // Singleton FIRST — before any socket mutation — so a losing racer never
    // unlinks the winner's live socket during the stale-socket cleanup below.
    const lock_fd = acquireSingleton(io, socket_path) orelse {
        crew.note("gist serve: another daemon already warm on {s}\n", .{socket_path});
        return;
    };
    defer _ = close(lock_fd); // closing releases the advisory flock

    var session = try ResidentSession.init(gpa, io, roots);
    defer session.deinit();
    session.daemon_gen = @bitCast(@as(i64, @truncate(std.Io.Clock.now(.real, io).nanoseconds)));
    // Only the daemon arms a budget; embedders/FFI/tests keep the unbudgeted
    // default so their behavior — and the fast path's zero clock reads — is
    // unchanged. Survives an index-reload (config, not per-index data).
    session.query_budget_ns = answer.budgetNs();

    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    watcher.start();
    defer watcher.stop();
    crew.note("gist serve: watcher {s}, exact dirty log {s}\n", .{
        if (session.seqlock.armed()) "armed" else "unavailable (reconcile-always)",
        if (session.dirty_log.exact) "on" else "off",
    });

    // Both are best-effort because `listen` below is the real check: if the
    // directory is genuinely unusable, binding fails there with a fault the
    // caller sees, so failing here would only report it twice.
    if (std.fs.path.dirnamePosix(socket_path)) |dir|
        fault.spare("pre-create the socket directory", Dir.cwd().createDirPath(io, dir));
    fault.spare("clear a stale socket from a crashed daemon", Dir.cwd().deleteFile(io, socket_path));
    const ua = try net.UnixAddress.init(socket_path);
    var listener = try ua.listen(io, .{});
    defer listener.deinit(io);
    defer fault.spare("unlink the socket on shutdown", Dir.cwd().deleteFile(io, socket_path));
    // Say which tree went resident here, beside the socket. The socket lives in
    // the artifact directory, so a `GIST_DIR` shared by two checkouts aims both
    // at THIS rendezvous — and resident bytes carry no path prefix to give the
    // mix-up away. The client re-proves the binding before it dials
    // (`frame_mod.socketBindingPath`) and answers cold when it names another
    // tree; publishing after `listen` means the file exists for as long as
    // anyone can connect.
    var bind_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (frame_mod.socketBindingPath(&bind_buf, socket_path)) |bind_path| {
        frame_mod.publishBinding(io, bind_path);
    }
    defer if (frame_mod.socketBindingPath(&bind_buf, socket_path)) |bind_path| {
        fault.spare("unlink the socket binding on shutdown", Dir.cwd().deleteFile(io, bind_path));
    };

    // Shared server state + the worker-completion wakeup pipe. Pipe failure is
    // fatal to the daemon (essentially only fd exhaustion) — the client then
    // just answers cold and re-spawns later; worker-spawn failure only degrades
    // to inline handling (below), so it fails open.
    var wp: [2]std.posix.fd_t = undefined;
    if (pipe(&wp) != 0) return fault.Resource.Exhausted;
    // The answer keep outlives every connection and dies with the daemon — its
    // whole soundness argument rests on this watcher's epoch, so it must not
    // survive the watcher that vouched for it.
    var keep = keep_mod.Keep.init(gpa);
    defer keep.deinit();
    var server = crew.Server{ .gpa = gpa, .io = io, .session = &session, .watcher = &watcher, .keep = &keep, .wake_r = wp[0], .wake_w = wp[1] };
    // Teardown runs LIFO; register so it unwinds in this order: (1) stop + join
    // the workers — they touch the session, the connections, and the wake pipe,
    // so they must all be quiescent first; (2) close the connections; (3) close
    // the pipe. `session.deinit`/`watcher.stop` (registered far above) run after
    // the join, as they must.
    defer {
        _ = close(server.wake_r);
        _ = close(server.wake_w);
    }
    defer for (&server.conns) |*c| {
        if (c.state != .free) c.stream.close(io);
    };

    var workers: [crew.max_clients]std.Thread = undefined;
    var nworkers: usize = 0;
    const want = crew.configuredWorkers();
    while (nworkers < want) : (nworkers += 1)
        workers[nworkers] = std.Thread.spawn(.{}, crew.Server.workerMain, .{&server}) catch break;
    server.pool_ready = nworkers > 0;
    defer {
        server.mutex.lockUncancelable(io);
        server.shutting_down = true;
        server.mutex.unlock(io);
        server.job_ready.broadcast(io);
        for (workers[0..nworkers]) |w| w.join();
    }

    crew.note("gist serve: warm on {s} ({d} roots, {d} workers)\n", .{ socket_path, roots.len, nworkers });
    try loop.run(&server, &listener);
}

/// Take the advisory single-instance lock on `<socket_path>.lock`. Returns the
/// held fd (keep it open for the daemon's lifetime — closing releases the lock),
/// or `null` if another daemon owns it or the lock file can't be opened (in
/// which case the caller declines to start rather than fight over the socket).
fn acquireSingleton(io: std.Io, socket_path: []const u8) ?std.posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&buf, "{s}.lock", .{socket_path}) catch return null;
    // Best-effort for the same reason as the socket directory: the `openat`
    // below is the real check and already declines by returning null.
    if (std.fs.path.dirnamePosix(lock_path)) |dir|
        fault.spare("pre-create the lock directory", Dir.cwd().createDirPath(io, dir));
    const fd = std.posix.openat(std.posix.AT.FDCWD, lock_path, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600) catch return null;
    if (flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB) != 0) {
        _ = close(fd); // held by a live daemon → this racer stands down
        return null;
    }
    return fd;
}

/// The socket path a daemon binds / a client dials: `$GIST_SESSION_SOCK` when
/// set, else the per-repo default beside the index (`corpus.outDir()`, itself
/// `$GIST_DIR`-overridable). The returned slice is gpa-owned.
pub fn socketPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("GIST_SESSION_SOCK")) |p| return gpa.dupe(u8, p);
    return std.fmt.allocPrint(gpa, "{s}/gistd.sock", .{corpus.outDir()});
}
