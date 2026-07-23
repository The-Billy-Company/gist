//! gist resident daemon — `gist serve` (ADR-352 rung 2.5).
//!
//! Holds one `ResidentSession` warm behind a Unix-domain socket so a persistent
//! client answers an eligible query without re-paying the cold subprocess's
//! process + index-mmap + candidate-read startup on every call — the whole
//! reason the warm certificate can post a geomean the cold path never could. It
//! is the transport shell only; the correctness (freshness, parity) lives in the
//! session (`src/surface/exec/session/`).
//!
//! Lifecycle: grab the single-instance lock, build the session, arm the
//! freshness watcher, bind the socket (unlinking a stale one), then a
//! **poll-multiplexed** accept loop — one `poll` set over the listener, a
//! worker-completion wakeup pipe, and every idle client — routing one frame per
//! readable client per wakeup.
//!
//! ## Concurrency: the poll thread routes, a worker pool answers
//!
//! ~10 coworker agents share one auto-spawned daemon, so a single slow query
//! must never stall everyone else. The poll thread stays the sole owner of every
//! connection's lifecycle (accept, read the small request frame, drop, teardown)
//! and answers the cheap control frames — `hello`/`status`/`ping`/`changed`/
//! `shutdown` — inline. A `query`/`query_ext` (the expensive search AND its
//! potentially multi-MB response write) is instead handed to a bounded,
//! persistent **worker pool** (`min(cpu/2, 8)`, `GIST_SERVE_WORKERS` override):
//! the poll thread parses the request frame, lifts that connection out of the
//! poll set (the protocol is one request/response per connection, so the worker
//! owns the fd for the query's duration and writes the whole answer — `chunk`,
//! `result`, or the `chunk_fd` shm handoff — directly), and moves on to the next
//! readable client. On completion the worker posts the connection back and nudges
//! the poll thread over a self-pipe, which re-registers the fd. The session is
//! itself reader/writer-safe (the `Ward`: many warm reads overlap, a reconcile
//! runs alone), so the workers answer in parallel; the reconcile/abort counters
//! the poll thread samples for its operator note are atomic. Every failure is
//! fail-open toward cold — a declined/errored query costs the client a fallback
//! subprocess, never a wrong answer — and if the pool can't spawn, the poll
//! thread answers the query inline (the classic serial shape) rather than not at
//! all. An idle persistent client never starves a new connection either way.
//!
//! Because a worker runs one query to completion, a single runaway scan — or one
//! a client already timed out and abandoned — would hold a worker (and, under
//! saturation, could tie up the whole pool). A per-query wall-clock **budget**
//! (`ResidentSession.query_budget_ns`, sampled at strided checkpoints in the
//! O(corpus) walks) bounds that: an overrun declines the query so the client
//! answers cold and the worker is reclaimed. It is a liveness backstop, not a
//! latency SLA — generous by default (`GIST_QUERY_BUDGET_MS`), so no legitimate
//! local warm query approaches it.
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
//!     client dials (and no query is in flight) within `idle_ttl_ms` the daemon
//!     exits so an abandoned session doesn't pin RAM forever. The next query
//!     just re-spawns it.
//!
//! An explicit `shutdown` frame also stops the loop; a client merely
//! disconnecting just frees the daemon for the next one.

const std = @import("std");
const builtin = @import("builtin");
const resident = @import("../../../../exec/session/resident.zig");
const annals_mod = @import("../../../../exec/session/annals.zig");
const protocol = @import("../../../../exec/session/protocol.zig");
const watch = @import("../../../../exec/session/watch.zig");
const corpus = @import("../../../../../corpus/tree/corpus.zig");
const fresh = @import("../../../../../corpus/index/trigrams/fresh.zig");
const journal = @import("../../../../../corpus/tree/journal.zig");
const net = std.Io.net;
const Dir = std.Io.Dir;

const ResidentSession = resident.ResidentSession;

extern "c" fn flock(fd: std.posix.fd_t, operation: c_int) c_int;
extern "c" fn close(fd: std.posix.fd_t) c_int;
extern "c" fn pipe(fds: *[2]std.posix.fd_t) c_int;
extern "c" fn write(fd: std.posix.fd_t, buf: [*]const u8, n: usize) isize;

/// What routing one frame on the poll thread tells the loop to do with that
/// connection: keep it registered, drop it (closed/errored peer), stop the
/// daemon, or that the frame was dispatched to a worker (the connection left the
/// poll set and the worker will report it back through the completion queue).
const Route = enum { keep, drop, stop, dispatched };

/// One registered client connection, held in a STABLE fixed-slot array (not a
/// growing `ArrayList`) so a worker can reference its slot across the poll
/// thread's accept/drop churn without the entry moving under it. `gen` is the
/// per-connection session generation the READY frame reports; `caps` is the
/// transport capabilities advertised in HELLO (0 until then). `state` is written
/// ONLY by the poll thread; a worker touches a slot's `stream`/`caps` solely
/// while it is `.in_flight` (handed off under the pool mutex, so the fields the
/// poll thread set are visible), and never its `state`.
const Conn = struct {
    stream: net.Stream,
    gen: u64,
    caps: u8 = 0,
    state: State = .free,

    const State = enum { free, active, in_flight };
};

/// Registered-connection cap. Beyond it a new connection is closed at accept
/// and the client falls back to the certified cold path — fail-open, never a
/// hang. Generous: the realistic local population is ~10 coworker agents. It
/// also bounds every pool queue: a connection contributes at most one in-flight
/// query at a time (one request/response per connection), so pending + in-flight
/// jobs — and completions — never exceed this.
const max_clients: usize = 64;

/// Upper bound on the worker pool regardless of core count: enough parallelism
/// for the coworker population without oversubscribing a laptop under a burst.
const worker_cap: usize = 8;

/// A bounded FIFO sized to `max_clients` — never overflows because at most one
/// job/completion per connection is outstanding. Guarded by the pool mutex.
fn Ring(comptime T: type) type {
    return struct {
        buf: [max_clients]T = undefined,
        head: usize = 0,
        len: usize = 0,

        const Self = @This();

        fn push(self: *Self, v: T) void {
            std.debug.assert(self.len < max_clients);
            self.buf[(self.head + self.len) % max_clients] = v;
            self.len += 1;
        }

        fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const v = self.buf[self.head];
            self.head = (self.head + 1) % max_clients;
            self.len -= 1;
            return v;
        }
    };
}

/// A query handed to a worker: the connection slot it belongs to and the request
/// frame the poll thread already read (the worker owns it and deinits it after
/// answering directly on the connection's fd).
const Job = struct { slot: u16, frame: protocol.Frame };

/// A finished query posted back to the poll thread: the slot to re-register, or
/// drop when the worker's response write found the peer gone.
const Done = struct { slot: u16, drop: bool };

/// The shared daemon state a worker pool rides. The poll thread owns connection
/// lifecycle + `state`; workers pull `jobs`, answer, and push `dones`, waking the
/// poll thread over the self-pipe. `conns` lives here (by pointer to the run()
/// frame) so a worker can reach its in-flight slot's fd.
const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session: *ResidentSession,
    watcher: *watch.Watcher(ResidentSession),

    conns: [max_clients]Conn = [_]Conn{.{ .stream = undefined, .gen = 0 }} ** max_clients,

    /// False when no worker could spawn: queries then run inline on the poll
    /// thread (the classic serial daemon) — degraded, never broken.
    pool_ready: bool = false,
    mutex: std.Io.Mutex = .init,
    job_ready: std.Io.Condition = .init,
    jobs: Ring(Job) = .{},
    dones: Ring(Done) = .{},
    shutting_down: bool = false,
    wake_r: std.posix.fd_t,
    wake_w: std.posix.fd_t,

    /// Hand a parsed query frame to the pool: mark the slot in-flight (so the
    /// poll thread stops polling its fd), enqueue, and signal one worker. The
    /// frame's ownership moves into the job.
    fn dispatch(self: *Server, slot: u16, frame: protocol.Frame) void {
        self.conns[slot].state = .in_flight;
        self.mutex.lockUncancelable(self.io);
        self.jobs.push(.{ .slot = slot, .frame = frame });
        self.mutex.unlock(self.io);
        self.job_ready.signal(self.io);
    }

    /// Wake the poll thread from its `poll` so it drains completions promptly. A
    /// single byte per completion; the pipe holds ≤ `max_clients` outstanding
    /// bytes (« its buffer), so this write never blocks in practice.
    fn wake(self: *Server) void {
        _ = write(self.wake_w, &[_]u8{1}, 1);
    }

    /// Drain the self-pipe's readiness after `poll` reports it — one read clears
    /// the accumulated wakeup bytes; any residue simply re-triggers next loop.
    fn drainWake(self: *Server) void {
        var buf: [256]u8 = undefined;
        _ = std.posix.read(self.wake_r, &buf) catch {};
    }

    /// Apply every finished query the workers posted: re-register a kept
    /// connection (back to `.active`, so the next loop polls its fd for the next
    /// request) or close + free a dropped one. Poll-thread only.
    fn drainCompletions(self: *Server) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const done = self.dones.pop();
            self.mutex.unlock(self.io);
            const d = done orelse break;
            const c = &self.conns[d.slot];
            if (d.drop) {
                c.stream.close(self.io);
                c.state = .free;
            } else {
                c.state = .active;
            }
        }
    }

    /// The first free connection slot, or null when the daemon is at `max_clients`.
    fn freeSlot(self: *Server) ?u16 {
        for (&self.conns, 0..) |*c, i| if (c.state == .free) return @intCast(i);
        return null;
    }

    /// A pool worker: block for a job, answer it directly on the connection's fd
    /// (writing the response off the poll thread — the whole point), then post
    /// the connection back and nudge the poll thread. Exits when the daemon is
    /// shutting down and the queue has drained.
    fn workerMain(self: *Server) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.jobs.len == 0 and !self.shutting_down)
                self.job_ready.waitUncancelable(self.io, &self.mutex);
            const job = self.jobs.pop() orelse {
                self.mutex.unlock(self.io);
                return; // shutting down, queue drained
            };
            self.mutex.unlock(self.io);

            var frame = job.frame;
            const c = &self.conns[job.slot];
            const ext = frame.op == .query_ext;
            const drop = if (handleQuery(self.session, self.gpa, c.stream.socket.handle, frame.payload(), c.caps, ext)) |_|
                false
            else |_|
                true;
            frame.deinit();

            self.mutex.lockUncancelable(self.io);
            self.dones.push(.{ .slot = job.slot, .drop = drop });
            self.mutex.unlock(self.io);
            self.wake();
        }
    }
};

/// Operator-facing lifecycle line on stderr. Silenced under `zig build test`:
/// the daemon is spawned in-process by `serve_test.zig`, and any stderr from a
/// passing unit-test binary makes the build runner dump the step tree with a
/// spurious "failed command:" banner — a green run must read green.
fn note(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt, args);
}

/// Idle window with zero connections (and no query in flight) before a warm
/// daemon self-exits: the resident index/corpus stops earning its RAM once
/// nobody is querying, and a fresh query re-spawns one in the background anyway
/// (see `client/spawn.zig`).
const idle_ttl_ms: i32 = 10 * 60 * 1000;

/// Default per-query wall-clock ceiling (see the header): a liveness backstop
/// deliberately far above any legitimate local warm query, so it only bounds a
/// runaway or abandoned scan that would otherwise pin a shared worker.
/// `GIST_QUERY_BUDGET_MS` overrides it; `0` disables the ceiling entirely.
const query_budget_ms_default: i64 = 30_000;

/// Test hook (mirrors `shm.force_fail_for_test`): a non-negative value forces
/// the per-query budget in NANOSECONDS, so a unit test can drive the abort path
/// deterministically without a giant corpus. `-1` (the default) defers to
/// `GIST_QUERY_BUDGET_MS` / `query_budget_ms_default`.
pub var query_budget_ns_override: std.atomic.Value(i64) = .init(-1);

/// Test hook: when non-null, every query handler blocks on this event before
/// answering, so a test can pin a query "in flight" on its worker and prove the
/// poll thread still serves another client's control frame. `std.Io.Event` is a
/// latching manual-reset flag — `set` is idempotent, so a failed test assertion
/// releasing it twice can't leave a worker parked and deadlock the pool join.
/// Null (the default) is no gate.
pub var query_gate_for_test: std.atomic.Value(?*std.Io.Event) = .init(null);

/// Resolve this daemon's per-query budget in nanoseconds: the test override if
/// armed, else `GIST_QUERY_BUDGET_MS`, else the default. A malformed env value
/// falls back to the default rather than failing the daemon.
fn configuredBudgetNs() i128 {
    const override = query_budget_ns_override.load(.monotonic);
    if (override >= 0) return override;
    const ms: i64 = if (std.c.getenv("GIST_QUERY_BUDGET_MS")) |s|
        std.fmt.parseInt(i64, std.mem.span(s), 10) catch query_budget_ms_default
    else
        query_budget_ms_default;
    return @as(i128, @max(ms, 0)) * std.time.ns_per_ms;
}

/// Worker count: `GIST_SERVE_WORKERS` if a positive value is set (capped at
/// `max_clients`), else `min(cpu/2, worker_cap)`, at least one. Read once at
/// startup; the pool is fixed for the daemon's life.
fn configuredWorkers() usize {
    if (std.c.getenv("GIST_SERVE_WORKERS")) |s| {
        const n = std.fmt.parseInt(usize, std.mem.span(s), 10) catch 0;
        if (n > 0) return @min(n, max_clients);
    }
    const cpu = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(cpu / 2, 1, worker_cap);
}

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
    // Only the daemon arms a budget; embedders/FFI/tests keep the unbudgeted
    // default so their behavior — and the fast path's zero clock reads — is
    // unchanged. Survives an index-reload (config, not per-index data).
    session.query_budget_ns = configuredBudgetNs();

    var watcher = watch.Watcher(ResidentSession).init(gpa, io, &session);
    watcher.start();
    defer watcher.stop();
    note("gist serve: watcher {s}, exact dirty log {s}\n", .{
        if (session.seqlock.active) "armed" else "unavailable (reconcile-always)",
        if (session.dirty_log.exact) "on" else "off",
    });
    // Boot-seed the annals from the persisted journal token: a `gist index`
    // amend asks "changed since base.ns" — an instant that usually PREDATES
    // this daemon — so replay the OS journal once and extend coverage back to
    // the token's mint. Best-effort: any doubt leaves coverage at stream-live
    // (the consult declines; the client falls back to its own replay/walk).
    seedAnnals(gpa, io, &session);

    if (std.fs.path.dirnamePosix(socket_path)) |dir| Dir.cwd().createDirPath(io, dir) catch {};
    Dir.cwd().deleteFile(io, socket_path) catch {}; // clear a stale socket from a crashed daemon
    const ua = try net.UnixAddress.init(socket_path);
    var listener = try ua.listen(io, .{});
    defer listener.deinit(io);
    defer Dir.cwd().deleteFile(io, socket_path) catch {};

    // Shared server state + the worker-completion wakeup pipe. Pipe failure is
    // fatal to the daemon (essentially only fd exhaustion) — the client then
    // just answers cold and re-spawns later; worker-spawn failure only degrades
    // to inline handling (below), so it fails open.
    var wp: [2]std.posix.fd_t = undefined;
    if (pipe(&wp) != 0) return error.WakePipeFailed;
    var server = Server{ .gpa = gpa, .io = io, .session = &session, .watcher = &watcher, .wake_r = wp[0], .wake_w = wp[1] };
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

    var workers: [max_clients]std.Thread = undefined;
    var nworkers: usize = 0;
    const want = configuredWorkers();
    while (nworkers < want) : (nworkers += 1)
        workers[nworkers] = std.Thread.spawn(.{}, Server.workerMain, .{&server}) catch break;
    server.pool_ready = nworkers > 0;
    defer {
        server.mutex.lockUncancelable(io);
        server.shutting_down = true;
        server.mutex.unlock(io);
        server.job_ready.broadcast(io);
        for (workers[0..nworkers]) |w| w.join();
    }

    note("gist serve: warm on {s} ({d} roots, {d} workers)\n", .{ socket_path, roots.len, nworkers });

    // Poll-multiplexed loop: slot 0 is the listener, slot 1 the wakeup pipe,
    // slots 2.. the currently-idle (`.active`) connections. An in-flight
    // connection is off the poll set entirely (its worker owns the fd), so one
    // long query never blocks a new connection or another client's probe.
    var pfds: std.ArrayList(std.posix.pollfd) = .empty;
    defer pfds.deinit(gpa);
    var pfd_slots: std.ArrayList(u16) = .empty;
    defer pfd_slots.deinit(gpa);

    var session_gen: u64 = 0;
    var last_scoped: u64 = 0;
    var last_full: u64 = 0;
    var last_aborts: u64 = 0;
    serve_loop: while (true) {
        server.drainCompletions();

        // Sample the (atomic) reconcile/abort counters a worker may have bumped
        // and surface a one-line operator note on any change.
        const scoped = session.scoped_reconciles.load(.monotonic);
        const full = session.full_reconciles.load(.monotonic);
        if (scoped != last_scoped or full != last_full) {
            last_scoped = scoped;
            last_full = full;
            note("gist serve: reconciled (scoped={d} full={d})\n", .{ last_scoped, last_full });
        }
        const aborts = session.budget_aborts.load(.monotonic);
        if (aborts != last_aborts) {
            last_aborts = aborts;
            note("gist serve: query exceeded budget → declined cold (total {d})\n", .{aborts});
        }

        pfds.clearRetainingCapacity();
        pfd_slots.clearRetainingCapacity();
        try pfds.append(gpa, .{ .fd = listener.socket.handle, .events = std.posix.POLL.IN, .revents = 0 });
        try pfds.append(gpa, .{ .fd = server.wake_r, .events = std.posix.POLL.IN, .revents = 0 });
        var live: usize = 0;
        for (&server.conns, 0..) |*c, i| {
            if (c.state == .free) continue;
            live += 1; // active OR in-flight: a query in flight still pins the session
            if (c.state != .active) continue; // in-flight: owned by a worker, not polled
            try pfds.append(gpa, .{ .fd = c.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 });
            try pfd_slots.append(gpa, @intCast(i));
        }

        // Idle-TTL only when nothing is connected AND nothing is in flight: a
        // connected (even quiet) client, or a running query, keeps the session.
        const timeout: i32 = if (live == 0) idle_ttl_ms else -1;
        const ready = std.posix.poll(pfds.items, timeout) catch break;
        if (ready == 0) break; // idle with no connections → self-exit

        if (pfds.items[1].revents & std.posix.POLL.IN != 0) server.drainWake();

        // Serve every readable idle client (one frame each). A query dispatches
        // to the pool (the connection leaves the poll set until its worker
        // reports back); everything else answers inline right here.
        for (pfds.items[2..], pfd_slots.items) |pfd, slot| {
            if (pfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR) == 0) continue;
            switch (routeFrame(&server, slot)) {
                .keep, .dispatched => {},
                .drop => {
                    server.conns[slot].stream.close(io);
                    server.conns[slot].state = .free;
                },
                .stop => break :serve_loop,
            }
        }

        if (pfds.items[0].revents & std.posix.POLL.IN != 0) {
            const stream = listener.accept(io) catch break;
            if (server.freeSlot()) |slot| {
                session_gen +%= 1;
                server.conns[slot] = .{ .stream = stream, .gen = session_gen, .state = .active };
            } else {
                stream.close(io); // over cap → the client answers cold
            }
        }
    }
}

/// One-time boot seed of the session's annals: replay the persisted FSEvents
/// journal token (the same one the one-shot amend would replay itself) and
/// deposit each surviving file with its LIVE max(mtime, ctime) — the exact
/// quantity the stat walk compares — then extend coverage back to the token's
/// mint instant. Gated on the per-file-exact watcher being live (`dirty_log
/// .exact`): seeding must never make the ledger answerable for a window no
/// live stream is covering forward from. Every failure returns with coverage
/// unextended — sound, just younger.
fn seedAnnals(gpa: std.mem.Allocator, io: std.Io, session: *ResidentSession) void {
    if (comptime !journal.supported) return;
    if (!session.dirty_log.exact) return; // no live exact stream → never extend
    const tok = fresh.readJournalToken(gpa, io) orelse return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var entries: std.ArrayList(journal.Entry) = .empty;
    // Rootless daemon semantics: the annals cover the whole CWD tree, so the
    // replay runs over `.` regardless of served roots (a scoped daemon's
    // annals prefix won't match the amend's CWD check anyway).
    if (!journal.replay(gpa, io, &.{"."}, tok, arena.allocator(), &entries)) return;
    for (entries.items) |e| {
        if (e.is_dir) continue;
        const ts: i128 = if (Dir.cwd().statFile(io, e.path, .{ .follow_symlinks = false })) |st|
            @max(st.mtime.nanoseconds, st.ctime.nanoseconds)
        else |_|
            std.Io.Clock.now(.real, io).nanoseconds; // vanished: conservatively "now"
        if (!session.annals.seed(e.path, ts)) return; // OOM/cap: abort WITHOUT extending
    }
    session.annals.extendCoverage(tok.captured_ns);
    note("gist serve: annals seeded ({d} replayed entries, coverage from token)\n", .{entries.items.len});
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

/// Route ONE frame from a readable idle client on the POLL thread. Called only
/// after `poll` reported the fd readable, so the blocking `recvFrame` returns
/// promptly (a whole small request frame arrives in one segment on a local Unix
/// socket; a half-written frame from a dying peer ends as `ConnClosed` →
/// `.drop`). A `query`/`query_ext` is handed to the worker pool (`.dispatched`);
/// every cheap control frame answers inline. Returns `.stop` only on `shutdown`.
fn routeFrame(server: *Server, slot: u16) Route {
    const c = &server.conns[slot];
    const fd = c.stream.socket.handle;
    var frame = protocol.recvFrame(server.gpa, fd) catch return .drop; // closed/oversized/bad → drop peer
    switch (frame.op) {
        // The search verbs — the expensive path. With a live pool the frame's
        // ownership moves into a job and the connection leaves the poll set until
        // the worker reports back; without one (pool spawn failed) it runs inline
        // here, the classic serial shape.
        .query, .query_ext => {
            // Read-your-writes causal barrier (mirrors the annals consult): force
            // synchronous delivery of every FSEvents change that happened-before
            // this query — the client sent it AFTER its own writes completed, and
            // this poll read is after that — so the reconcile the worker runs
            // observes them (markDirty clears `clean`, defeating the stale
            // fast path). Without it a query landing inside the ~50 ms watcher
            // latency answers over pre-edit bytes, breaking the "index changes
            // speed, never results" claim (`index_elision_parity` freshness). Run
            // on the poll thread so `flushSync` stays single-threaded (its
            // documented invariant); a no-op off macOS / with no live stream,
            // where the session already reconciles every query.
            _ = server.watcher.flushSync();
            if (server.pool_ready) {
                server.dispatch(slot, frame); // frame ownership moves into the job
                return .dispatched;
            }
            defer frame.deinit();
            handleQuery(server.session, server.gpa, fd, frame.payload(), c.caps, frame.op == .query_ext) catch return .drop;
            return .keep;
        },
        // HELLO carries an optional caps byte after the version — latch it for
        // this connection so its queries can use fd-transport (`status` is a
        // re-handshake that never advertises, so it leaves caps untouched).
        .hello => {
            defer frame.deinit();
            const p = frame.payload();
            c.caps = if (p.len >= 2) p[1] else 0;
            sendReady(server.session, server.gpa, fd, c.gen) catch return .drop;
            return .keep;
        },
        .status => {
            defer frame.deinit();
            sendReady(server.session, server.gpa, fd, c.gen) catch return .drop;
            return .keep;
        },
        .ping => {
            defer frame.deinit();
            protocol.sendFrame(server.gpa, fd, .pong, "") catch return .drop;
            return .keep;
        },
        // The annals consult: `gist index` asking "what changed since S?".
        .changed => {
            defer frame.deinit();
            handleChanged(server.session, server.watcher, server.gpa, fd, frame.payload()) catch return .drop;
            return .keep;
        },
        .shutdown => {
            frame.deinit();
            return .stop;
        },
        // Anything server→client, or an unknown verb, is not a request: refuse
        // it as decline so a confused client falls back cold rather than hangs.
        else => {
            defer frame.deinit();
            protocol.sendFrame(server.gpa, fd, .decline, "") catch return .drop;
            return .keep;
        },
    }
}

/// Answer an annals consult: force synchronous delivery of every FSEvents
/// event already queued (the causal barrier — after `flushSync` returns, any
/// change that OCCURRED before the client captured its own witness instant has
/// been `note`d), then snapshot the ledger at/after `since_ns`. Every
/// uncertainty — no live stream to flush, an unarmed/poisoned ledger, a
/// pre-floor query, OOM — answers `ok=0`, sending the client to its proven
/// fallback (journal replay → stat walk). Never a partial list.
fn handleChanged(session: *ResidentSession, watcher: *watch.Watcher(ResidentSession), gpa: std.mem.Allocator, fd: std.posix.fd_t, payload: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const since_ns = protocol.decodeChanged(payload) catch {
        try protocol.encodeAnnals(&buf, gpa, null);
        if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
        return;
    };
    var snap: ?annals_mod.Snapshot = if (watcher.flushSync())
        session.annals.since(gpa, since_ns)
    else
        null;
    defer if (snap) |*s| s.deinit(gpa);
    try protocol.encodeAnnals(&buf, gpa, if (snap) |s| .{ .prefix = s.prefix, .paths = s.paths } else null);
    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
}

/// Answer a `hello`/`status` frame with the READY triple (daemon gen, session
/// gen, index gen) the client's handshake validates against its own protocol.
/// `index_gen` is copied under the session's read lease (`indexGenDup`) so a
/// concurrent worker's reconcile reload can't free the slice mid-encode.
fn sendReady(session: *ResidentSession, gpa: std.mem.Allocator, fd: std.posix.fd_t, session_gen: u64) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const gen = try session.indexGenDup(gpa);
    defer gpa.free(gen);
    try protocol.encodeReady(&buf, gpa, session.daemon_gen, session_gen, gen);
    if (!protocol.writeAll(fd, buf.items)) return error.ConnClosed;
}

/// Decode + answer one query. A malformed frame or an unservable request
/// (`error.Stale` from a lost freshness anchor / rebuilt index, OOM) comes back
/// as `decline` — the client re-runs it on the certified cold path. `caps` is
/// the connection's advertised transport capabilities (see `Conn.caps`). Runs on
/// a pool worker (or inline when the pool is down); the session's `Ward` makes
/// concurrent workers safe.
fn handleQuery(session: *ResidentSession, gpa: std.mem.Allocator, fd: std.posix.fd_t, payload: []const u8, caps: u8, ext: bool) !void {
    // Test-only in-flight gate (see `query_gate_for_test`): pins this handler on
    // its worker so a test can prove the poll thread still serves other clients.
    if (query_gate_for_test.load(.acquire)) |gate| gate.waitUncancelable(session.io);
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
                .chunk => |chnk| {
                    try protocol.encodeLines(&buf, gpa, chnk.bytes, chnk.matched);
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
