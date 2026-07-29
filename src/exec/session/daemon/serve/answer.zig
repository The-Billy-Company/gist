//! gist resident daemon — how one `query`/`query_ext` frame becomes an answer.
//!
//! Everything past the poll thread's triage (`route.zig`): decode the request,
//! prove this daemon may serve its scope, run the session verb the request
//! selected, and write the response on the connection's own fd — from a pool
//! worker, or inline on the poll thread when no worker could spawn. Four
//! answer shapes ride out of here, and the choice is the request's, not the
//! transport's: a `--rank` ranked view, a `-q` existence flag, the default line
//! search (over shared memory when the peer advertised fd-transport and the
//! answer is big enough to pay for it), or a files/count result.
//!
//! One rule governs every failure: an unservable request comes back as
//! `decline`, never as a wrong or partial answer. The client re-runs it on the
//! certified cold path and loses a warm acceleration, nothing else.
//!
//! ## The budget
//!
//! Because a worker runs one query to completion, a single runaway scan — or
//! one a client already timed out and abandoned — would hold a worker (and,
//! under saturation, could tie up the whole pool). A per-query wall-clock
//! budget (`ResidentSession.query_budget_ns`, sampled at strided checkpoints in
//! the O(corpus) walks) bounds that: an overrun declines the query so the
//! client answers cold and the worker is reclaimed. It is a liveness backstop,
//! not a latency SLA — generous by default (`GIST_QUERY_BUDGET_MS`), so no
//! legitimate local warm query approaches it.

const std = @import("std");
const resident = @import("../../warm/resident.zig");
const protocol = @import("../../conduit/protocol/protocol.zig");
const assay = @import("../../../../assay/assay.zig");
const fault = @import("../../../../fault.zig");

const ResidentSession = resident.ResidentSession;

/// Default per-query wall-clock ceiling (see the header): a liveness backstop
/// deliberately far above any legitimate local warm query, so it only bounds a
/// runaway or abandoned scan that would otherwise pin a shared worker.
/// `GIST_QUERY_BUDGET_MS` overrides it; `0` disables the ceiling entirely.
const query_budget_ms_default: i64 = 30_000;

/// Test hook (mirrors `shm.force_fail_for_test`): a non-negative value forces
/// the per-query budget in NANOSECONDS, so a unit test can drive the abort path
/// deterministically without a giant corpus. `-1` (the default) defers to
/// `GIST_QUERY_BUDGET_MS` / `query_budget_ms_default`.
///
/// Pointer-width (an atomic may not exceed the target's largest atomic, 4 bytes
/// on 32-bit; `isize` is `i64` on every 64-bit target). The hook exists to force
/// a *tiny* budget so the abort path fires without a giant corpus, so the 32-bit
/// range — ±2.1 s expressed in nanoseconds — covers every use of it. Production
/// budgets never pass through here: `GIST_QUERY_BUDGET_MS` is parsed as `i64`
/// milliseconds and widened to `i128` nanoseconds below, untouched by this.
pub var query_budget_ns_override: std.atomic.Value(isize) = .init(-1);

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
pub fn budgetNs() i128 {
    const override = query_budget_ns_override.load(.monotonic);
    if (override >= 0) return override;
    const ms: i64 = if (std.c.getenv("GIST_QUERY_BUDGET_MS")) |s|
        std.fmt.parseInt(i64, std.mem.span(s), 10) catch query_budget_ms_default
    else
        query_budget_ms_default;
    return @as(i128, @max(ms, 0)) * std.time.ns_per_ms;
}

/// Decode + answer one query. A malformed frame, unservable request, or typed
/// warm declinature comes back as `decline` — the client re-runs it on the
/// certified cold path. OOM remains a fault and propagates. `caps` is
/// the connection's advertised transport capabilities (see `crew.Conn.caps`).
/// Runs on a pool worker (or inline when the pool is down); the session's
/// `Ward` makes concurrent workers safe.
pub fn query(session: *ResidentSession, gpa: std.mem.Allocator, fd: std.posix.fd_t, payload: []const u8, caps: u8, ext: bool) !void {
    // Test-only in-flight gate (see `query_gate_for_test`): pins this handler on
    // its worker so a test can prove the poll thread still serves other clients.
    if (query_gate_for_test.load(.acquire)) |gate| gate.waitUncancelable(session.io);
    // Capture every diagnostic this query produces (reconcile lens traces, a
    // `--rank` timing summary) off this worker's thread-local sink so it can ride
    // a `diag` frame back to the client's stderr — a warm query is otherwise
    // unmeasurable from the client. The scope is worker-thread-local; a decline
    // path just drops the buffer (the client re-runs cold and re-emits its own).
    var dbuf: std.ArrayList(u8) = .empty;
    defer dbuf.deinit(gpa);
    const sc = assay.scope(.{ .buffer = .{ .list = &dbuf, .gpa = gpa } });
    defer sc.end();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // `query_ext` carries a roots trailer whose slice headers live in the arena;
    // `query` is rootless. A malformed frame → decline (client → cold).
    const req = (if (ext) protocol.decodeQueryExt(arena.allocator(), payload) else protocol.decodeQuery(payload)) catch
        return protocol.sendFrame(gpa, session.io, fd, .decline, "");
    // Served-scope soundness: a scoped request is only answerable warm when its
    // roots are a subset of what THIS daemon mirrors — otherwise the resident
    // set is missing files cold would search, so warm could report empty where
    // cold matches. The common auto-spawned daemon is rootless (serves the whole
    // CWD tree) and admits every relative root; an explicitly-scoped daemon
    // declines a query that reaches outside its subtree.
    if (!session.servesScope(req.filter.roots))
        return protocol.sendFrame(gpa, session.io, fd, .decline, "");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    if (req.rank_k) |k| {
        // `--rank`: gist's definition-first ranked view, dispatched before the
        // mode (it overrides it). The rendered top-K rides the SAME `chunk`+
        // terminal-`result` transport as a `lines` answer, with `matched=true` so
        // the client exits 0 — cold `--rank` always exits 0 (only a path error is
        // 2, and the client's `rootsExist` gate already sent those cold).
        const bytes = switch (try session.queryRank(arena.allocator(), req, k)) {
            .got => |got| got,
            .declined => return protocol.sendFrame(gpa, session.io, fd, .decline, ""),
        };
        try protocol.encodeLines(&buf, gpa, bytes, true);
    } else if (req.quiet) {
        // `-q`: an existence-only answer regardless of the mode byte. The walk
        // halts at the first hit (`queryExists`); framed as a zero-chunk `lines`
        // result carrying just the matched flag, so the client prints nothing
        // and exits 0/1 on it. `-m0` resolves to `matched=false` inside.
        const found = switch (try session.queryExists(req)) {
            .got => |got| got,
            .declined => return protocol.sendFrame(gpa, session.io, fd, .decline, ""),
        };
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
            switch (switch (try session.queryLinesShm(arena.allocator(), req, protocol.fd_transport_floor)) {
                .got => |got| got,
                .declined => return protocol.sendFrame(gpa, session.io, fd, .decline, ""),
            }) {
                .fd => |shl| {
                    var buffer = shl.buffer;
                    defer buffer.close();
                    buffer.freeze(); // drop the daemon's writable view, seal (Linux)
                    sendDiag(gpa, session.io, fd, dbuf.items);
                    if (!protocol.sendChunkFd(fd, shl.len, shl.matched, buffer.fd)) return error.ConnClosed;
                    return;
                },
                .chunk => |chnk| {
                    try protocol.encodeLines(&buf, gpa, chnk.bytes, chnk.matched);
                    sendDiag(gpa, session.io, fd, dbuf.items);
                    if (!protocol.writeAll(session.io, fd, buf.items)) return error.ConnClosed;
                    return;
                },
            }
        }
        const ans = switch (try session.queryLines(arena.allocator(), req)) {
            .got => |got| got,
            .declined => return protocol.sendFrame(gpa, session.io, fd, .decline, ""),
        };
        try protocol.encodeLines(&buf, gpa, ans.out, ans.matched);
    } else {
        const result = switch (try session.query(arena.allocator(), req)) {
            .got => |got| got,
            .declined => return protocol.sendFrame(gpa, session.io, fd, .decline, ""),
        };
        switch (result.mode) {
            .files => try protocol.encodeFiles(&buf, gpa, result.files),
            .count => try protocol.encodeCount(&buf, gpa, result.count),
            .lines => unreachable, // routed above
        }
    }
    sendDiag(gpa, session.io, fd, dbuf.items);
    if (!protocol.writeAll(session.io, fd, buf.items)) return error.ConnClosed;
}

/// Ship a warm query's captured diagnostics ahead of its answer as a `diag`
/// frame, so the client can relay them to its stderr. Best-effort: a lost diag
/// (dead peer, oversized) never fails the answer — the client's exit code and
/// stdout are the contract, the timing line is advisory. Empty → nothing sent.
fn sendDiag(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, bytes: []const u8) void {
    if (bytes.len == 0 or bytes.len > protocol.max_frame) return;
    fault.spare("ship warm diagnostics to the client", protocol.sendFrame(gpa, io, fd, .diag, bytes));
}
