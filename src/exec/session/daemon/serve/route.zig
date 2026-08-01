//! gist resident daemon — what the poll thread does with one readable client.
//!
//! The triage rule is a cost split. A control frame — `hello`/`status`/`ping`/
//! `changed`/`shutdown` — is a handful of bytes and a lock-free read of state
//! the poll thread already holds, so answering it inline is cheaper than any
//! handoff. A `query`/`query_ext` is an O(corpus) walk plus a response write
//! that can run to megabytes, so it goes to the worker pool (`crew.zig`) and
//! its connection leaves the poll set until the worker reports back — which is
//! what keeps one slow search from stalling the other coworkers on the daemon.
//!
//! Everything here is fail-open toward cold: an unreadable or malformed frame
//! drops the peer, an unknown verb is answered `decline`, and only an explicit
//! `shutdown` stops the daemon. A client that merely disconnects just frees the
//! slot for the next one.

const std = @import("std");
const resident = @import("irregex").session.resident;
const annals_mod = @import("irregex").inner.session.annals;
const protocol = @import("../../conduit/protocol/protocol.zig");
const image = @import("../../conduit/image.zig");
const watch = @import("irregex").session.watch;
const answer = @import("answer.zig");
const crew = @import("crew.zig");

const ResidentSession = resident.ResidentSession;

/// What routing one frame on the poll thread tells the loop to do with that
/// connection: keep it registered, drop it (closed/errored peer), stop the
/// daemon, or that the frame was dispatched to a worker (the connection left the
/// poll set and the worker will report it back through the completion queue).
pub const Route = enum { keep, drop, stop, dispatched };

/// Route ONE frame from a readable idle client on the POLL thread. Called only
/// after `poll` reported the fd readable, so the blocking `recvFrame` returns
/// promptly (a whole small request frame arrives in one segment on a local Unix
/// socket; a half-written frame from a dying peer ends as `ConnClosed` →
/// `.drop`). A `query`/`query_ext` is handed to the worker pool (`.dispatched`);
/// every cheap control frame answers inline. Returns `.stop` only on `shutdown`.
pub fn frame(server: *crew.Server, slot: u16) Route {
    const c = &server.conns[slot];
    const fd = c.stream.socket.handle;
    var f = protocol.recvFrame(server.gpa, server.io, fd) catch return .drop; // closed/oversized/bad → drop peer
    switch (f.op) {
        // The search verbs — the expensive path. With a live pool the frame's
        // ownership moves into a job and the connection leaves the poll set until
        // the worker reports back; without one (pool spawn failed) it runs inline
        // here, the classic serial shape.
        .query, .query_ext => {
            // Read-your-writes barrier, drained BEFORE dispatch: both backends
            // post their event inside the syscall that caused it (Linux inotify ·
            // macOS kqueue), so any write that completed before this request was
            // sent is already queued here and gets noted for the reconcile
            // An unarmed session reconciles fully anyway.
            _ = server.watcher.flushSync();
            if (server.pool_ready) {
                server.dispatch(slot, f); // frame ownership moves into the job
                return .dispatched;
            }
            defer f.deinit();
            answer.query(server.session, server.gpa, fd, f.payload(), c.caps, f.op == .query_ext) catch return .drop;
            return .keep;
        },
        // HELLO carries an optional caps byte after the version — latch it for
        // this connection so its queries can use fd-transport (`status` is a
        // re-handshake that never advertises, so it leaves caps untouched).
        //
        // It is also the moment to ask whether this daemon should still exist.
        // A new client dialing in is exactly when a rebuild has plausibly just
        // happened, and `image.replaced` answers it against the filesystem
        // rather than against the peer: if the executable this process is
        // running has been rewritten, the bytes it would answer from are gone.
        // Answer READY honestly first — the stamp is the boot-time one, so the
        // client declines and runs cold — then stop, freeing the socket for a
        // daemon spawned from what is on disk now. Retirement therefore needs
        // no comparison between peers, which is what keeps two live builds at
        // one rendezvous from taking turns killing each other.
        .hello => {
            defer f.deinit();
            const p = f.payload();
            c.caps = if (p.len >= 2) p[1] else 0;
            sendReady(server.session, server.gpa, fd, c.gen) catch return .drop;
            return if (image.replaced(server.io)) .stop else .keep;
        },
        .status => {
            defer f.deinit();
            sendReady(server.session, server.gpa, fd, c.gen) catch return .drop;
            return .keep;
        },
        .ping => {
            defer f.deinit();
            protocol.sendFrame(server.gpa, server.io, fd, .pong, "") catch return .drop;
            return .keep;
        },
        // The annals consult: `gist index` asking "what changed since S?".
        .changed => {
            defer f.deinit();
            handleChanged(server.session, server.watcher, server.gpa, fd, f.payload()) catch return .drop;
            return .keep;
        },
        // The answer keep. Both frames are epoch arithmetic over state the poll
        // thread already holds — no walk, no session read — so they answer
        // inline like the other control frames. A `retain` carries the caller's
        // rendered answer and is the one control frame that can be large; it is
        // still a plain memcpy off a local socket, not an O(corpus) walk.
        .recall => {
            defer f.deinit();
            handleRecall(server, fd, f.payload()) catch return .drop;
            return .keep;
        },
        .retain => {
            defer f.deinit();
            handleRetain(server, f.payload());
            return .keep;
        },
        .shutdown => {
            f.deinit();
            return .stop;
        },
        // Anything server→client, or an unknown verb, is not a request: refuse
        // it as decline so a confused client falls back cold rather than hangs.
        else => {
            defer f.deinit();
            protocol.sendFrame(server.gpa, server.io, fd, .decline, "") catch return .drop;
            return .keep;
        },
    }
}

/// Answer an annals consult only when the watcher supplies a causal barrier — an
/// unarmed or non-syscall-synchronous backend declines, and the client takes its
/// conservative journal/stat-walk fallback. Never return a partial list.
fn handleChanged(session: *ResidentSession, watcher: *watch.Watcher(ResidentSession), gpa: std.mem.Allocator, fd: std.posix.fd_t, payload: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const since_ns = protocol.decodeChanged(payload) catch {
        try protocol.encodeAnnals(&buf, gpa, null);
        if (!protocol.writeAll(session.io, fd, buf.items)) return error.ConnClosed;
        return;
    };
    var snap: ?annals_mod.Snapshot = if (watcher.flushSync())
        session.annals.since(gpa, since_ns)
    else
        null;
    defer if (snap) |*s| s.deinit(gpa);
    try protocol.encodeAnnals(&buf, gpa, if (snap) |s| .{ .prefix = s.prefix, .paths = s.paths } else null);
    if (!protocol.writeAll(session.io, fd, buf.items)) return error.ConnClosed;
}

/// The corpus change epoch, or null when the daemon cannot vouch for one — an
/// unarmed or non-syscall-synchronous watcher, or a ledger poisoned by an event
/// it could not attribute. Same causal barrier the annals consult stands on
/// The flush drains every event whose syscall completed before this
/// request was sent, so an epoch read here cannot miss a write the client's own
/// earlier run could have seen.
fn epochNow(server: *crew.Server) ?u64 {
    if (!server.watcher.flushSync()) return null;
    return server.session.annals.epoch();
}

/// Answer a `recall`: the held answer if the corpus has not moved since it was
/// computed, otherwise the current epoch for the caller to stamp its own answer
/// with. An unvouchable epoch answers `ok=0` — the client then neither trusts
/// nor feeds the keep, and simply runs cold as if no daemon existed.
fn handleRecall(server: *crew.Server, fd: std.posix.fd_t, key: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(server.gpa);
    const epoch = epochNow(server) orelse {
        try protocol.encodeRecalled(&buf, server.gpa, null);
        if (!protocol.writeAll(server.io, fd, buf.items)) return error.ConnClosed;
        return;
    };
    const found: ?protocol.Hit = switch (server.keep.recall(key, epoch)) {
        .hit => |h| .{ .code = h.code, .answer = h.answer },
        .stale, .absent => null,
    };
    try protocol.encodeRecalled(&buf, server.gpa, .{ .epoch = epoch, .hit = found });
    if (!protocol.writeAll(server.io, fd, buf.items)) return error.ConnClosed;
}

/// Take a `retain` offer. Kept only when the corpus is still at the epoch the
/// client read before it started computing — otherwise a file moved DURING the
/// computation and the answer describes a tree that no longer exists. Silent
/// either way: the client has already printed its answer and is not waiting.
fn handleRetain(server: *crew.Server, payload: []const u8) void {
    const r = protocol.decodeRetain(payload) catch return;
    const epoch = epochNow(server) orelse return;
    if (epoch != r.epoch) return;
    server.keep.retain(r.key, epoch, r.code, r.answer);
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
    try protocol.encodeReady(&buf, gpa, session.daemon_gen, session_gen, session.image, gen);
    if (!protocol.writeAll(session.io, fd, buf.items)) return error.ConnClosed;
}
