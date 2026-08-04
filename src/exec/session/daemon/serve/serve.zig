//! gist resident daemon — `gist serve`.
//!
//! Holds one `ResidentSession` warm behind a Unix-domain socket so a persistent
//! client answers an eligible query without re-paying the cold subprocess's
//! process + index-mmap + candidate-read startup on every call — the whole
//! reason the warm certificate can post a geomean the cold path never could. It
//! is the transport shell only; the correctness (freshness, parity) lives in the
//! session (`src/exec/session/`).
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
//!   * **Single-instance** — before touching the socket, `run` takes an exclusive
//!     lock on `<socket>.lock`. Exactly one racer wins; the losers return at
//!     once *without* unlinking the winner's live socket. The lock is taken
//!     first precisely so a loser never runs the stale-socket cleanup below.
//!   * **Idle self-release, in two stages** (`idle.zig`) — the accept loop
//!     `poll`s with a timeout and gives resources back in the order they cost
//!     the MACHINE rather than this process. First the watch set: macOS holds
//!     one descriptor per watched vnode (~26k here, a real slice of the
//!     system-wide file table) and several trees each keep their own daemon, so
//!     a quiet daemon releases every one of them and drops to the
//!     reconcile-always baseline — pure speed, never correctness —
//!     re-registering once returning traffic settles. Then the session: at
//!     `idle.ttl_ms` of continuous idleness the daemon exits so an abandoned
//!     session doesn't pin RAM forever. The next query just re-spawns it.
//!
//! An explicit `shutdown` frame also stops the loop; a client merely
//! disconnecting just frees the daemon for the next one.

const std = @import("std");
const resident = @import("irregex").session.resident;
const image = @import("../../conduit/image.zig");
const rendezvous = @import("../../conduit/rendezvous.zig");
const watch = @import("irregex").session.watch;
const keep_mod = @import("irregex").inner.session.keep;
const ration = @import("../../warden/ration.zig");
const warden_mod = @import("../../warden/warden.zig");
const standdown = @import("../../warden/standdown.zig");
const answer = @import("answer.zig");
const crew = @import("crew.zig");
const loop = @import("loop.zig");
const vigil = @import("../../conduit/vigil.zig");
const corpus = @import("irregex").corpus;
// `frame` is taken by the protocol frames threaded through the daemon.
const frame_mod = @import("irregex").inner.corpus.frame;
const fault = @import("irregex").fault;
const portal = @import("irregex").portal;
const home = @import("irregex").index.home;
const net = std.Io.net;
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;
const Warden = warden_mod.Warden;

/// What the session surrenders when it meets its memory ration: the whole answer
/// keep. Called from inside a failing allocation on whichever thread met the
/// ceiling, so it must not block — `Keep.surrender` tries its lock and reports
/// zero rather than deadlocking against a `retain` already holding it.
fn surrenderKeep(ctx: *anyopaque) usize {
    const k: *keep_mod.Keep = @ptrCast(@alignCast(ctx));
    return k.surrender();
}

/// Serve `roots` warm on `socket_path` until it goes idle, a client sends
/// `shutdown`, or the listener dies. Owns the session + socket for its whole
/// lifetime. Returns immediately (no-op) if another daemon already holds the
/// single-instance lock, so it is safe to auto-spawn or run twice.
pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, socket_path: []const u8) !void {
    // A platform without unix sockets has no resident tier at all, and the warm
    // tier is an optimization the cold path never depends on. Declining here —
    // rather than at the socket call — keeps the whole listener graph out of
    // semantic analysis on such a target instead of half-porting it.
    if (comptime portal.resident_sessions) return serveResident(gpa, io, roots, socket_path);
    crew.note("gist serve: no resident tier on this platform — queries answer cold\n", .{});
}

fn serveResident(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, socket_path: []const u8) !void {
    // Singleton FIRST — before any socket mutation — so a losing racer never
    // unlinks the winner's live socket during the stale-socket cleanup below.
    const lock = acquireSingleton(io, socket_path) orelse {
        crew.note("gist serve: another daemon already warm on {s}\n", .{socket_path});
        return;
    };
    defer lock.close(io); // closing releases the lock

    // Everything below is charged against ONE ration: the session's mirror and
    // trigram index, the answer keep, the watcher's bookkeeping, and each
    // worker's per-query arena all build on `mem`. This is the only seam where
    // that is true — `run` receives a single allocator and threads it into
    // everything it constructs — which is what lets a wrapper here bound the
    // whole resident set instead of the parts someone remembered to check.
    const allowance = ration.addressable();
    if (allowance == 0) {
        crew.note("gist serve: this machine lends no resident ration — queries answer cold\n", .{});
        return;
    }
    var warden = Warden.init(gpa, allowance);
    const mem = warden.allocator();

    // Loading the mirror is the largest single claim a session makes, so it is
    // where an over-large corpus meets the ceiling. Meeting it is a DECLINATURE,
    // not a fault: cold answers every query correctly, so the daemon stands down
    // and says so, rather than propagating an OOM that reads like a crash. The
    // note is what stops the next query re-staging the same doomed load.
    var session = ResidentSession.init(mem, io, roots) catch |e| {
        if (e != error.OutOfMemory or warden.turnedAway() == 0) return e;
        crew.note("gist serve: mirror does not fit the {d} MB ration (held {d} MB) — standing down, queries answer cold\n", .{ allowance >> 20, warden.peak() >> 20 });
        standdown.mark(io, socket_path, warden.peak(), allowance);
        return;
    };
    defer session.deinit();
    // It DID fit, so withdraw any refusal an earlier daemon left: a corpus that
    // shrank, a machine that freed memory, or a raised ration all recover here
    // instead of waiting out the lull.
    standdown.lift(io, socket_path);
    session.daemon_gen = @bitCast(@as(i64, @truncate(std.Io.Clock.now(.real, io).nanoseconds)));
    // Latch the build NOW, while the file on disk is still the one we were
    // exec'd from. A daemon outlives rebuilds; asking at handshake time would
    // report whichever binary a coworker last installed and vouch for a build
    // this process has never run.
    session.image = image.stamp(io);
    // Only the daemon arms a budget; embedders/FFI/tests keep the unbudgeted
    // default so their behavior — and the fast path's zero clock reads — is
    // unchanged. Survives an index-reload (config, not per-index data).
    session.query_budget_ns = answer.budgetNs();

    var watcher = watch.Watcher(ResidentSession).init(mem, io, &session);
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
    const ua = try rendezvous.address(socket_path);
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

    // Shared server state + the worker-completion bell. Failing to open it is
    // fatal to the daemon (essentially only descriptor exhaustion) — the client
    // then just answers cold and re-spawns later; worker-spawn failure only
    // degrades to inline handling (below), so it fails open.
    const bell = vigil.Bell.open(io) catch return fault.Resource.Exhausted;
    // The answer keep outlives every connection and dies with the daemon — its
    // whole soundness argument rests on this watcher's epoch, so it must not
    // survive the watcher that vouched for it.
    var keep = keep_mod.Keep.init(mem);
    defer keep.deinit();
    // The keep is the one thing a session under pressure can give back, and the
    // reason the ceiling throttles rather than kills: every entry is rendered
    // output the daemon can recompute, which is what made it cacheable. Spend it
    // before declining a query (`warden/warden.zig`).
    warden.attend(.{ .ctx = &keep, .hand = surrenderKeep });
    var server = crew.Server{ .gpa = mem, .io = io, .session = &session, .watcher = &watcher, .keep = &keep, .bell = bell };
    // Teardown runs LIFO; register so it unwinds in this order: (1) stop + join
    // the workers — they touch the session, the connections, and the bell, so
    // they must all be quiescent first; (2) close the connections; (3) close the
    // bell. `session.deinit`/`watcher.stop` (registered far above) run after the
    // join, as they must.
    defer server.bell.close(io);
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

    // Say what the load actually cost, because the load PEAK — not the steady
    // state — is what a ration has to accommodate, and the two differ by an
    // order of magnitude here. A daemon reporting a crest near its ration is one
    // rebuild away from standing down, which is worth knowing before it does.
    crew.note("gist serve: warm on {s} ({d} roots, {d} workers, held {d} MB of a {d} MB ration, load crest {d} MB)\n", .{ socket_path, roots.len, nworkers, warden.holding() >> 20, allowance >> 20, warden.peak() >> 20 });
    loop.run(&server, &listener);
}

/// Take the single-instance lock on `<socket_path>.lock`. Returns the held file
/// (keep it open for the daemon's lifetime — closing releases the lock), or
/// `null` if another daemon owns it or the lock file can't be opened (in which
/// case the caller declines to start rather than fight over the socket).
///
/// One call, no platform arm: std acquires the lock *as part of* the open, and
/// both spellings underneath it are release-on-close, so the `defer` that closes
/// this file is the whole release protocol. POSIX is `flock(2)`; Windows has no
/// `flock` but `NtLockFile` over a fixed byte range is the same fact — a
/// non-blocking exclusive request that either wins or reports `WouldBlock`, which
/// is exactly the two outcomes this function has ever had.
fn acquireSingleton(io: std.Io, socket_path: []const u8) ?std.Io.File {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const lock_path = std.fmt.bufPrint(&buf, "{s}.lock", .{socket_path}) catch return null;
    // Best-effort for the same reason as the socket directory: the create
    // below is the real check and already declines by returning null.
    if (std.fs.path.dirnamePosix(lock_path)) |dir|
        fault.spare("pre-create the lock directory", Dir.cwd().createDirPath(io, dir));
    // `truncate = false` because the file is a rendezvous, not a payload — the
    // bytes are nobody's, and truncating one a live daemon holds would be a write
    // this function has no business making.
    return Dir.cwd().createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch null; // WouldBlock = a live daemon holds it → this racer stands down
}

/// The socket path a daemon binds / a client dials: `$GIST_SESSION_SOCK` when
/// set, else the per-repo default beside the index (`home.outDir()`, itself
/// `$GIST_DIR`-overridable). The returned slice is gpa-owned.
pub fn socketPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("GIST_SESSION_SOCK")) |p| return gpa.dupe(u8, p);
    return std.fmt.allocPrint(gpa, "{s}/gistd.sock", .{home.outDir()});
}
