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
//! client. On completion the worker posts the connection back and nudges the
//! poll thread over a self-pipe, which re-registers the fd.
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
const resident = @import("../../../../exec/session/warm/resident.zig");
const protocol = @import("../../../../exec/session/conduit/protocol/protocol.zig");
const watch = @import("../../../../exec/session/watch/watch.zig");
const answer = @import("answer.zig");
const fault = @import("../../../../../fault.zig");
const net = std.Io.net;

const ResidentSession = resident.ResidentSession;

extern "c" fn write(fd: std.posix.fd_t, buf: [*]const u8, n: usize) isize;

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
    pub fn dispatch(self: *Server, slot: u16, frame: protocol.Frame) void {
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
    pub fn drainWake(self: *Server) void {
        var buf: [256]u8 = undefined;
        fault.spare("drain the wakeup self-pipe", std.posix.read(self.wake_r, &buf));
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
            const drop = if (answer.query(self.session, self.gpa, c.stream.socket.handle, frame.payload(), c.caps, ext)) |_|
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

/// Worker count: `GIST_SERVE_WORKERS` if a positive value is set (capped at
/// `max_clients`), else `min(cpu/2, worker_cap)`, at least one. Read once at
/// startup; the pool is fixed for the daemon's life.
pub fn configuredWorkers() usize {
    if (std.c.getenv("GIST_SERVE_WORKERS")) |s| {
        const n = std.fmt.parseInt(usize, std.mem.span(s), 10) catch 0;
        if (n > 0) return @min(n, max_clients);
    }
    const cpu = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(cpu / 2, 1, worker_cap);
}

/// Operator-facing lifecycle line on stderr. It lives beside the shared state
/// because both halves of the daemon narrate — `serve.zig` over setup and
/// teardown, `loop.zig` over reconciles, budget aborts, and idle staging — and
/// this is the one module they both already import. Silenced under `zig build
/// test`: the daemon is spawned in-process by `serve_test.zig`, and any stderr
/// from a passing unit-test binary makes the build runner dump the step tree
/// with a spurious "failed command:" banner — a green run must read green.
pub fn note(comptime fmt: []const u8, args: anytype) void {
    if (builtin.is_test) return;
    std.debug.print(fmt, args);
}
