//! gist resident daemon — the readiness-multiplexed accept loop.
//!
//! One wait set over three kinds of handle: the listener, the worker bell, and
//! every currently-idle client. An in-flight connection is off the set entirely
//! (its worker owns the handle), so one long query never blocks a new connection
//! or another client's probe, and an idle persistent client never starves an
//! arriving one. Each wakeup drains completions, serves one frame per readable
//! client (`route.zig`), and accepts at most one connection — routing only; the
//! session's correctness lives in `exec/session/`.
//!
//! The wait is `conduit/vigil.zig`, which is `poll(2)` on POSIX and AFD's
//! `IOCTL_AFD_POLL` on Windows. Both answer the same question in the same
//! vocabulary, which is why this loop has no platform arm of its own.
//!
//! It is also where the daemon watches itself. The reconcile and budget-abort
//! counters a worker may have bumped are sampled here and surfaced as one
//! operator line on change, and the two-stage idle policy (`idle.zig`) is
//! applied here because this is the only place with a quiescent window: zero
//! connections and nothing in flight, the same condition the boot arm ran in,
//! which is what keeps the watcher single-consumer without a lock. A fired idle
//! deadline is the only way out of the loop besides a `shutdown` frame or a
//! dead listener.
//!
//! The annals seed lives here for the same reason: coverage begins at boot and
//! begins again after every re-arm, and both moments are windows this loop owns.

const std = @import("std");
const idle = @import("idle.zig");
const crew = @import("crew.zig");
const route = @import("route.zig");
const vigil = @import("../../conduit/vigil.zig");
const fresh = @import("irregex").fresh;
const journal = @import("irregex").inner.corpus.journal;
const net = std.Io.net;
const Dir = std.Io.Dir;

/// Serve until the daemon goes idle past its TTL, a client sends `shutdown`, or
/// the listener dies. Owns nothing: `serve.run` built the session, the watcher,
/// the socket, and the worker pool, and unwinds them after this returns.
pub fn run(server: *crew.Server, listener: *net.Server) void {
    const io = server.io;
    const session = server.session;
    const watcher = server.watcher;

    // Boot-seed the annals before the first accept — the socket is already
    // bound, but nothing is read off it until this loop starts, so no consult
    // can precede the seed.
    seedAnnals(server);

    // The set is rebuilt every wakeup but never grows past its ceiling — the
    // listener, the bell, and at most `crew.max_clients` idle clients — so it
    // lives on the stack rather than costing an allocation per wakeup.
    var watches: [vigil.max_watched]vigil.Watch = undefined;
    var slots: [vigil.max_watched]u16 = undefined;
    var keeper = vigil.Vigil.open() catch |e| {
        crew.note("gist serve: cannot open the readiness device ({t}) — standing down, queries answer cold\n", .{e});
        return;
    };
    defer keeper.close();

    var session_gen: u64 = 0;
    var last_scoped: u64 = 0;
    var last_full: u64 = 0;
    var last_aborts: u64 = 0;
    // The two-stage idle policy (`idle.zig`). `idle_since` is null while anyone
    // is connected, so `nextStep` always measures CONTINUOUS idleness.
    var watch_set: idle.WatchSet = idle.settle(watcher.held());
    var idle_since: ?i64 = null;
    serve_loop: while (true) {
        server.drainCompletions();

        // Sample the (atomic) reconcile/abort counters a worker may have bumped
        // and surface a one-line operator note on any change.
        const scoped = session.scoped_reconciles.load(.monotonic);
        const full = session.full_reconciles.load(.monotonic);
        if (scoped != last_scoped or full != last_full) {
            last_scoped = scoped;
            last_full = full;
            crew.note("gist serve: reconciled (scoped={d} full={d})\n", .{ last_scoped, last_full });
        }
        const aborts = session.budget_aborts.load(.monotonic);
        if (aborts != last_aborts) {
            last_aborts = aborts;
            crew.note("gist serve: query exceeded budget → declined cold (total {d})\n", .{aborts});
        }

        // Slots 0 and 1 are the listener and the bell, by position, for the whole
        // loop; every entry after them is one idle client and `slots` says which.
        watches[0] = .{ .handle = listener.socket.handle };
        watches[1] = .{ .handle = server.bell.ear() };
        var watched: usize = 2;
        var live: usize = 0;
        for (&server.conns, 0..) |*c, i| {
            if (c.state == .free) continue;
            live += 1; // active OR in-flight: a query in flight still pins the session
            if (c.state != .active) continue; // in-flight: owned by a worker, not watched
            watches[watched] = .{ .handle = c.stream.socket.handle };
            slots[watched] = @intCast(i);
            watched += 1;
        }
        const set = watches[0..watched];

        // The idle clock runs only with nothing connected AND nothing in flight:
        // a connected (even quiet) client, or a running query, keeps the session
        // whole. Idle, the daemon gives resources back in stages — the watch set
        // first (descriptors the whole machine shares), the session itself last.
        var step: ?idle.Step = null;
        const timeout: i32 = if (live != 0) blk: {
            idle_since = null;
            break :blk -1;
        } else blk: {
            const now: i64 = @intCast(@divTrunc(std.Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
            const since = idle_since orelse s: {
                idle_since = now;
                break :s now;
            };
            const plan = idle.nextStep(watch_set, now - since);
            step = plan;
            break :blk plan.in_ms;
        };
        const ready = keeper.wait(set, timeout) catch break;
        // A fired idle deadline is the only way out of this loop besides a
        // `shutdown` frame or a dead listener. Shedding and re-arming both run
        // HERE — with zero connections and nothing in flight, the same quiescent
        // window the boot arm ran in, so the watcher stays single-consumer.
        if (ready == 0) switch ((step orelse break).act) {
            .exit => break,
            .shed => {
                const n = watcher.held();
                watcher.shed();
                watch_set = .released;
                crew.note("gist serve: idle — released {d} watch descriptors (reconcile-always until re-armed)\n", .{n});
            },
            .rearm => {
                watcher.start();
                watch_set = idle.settle(watcher.held());
                // The ledger's live coverage restarts at this instant, so replay
                // the journal back over the shed window exactly as at boot —
                // otherwise a `changed` consult would decline for a gap the OS
                // can still account for.
                seedAnnals(server);
                crew.note("gist serve: re-armed after idle ({d} watch descriptors, exact dirty log {s})\n", .{
                    watcher.held(),
                    if (session.dirty_log.exact) "on" else "off",
                });
            },
        };

        if (set[1].ready.readable) server.drainWake();

        // Serve every readable idle client (one frame each). A query dispatches
        // to the pool (the connection leaves the poll set until its worker
        // reports back); everything else answers inline right here.
        for (set[2..], slots[2..watched]) |watch, slot| {
            if (!watch.ready.any()) continue;
            switch (route.frame(server, slot)) {
                .keep, .dispatched => {},
                .drop => {
                    server.conns[slot].stream.close(io);
                    server.conns[slot].state = .free;
                },
                .stop => break :serve_loop,
            }
        }

        if (set[0].ready.readable) {
            const stream = listener.accept(io) catch break;
            // Somebody is back: a shed watch set has become worth re-registering
            // (once this burst goes quiet again — never in front of this query,
            // which answers on the baseline meanwhile).
            if (watch_set == .released) watch_set = .wanted;
            if (server.freeSlot()) |slot| {
                session_gen +%= 1;
                server.conns[slot] = .{ .stream = stream, .gen = session_gen, .state = .active };
            } else {
                stream.close(io); // over cap → the client answers cold
            }
        }
    }
}

/// Seed the session's annals: replay the persisted FSEvents journal token (the
/// same one the one-shot amend would replay itself) and deposit each surviving
/// file with its LIVE max(mtime, ctime) — the exact quantity the stat walk
/// compares — then extend coverage back to the token's mint instant. A `gist
/// index` amend asks "changed since base.ns" — an instant that usually PREDATES
/// this daemon — which is why the replay is needed at all. Gated on the
/// per-file-exact watcher being live (`dirty_log.exact`): seeding must never
/// make the ledger answerable for a window no live stream is covering forward
/// from. Every failure returns with coverage unextended — sound, just younger,
/// and the client falls back to its own replay/walk.
fn seedAnnals(server: *crew.Server) void {
    if (comptime !journal.supported) return;
    const gpa = server.gpa;
    const io = server.io;
    const session = server.session;
    if (!session.dirty_log.exact) return; // no live exact stream → never extend
    const tok = fresh.readJournalToken(gpa, io) orelse return;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var entries: std.ArrayList(journal.Entry) = .empty;
    // Rootless daemon semantics: the annals cover the whole CWD tree, so the
    // replay runs over `.` regardless of served roots (a scoped daemon's
    // annals prefix won't match the amend's CWD check anyway).
    if (!journal.replay(gpa, io, &.{"."}, tok, journal.boot_budget_ns, arena.allocator(), &entries)) return;
    for (entries.items) |e| {
        if (e.is_dir) continue;
        const ts: i128 = if (Dir.cwd().statFile(io, e.path, .{ .follow_symlinks = false })) |st|
            @max(st.mtime.nanoseconds, st.ctime.nanoseconds)
        else |_|
            std.Io.Clock.now(.real, io).nanoseconds; // vanished: conservatively "now"
        if (!session.annals.seed(e.path, ts)) return; // OOM/cap: abort WITHOUT extending
    }
    session.annals.extendCoverage(tok.captured_ns);
    crew.note("gist serve: annals seeded ({d} replayed entries, coverage from token)\n", .{entries.items.len});
}
