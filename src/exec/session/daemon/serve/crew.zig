//! gist resident daemon — the shared state the poll thread and its workers ride.
//!
//! ## Concurrency: the poll thread routes, a worker pool answers
//!
//! ~10 coworker agents share one auto-spawned daemon, so a single slow query
//! must never stall everyone else. The poll thread (`loop.zig`) stays the sole
//! owner of every connection's lifecycle (accept, read the small request frame,
//! drop, teardown) and answers the cheap control frames — `hello`/`status`/
//! `ping`/`changed`/`shutdown` — inline (`route.zig`). A `query`/`query_ext`
//! (the expensive search AND its potentially multi-MB response write) is
//! instead handed to the bounded, persistent worker pool declared here
//! (`min(cpu/2, 8)`, `GIST_SERVE_WORKERS` override): the poll thread parses the
//! request frame, lifts that connection out of the poll set (the protocol is
//! one request/response per connection, so the worker owns the fd for the
//! query's duration and writes the whole answer — `chunk`, `result`, or the
//! `chunk_fd` shm handoff — directly), and moves on to the next readable
//! client. On completion the worker posts the connection back and rings the
//! bell the poll thread is watching (`conduit/vigil.zig`), which re-registers
//! the fd.
//!
//! The session is itself reader/writer-safe (the `Ward`: many warm reads
//! overlap, a reconcile runs alone), so the workers answer in parallel; the
//! reconcile/abort counters the poll thread samples for its operator note are
//! atomic. Every failure is fail-open toward cold — a declined/errored query
//! costs the client a fallback subprocess, never a wrong answer — and if the
//! pool can't spawn, the poll thread answers the query inline (the classic
//! serial shape) rather than not at all. An idle persistent client never
//! starves a new connection either way.

const std = @import("std");
const builtin = @import("builtin");
const portal = @import("irregex").portal;
const resident = @import("irregex").session.resident;
const protocol = @import("../../conduit/protocol/protocol.zig");
const watch = @import("irregex").session.watch;
const vigil = @import("../../conduit/vigil.zig");
const keep_mod = @import("irregex").inner.session.keep;
const answer = @import("answer.zig");
const assay = @import("irregex").assay;
const net = std.Io.net;

const ResidentSession = resident.ResidentSession;

/// Registered-connection cap. Beyond it a new connection is closed at accept
/// and the client falls back to the certified cold path — fail-open, never a
/// hang. Generous: the realistic local population is ~10 coworker agents. It
/// also bounds every pool queue: a connection contributes at most one in-flight
/// query at a time (one request/response per connection), so pending + in-flight
/// jobs — and completions — never exceed this.
pub const max_clients: usize = 64;

/// Upper bound on the worker pool regardless of core count: enough parallelism
/// for the coworker population without oversubscribing a laptop under a burst.
const worker_cap: usize = 8;

/// One registered client connection, held in a STABLE fixed-slot array (not a
/// growing `ArrayList`) so a worker can reference its slot across the poll
/// thread's accept/drop churn without the entry moving under it. `gen` is the
/// per-connection session generation the READY frame reports; `caps` is the
/// transport capabilities advertised in HELLO (0 until then). `state` is written
/// ONLY by the poll thread; a worker touches a slot's `stream`/`caps` solely
/// while it is `.in_flight` (handed off under the pool mutex, so the fields the
/// poll thread set are visible), and never its `state`.
pub const Conn = struct {
    stream: net.Stream,
    gen: u64,
    caps: u8 = 0,
    state: State = .free,

    pub const State = enum { free, active, in_flight };
};

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
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    session: *ResidentSession,
    watcher: *watch.Watcher(ResidentSession),
    /// Rendered answers from the sibling faces, held against the corpus epoch
    /// (`keep.zig`). Owned by the daemon's run frame, not by the session: the
    /// session answers questions this daemon understands, the keep holds
    /// answers to questions it deliberately does not.
    keep: *keep_mod.Keep,

    conns: [max_clients]Conn = [_]Conn{.{ .stream = undefined, .gen = 0 }} ** max_clients,

    /// False when no worker could spawn: queries then run inline on the poll
    /// thread (the classic serial daemon) — degraded, never broken.
    pool_ready: bool = false,
    mutex: std.Io.Mutex = .init,
    job_ready: std.Io.Condition = .init,
    jobs: Ring(Job) = .{},
    dones: Ring(Done) = .{},
    shutting_down: bool = false,
    /// Rung by a worker, watched by the poll thread — the only thing that makes
    /// a finished query visible before the wait's next deadline.
    bell: vigil.Bell,

    /// Hand a parsed query frame to the pool: mark the slot in-flight (so the
    /// poll thread stops polling its fd), enqueue, and signal one worker. The
    /// frame's ownership moves into the job.
    pub fn dispatch(self: *Server, slot: u16, frame: protocol.Frame) void {
        self.conns[slot].state = .in_flight;
        self.mutex.lockUncancelable(self.io);
        self.jobs.push(.{ .slot = slot, .frame = frame });
        self.mutex.unlock(self.io);
        self.job_ready.signal(self.io);
    }

    /// Drain the bell's readiness after the wait reports it — one read clears the
    /// accumulated wakeup bytes; any residue simply re-triggers next loop.
    pub fn drainWake(self: *Server) void {
        self.bell.quiet(self.io);
    }

    /// Apply every finished query the workers posted: re-register a kept
    /// connection (back to `.active`, so the next loop polls its fd for the next
    /// request) or close + free a dropped one. Poll-thread only.
    pub fn drainCompletions(self: *Server) void {
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
    pub fn freeSlot(self: *Server) ?u16 {
        for (&self.conns, 0..) |*c, i| if (c.state == .free) return @intCast(i);
        return null;
    }

    /// A pool worker: block for a job, answer it directly on the connection's fd
    /// (writing the response off the poll thread — the whole point), then post
    /// the connection back and nudge the poll thread. Exits when the daemon is
    /// shutting down and the queue has drained.
    pub fn workerMain(self: *Server) void {
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
            // `GIST_TRACE=session` is the only view of per-request service time.
            // The lifecycle notes narrate the daemon; the summary a worker emits
            // travels to the *client's* stderr through its buffer sink — so from
            // the operator's side, "which requests are slow, and are any being
            // dropped" is otherwise unobservable. Lands on the daemon's own
            // stderr because this span is outside the worker's sink scope.
            const served = assay.Span.open(self.io);
            const drop = if (answer.query(self.session, self.gpa, c.stream.socket.handle, frame.payload(), c.caps, ext)) |_|
                false
            else |_|
                true;
            assay.trace(.session, "session: slot {d} · {t} · {d:.1} ms · {s}\n", .{
                job.slot, frame.op, served.read(self.io).ms(), if (drop) "dropped" else "served",
            });
            frame.deinit();

            self.mutex.lockUncancelable(self.io);
            self.dones.push(.{ .slot = job.slot, .drop = drop });
            self.mutex.unlock(self.io);
            self.bell.ring(self.io);
        }
    }
};

/// Worker count: `GIST_SERVE_WORKERS` if a positive value is set (capped at
/// `max_clients`), else `min(cpu/2, worker_cap)`, at least one. Read once at
/// startup; the pool is fixed for the daemon's life.
pub fn configuredWorkers() usize {
    if (std.c.getenv("GIST_SERVE_WORKERS")) |s| {
        const n = std.fmt.parseInt(usize, std.mem.span(s), 10) catch 0;
        if (n > 0) return @min(n, max_clients);
    }
    const cpu = portal.cpuCount() catch 1;
    return std.math.clamp(cpu / 2, 1, worker_cap);
}

/// Operator-facing lifecycle line on stderr. It lives beside the shared state
/// because both halves of the daemon narrate — `serve.zig` over setup and
/// teardown, `loop.zig` over reconciles, budget aborts, and idle staging — and
/// this is the one module they both already import. Silenced under `zig build
/// test`: the daemon is spawned in-process by `serve_test.zig`, and any stderr
/// from a passing unit-test binary makes the build runner dump the step tree
/// with a spurious "failed command:" banner — a green run must read green.
///
/// Routed through `assay.diag` rather than `std.debug.print` (never write the host's stderr):
/// the sink is what decides where a lifecycle line lands, and the daemon is the
/// one process where that decision is load-bearing — a worker answering a warm
/// query holds a `buffer` sink so its diagnostics reach the *client's* stderr
/// instead of the daemon's, which a direct write silently defeats.
pub fn note(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    assay.diag(fmt, args);
}
