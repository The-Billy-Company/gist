//! gist resident client — the CLI's warm fast path.
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
//! `--rank[=N]` — gist's definition-first ranked view, the one shape rg can't
//! express — is served warm too: the daemon ranks over resident bytes and
//! streams the rendered top-K on the same transport as a `lines` answer,
//! exiting 0 as cold `--rank` always does.
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
const builtin = @import("builtin");
const request = @import("irregex").session.request;
const protocol = @import("../../conduit/protocol/protocol.zig");
const image = @import("../../conduit/image.zig");
const shm = @import("irregex").inner.session.shm;
const corpus = @import("irregex").corpus;
const frame = @import("irregex").inner.corpus.frame;
const beacon = @import("irregex").inner.cli.beacon;
const run = @import("irregex").commands.search;
const assay = @import("irregex").assay;
const portal = @import("irregex").portal;
const vigil = @import("../../conduit/vigil.zig");
const rendezvous = @import("../../conduit/rendezvous.zig");
const net = std.Io.net;

/// Transport capabilities this client advertises in HELLO — `caps_supported`
/// unless `GIST_NO_FD_TRANSPORT` is set, which suppresses fd-transport so the
/// emit-heavy answer streams as classic `chunk` frames. That knob is the
/// operational fail-open switch (disable the zero-copy path without a rebuild)
/// and how the byte-parity gate A/Bs warm-fd against warm-chunk on one binary;
/// it follows the `GIST_NO_PARALLEL` idiom and is never a CLI flag.
fn advertisedCaps() u8 {
    return if (assay.envSpan("GIST_NO_FD_TRANSPORT") != null) 0 else protocol.caps_supported;
}

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
/// timed out / poll error — caller falls through to cold. Prefer a readiness wait
/// over `SO_RCVTIMEO`: the latter's `timeval` ABI is easy to get wrong across
/// libc cuts, and a silent setsockopt failure used to leave the CLI blocked
/// forever.
///
/// This is the whole guard against a wedged daemon hanging the CLI, which is why
/// it goes through `vigil` rather than `portal.readable`: the latter answers an
/// optimistic `true` on Windows, correctly, for the one caller it has there (a
/// unix socket cannot be that process's stdin) — and answering it here would put
/// the hang back.
fn waitReadable(fd: std.posix.fd_t, timeout_ms: i32) bool {
    return vigil.readable(fd, timeout_ms);
}

/// Receive one frame, but never block longer than `client_io_timeout_ms`.
pub fn recvFrameDeadline(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, timeout_ms: i32) !protocol.Frame {
    if (!waitReadable(fd, timeout_ms)) return error.TimedOut;
    return protocol.recvFrame(gpa, io, fd);
}

/// Like `recvFrameDeadline`, but over `recvmsg` so a `chunk_fd` answer's passed
/// shm fd is captured (null for every other frame). Used for the query response
/// once we've advertised `cap_fd_transport`.
fn recvFdFrameDeadline(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, timeout_ms: i32) !protocol.FdFrame {
    if (!waitReadable(fd, timeout_ms)) return error.TimedOut;
    return protocol.recvFrameWithFd(gpa, io, fd);
}

/// True only if every scope root resolves on disk from the CWD (the tree cold
/// walks). A missing root is not "no matches": cold reports it as an error and
/// exits 2, so the warm path must decline and let cold own that outcome.
fn rootsExist(io: std.Io, roots: []const []const u8) bool {
    for (roots) |r| std.Io.Dir.cwd().access(io, r, .{}) catch return false;
    return true;
}

/// Is the daemon on the other end resident over the tree we are standing in?
/// The socket lives in the artifact directory, so an absolute `GIST_DIR` shared
/// by two checkouts points both at one rendezvous — and a warm answer names
/// files by paths that resolve in either, so the mix-up is invisible in the
/// output. Every daemon records its tree beside its socket at bind time
/// (`serve.run`), which makes this the same proof `frame.boundHere` runs for
/// the persisted artifacts. Fails CLOSED: an unwritten or unreadable binding
/// answers cold, which is always correct.
fn rendezvousIsOurs(socket_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return frame.bindingHolds(frame.socketBindingPath(&buf, socket_path) orelse return false);
}

/// Try to answer `argv` warm. Never errors: any failure is `.cold`.
pub fn attempt(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, socket_path: []const u8) Outcome {
    return attemptWithDeadline(gpa, io, argv, socket_path, client_io_timeout_ms);
}

fn attemptWithDeadline(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, socket_path: []const u8, timeout_ms: i32) Outcome {
    // `sa` backs `req.filter.roots` (aliases into argv) and must outlive the
    // whole attempt — it lives on this frame across `exchange` below.
    var sa: request.ScopeArgs = .{};
    const req = request.classify(argv, &sa) catch return .cold;
    // A scope root the cold engine would fail to open (a typo'd PATH) must reach
    // cold so it emits rg's exit-2 "No such file or directory" — the warm mirror
    // would otherwise silently prune the unknown root to an exit-1 "no match",
    // which reads to a caller like a crash on a typo. Stat each root against the
    // same CWD cold walks; any miss → cold. Only the (rare) scoped path pays it.
    if (!req.filter.isEmpty() and !rootsExist(io, req.filter.roots)) return .cold;
    // The wire count is a corpus-wide total; rg's `-c` is per-file — cold owns
    // it. But `-q` overrides the mode entirely (it answers existence, prints
    // nothing), so a quiet `-c`/`-l`/bare query is all served warm below.
    if (req.mode == .count and !req.quiet) return .cold;
    // Cold's interactive presentation (color, TTY long-line cap) is out of the
    // daemon's piped-frame envelope — the certified path owns the terminal.
    // Same detection cold's `--color auto` resolution uses (run.zig).
    if (std.Io.File.stdout().isTty(io) catch false) return .cold;
    // Clickable rows are cold's too, for the same reason: the daemon renders a
    // frame with no beacon in it. The TTY test above already covers every
    // hyperlink posture but one — `GIST_HYPERLINK=always` into a pipe.
    if (beacon.forcesLinks(gpa)) return .cold;

    if (!rendezvousIsOurs(socket_path)) return .cold;

    const ua = rendezvous.address(socket_path) catch return .cold;
    const stream = ua.connect(io) catch return .cold; // no daemon → cold
    defer stream.close(io);
    const fd = stream.socket.handle;

    // A readable stdin makes this a STREAM search cold — the tree daemon must
    // decline. Checked after the dial so a daemonless query never pays the
    // FIFO poll (`readableStdin` may wait up to its short poll window).
    if (run.readableStdin()) return .cold;

    return exchange(gpa, io, fd, req, image.stamp(io), timeout_ms) catch .cold;
}

/// We are about to answer cold because the resident daemon speaks an OLDER wire
/// version. Ask it to stop on the way out, so the warm tier is not stranded:
/// the daemon's idle TTL wants ten *continuous* minutes of quiet, which a tree
/// with ~10 coworker agents querying it never gets, and one release would
/// otherwise mean cold queries for the rest of the day.
///
/// `we_are_newer` is a strict order rather than "we disagree", because a
/// symmetric rule oscillates: an old shell and a new one would take turns
/// killing each other's daemons all afternoon. The protocol version is a real
/// order — it only ever counts up in source — so one-directional here converges
/// after a single cold query, and the next eligible one auto-spawns from the
/// binary that won.
///
/// BUILD skew routes here too, through `image.hosts` rather than through any
/// claim about recency. A build stamp is an identity and not an order
/// (`image.zig`), so `hosts` uses it only as a **tiebreak**: both sides pick the
/// same winner from the same pair, which converges for the same reason the
/// version order does. Self-retirement alone is not enough, because a daemon
/// exec'd from a content-addressed build artifact can never observe its own
/// executable being replaced — see `image.hosts` for the measured failure.
///
/// Best-effort throughout: the frame is fire-and-forget (the daemon stops its
/// loop on receipt, with nothing to read back) and a failed write is ignored.
/// Either way the caller's answer is the certified cold one.
fn retireIfSuperseded(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, we_are_newer: bool) void {
    if (we_are_newer) protocol.sendFrame(gpa, io, fd, .shutdown, "") catch {};
}

/// The peer's wire version, read straight off READY rather than through
/// `decodeReady` — every version this protocol has ever had puts it in byte
/// zero, and the decoder can only parse the layout it was compiled for. That
/// distinction is what lets an older daemon be *retired* instead of merely
/// declined: the version is an order, so "lower" means "superseded", and a
/// payload we cannot otherwise parse still answers the one question that
/// matters. `null` for an empty payload — a peer that says nothing is not one
/// we get to judge.
fn peerProtocol(payload: []const u8) ?u8 {
    return if (payload.len == 0) null else payload[0];
}

/// What is resident at the rendezvous, judged from THIS binary. The three
/// states are the three answers to "will my next eligible query land warm?"
pub const Residency = enum {
    /// Nothing is listening. The next eligible query runs cold and forks one.
    none,
    /// A daemon answered, on this wire version and this build: warm is live.
    ours,
    /// A daemon answered that this binary will not use — another build,
    /// another wire version, or a rendezvous bound to another tree. Every
    /// eligible query runs cold until it is retired, and nothing about the
    /// answers says so, which is exactly why status has to.
    foreign,
};

/// Deadline for the residency probe. A report is worth waiting a moment for
/// but never worth blocking on: a daemon too wedged to say hello inside this
/// window is not one that will answer a query either, and `foreign` is the
/// honest thing to print about it.
const residency_timeout_ms: i32 = 500;

/// Ask what is resident, for a report rather than for an answer: this never
/// spawns a daemon and never retires one. Introspection that changed the world
/// it describes would make the second run of `gist status` disagree with the
/// first for no reason the reader could see. (It does open one connection, so
/// a resident daemon's idle TTL is nudged — the one unavoidable trace.)
pub fn residency(gpa: std.mem.Allocator, io: std.Io, socket_path: []const u8) Residency {
    const ua = rendezvous.address(socket_path) catch return .none;
    const stream = ua.connect(io) catch return .none; // nothing listening
    defer stream.close(io);
    // Ordered after the dial on purpose: the binding file is also absent when
    // no daemon has ever run here, and reporting *that* as a foreign resident
    // would be its own false alarm.
    if (!rendezvousIsOurs(socket_path)) return .foreign;
    return probeReady(gpa, io, stream.socket.handle, image.stamp(io)) catch .foreign;
}

/// The handshake half of `residency`, over `status` rather than `hello`: the
/// re-handshake frame latches no capabilities and — the part that matters here
/// — is not the daemon's cue to re-examine its own executable, so a report
/// cannot be what ends a daemon's life. Otherwise the same two judgements
/// `exchange` makes before it will trust a peer with a query.
fn probeReady(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, mine: u64) !Residency {
    try protocol.sendFrame(gpa, io, fd, .status, "");
    var ready = try recvFrameDeadline(gpa, io, fd, residency_timeout_ms);
    defer ready.deinit();
    if (ready.op != .ready) return .foreign;
    if ((peerProtocol(ready.payload()) orelse return .foreign) != protocol.protocol_version) return .foreign;
    const r = protocol.decodeReady(ready.payload()) catch return .foreign;
    return if (image.agrees(mine, r.image)) .ours else .foreign;
}

/// Test-only seam for exercising fail-open behavior without spending the
/// production two-second budget in a scheduler-sensitive wall-clock assertion.
pub const test_api = if (builtin.is_test) struct {
    pub fn attemptWithin(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, socket_path: []const u8, timeout_ms: i32) Outcome {
        return attemptWithDeadline(gpa, io, argv, socket_path, timeout_ms);
    }
    /// The skew exit, reachable without two differently-dated binaries.
    pub fn retireOn(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, we_are_newer: bool) void {
        retireIfSuperseded(gpa, io, fd, we_are_newer);
    }
    pub const peerProtocolOf = peerProtocol;
} else struct {};

/// One request/response over an open connection: handshake, send the query, and
/// emit the answer — a `result(files)` frame becomes the sorted path list; a
/// chunk-streamed `lines` answer buffers every `chunk` frame and emits on the
/// terminal `result(lines)` frame (buffer-then-emit keeps the fallback atomic:
/// nothing reaches stdout unless the whole warm answer arrived, so a mid-stream
/// wire failure still degrades to a clean cold run with no duplicated output).
/// A `decline`/`err` frame (or any wire error / deadline) propagates so
/// `attempt` degrades to cold.
fn exchange(gpa: std.mem.Allocator, io: std.Io, fd: std.posix.fd_t, req: request.Request, mine: u64, timeout_ms: i32) !Outcome {
    // Handshake: HELLO → READY. The second HELLO byte advertises our transport
    // capabilities (`cap_fd_transport` on a supported target); an old daemon
    // ignores it and simply never sends `chunk_fd`. A daemon speaking another
    // protocol version is not one we can trust to frame-match, so bail to cold.
    // Nor is one running a different BUILD: it frames identically and answers
    // from an engine this binary no longer shares, which is the shape a search
    // tool may never take — a well-formed answer carrying superseded bytes.
    try protocol.sendFrame(gpa, io, fd, .hello, &.{ protocol.protocol_version, advertisedCaps() });
    {
        var ready = try recvFrameDeadline(gpa, io, fd, timeout_ms);
        defer ready.deinit();
        if (ready.op != .ready) return .cold;
        const proto = peerProtocol(ready.payload()) orelse return .cold;
        if (proto != protocol.protocol_version) {
            retireIfSuperseded(gpa, io, fd, proto < protocol.protocol_version);
            return .cold;
        }
        const r = protocol.decodeReady(ready.payload()) catch return .cold;
        // A build we do not share. Our HELLO already prompted it to re-check its
        // own executable, which retires it whenever that file was rewritten —
        // but a daemon exec'd from a content-addressed build artifact has no
        // such file to lose, so that check can never fire and it would hold the
        // rendezvous for the rest of the day. `image.hosts` settles it instead,
        // as a tiebreak both sides compute identically (see `image.zig`).
        if (!image.agrees(mine, r.image)) {
            retireIfSuperseded(gpa, io, fd, image.hosts(mine, r.image));
            return .cold;
        }
    }

    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    // A rootless, non-rank, windowless, non-`-P` request rides the classic
    // `query`; a scoped OR `--rank` OR `-A`/`-B`/`-C` OR `-P` one rides
    // `query_ext`, whose trailer carries the `PathFilter`, the rank top-k, the
    // context window, and the PCRE2 engine bit (the classic `query` has no
    // trailer room — the flags byte is full — so `-P` must ride `query_ext`).
    if (req.filter.isEmpty() and req.rank_k == null and req.before == 0 and req.after == 0 and !req.pcre)
        try protocol.encodeQuery(&qbuf, gpa, req)
    else
        try protocol.encodeQueryExt(&qbuf, gpa, req);
    if (!protocol.writeAll(io, fd, qbuf.items)) return .cold;

    var lines_out: std.ArrayList(u8) = .empty;
    defer lines_out.deinit(gpa);
    while (true) {
        const got = try recvFdFrameDeadline(gpa, io, fd, timeout_ms);
        var resp = got.frame;
        defer resp.deinit();
        // Only `chunk_fd` legitimately carries an fd; a stray one on any other
        // frame must be closed here rather than leaked.
        errdefer if (got.passed_fd) |p| {
            _ = std.c.close(p);
        };
        switch (resp.op) {
            // The daemon's per-query diagnostics (timing summary / lens traces),
            // captured warm and relayed to this client's stderr verbatim — so a
            // warm query reports the same timing a cold one prints. Arrives ahead
            // of the answer frames; keep reading for the result.
            .diag => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                std.debug.print("{s}", .{resp.payload()});
            },
            // A `lines` answer streams as chunks; accumulate until the terminal
            // result frame. (An old v1 daemon never emits `chunk` — it declines
            // the unknown mode byte first — so this arm is dead against it.)
            .chunk => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                try lines_out.appendSlice(gpa, resp.payload());
            },
            // Zero-copy terminal `lines` answer: the bytes live in the passed shm
            // fd, not the socket. mmap read-only straight to stdout. Chunks before
            // it are a protocol violation → cold (fail-open).
            .chunk_fd => {
                const cf = protocol.decodeChunkFd(resp.payload()) catch return .cold;
                const shm_fd = got.passed_fd orelse return .cold;
                return emitFd(shm_fd, cf.length, cf.matched, lines_out.items.len);
            },
            .result => {
                if (got.passed_fd) |p| _ = std.c.close(p);
                const view = protocol.decodeResult(resp.payload()) catch return .cold;
                return switch (view) {
                    // Chunks before a files/count result are a protocol violation.
                    .files => |files_iter| if (lines_out.items.len > 0) .cold else emitFiles(gpa, files_iter),
                    // `-q` answers as a zero-chunk `lines` frame: print NOTHING,
                    // exit 0/1 on the matched flag alone (rg's quiet contract).
                    .lines => |matched| if (req.quiet) Outcome{ .served = if (matched) 0 else 1 } else emitRaw(lines_out.items, matched),
                    .count => .cold, // CLI never emits count warm (see file header)
                };
            },
            else => return .cold, // decline / err → cold
        }
    }
}

/// Deadline for the `gist index` annals consult — tighter than a query's
/// 2 s: the consult's whole point is out-running the ~10 ms journal replay
/// and the ~100 ms stat walk, so a daemon too busy to answer inside this
/// window is answered by the fallback instead of waited on.
pub const changed_timeout_ms: i32 = 500;

/// A vouched annals answer: the daemon's armed absolute watch prefix (the
/// caller verifies it names ITS repo root) + the repo-relative changed paths.
/// Everything is allocated from the caller's arena.
pub const ChangedAnswer = struct { prefix: []const u8, paths: []const []const u8 };

/// Ask the resident daemon which corpus files changed at/after `since_ns`
/// (the amend's `base.ns` anchor). Null on ANY uncertainty — no daemon,
/// version skew, decline, truncation, deadline — so the caller runs its
/// proven fallback (journal replay → stat walk). Never errors, never spawns;
/// output lives in `a` (the caller's arena).
pub fn consultChanged(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, socket_path: []const u8, since_ns: i64) ?ChangedAnswer {
    const ua = rendezvous.address(socket_path) catch return null;
    const stream = ua.connect(io) catch return null; // no daemon → fallback
    defer stream.close(io);
    return exchangeChanged(gpa, io, a, stream.socket.handle, image.stamp(io), since_ns) catch null;
}

fn exchangeChanged(gpa: std.mem.Allocator, io: std.Io, a: std.mem.Allocator, fd: std.posix.fd_t, mine: u64, since_ns: i64) !?ChangedAnswer {
    // Same HELLO → READY handshake as a query (no transport caps — the answer
    // is small). A version-skewed daemon would `UnexpectedFrame`-drop the `changed`
    // frame, so the mismatch bails here first — as does a build skew, whose
    // answer would be a changed-set computed by a different watcher.
    try protocol.sendFrame(gpa, io, fd, .hello, &.{ protocol.protocol_version, 0 });
    {
        var ready = try recvFrameDeadline(gpa, io, fd, changed_timeout_ms);
        defer ready.deinit();
        if (ready.op != .ready) return null;
        const proto = peerProtocol(ready.payload()) orelse return null;
        if (proto != protocol.protocol_version) {
            retireIfSuperseded(gpa, io, fd, proto < protocol.protocol_version);
            return null;
        }
        const r = protocol.decodeReady(ready.payload()) catch return null;
        // Same build-skew handover as `exchange`: an answer computed by another
        // build's watcher is not one this amend may fold in, and a daemon whose
        // executable cannot be rewritten never retires itself.
        if (!image.agrees(mine, r.image)) {
            retireIfSuperseded(gpa, io, fd, image.hosts(mine, r.image));
            return null;
        }
    }
    var qbuf: std.ArrayList(u8) = .empty;
    defer qbuf.deinit(gpa);
    try protocol.encodeChanged(&qbuf, gpa, since_ns);
    if (!protocol.writeAll(io, fd, qbuf.items)) return null;

    var resp = try recvFrameDeadline(gpa, io, fd, changed_timeout_ms);
    defer resp.deinit();
    if (resp.op != .annals) return null;
    const view = (protocol.decodeAnnals(resp.payload()) catch return null) orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    var it = view.paths;
    while (it.next() catch return null) |p| try out.append(a, try a.dupe(u8, p));
    return .{ .prefix = try a.dupe(u8, view.prefix), .paths = try out.toOwnedSlice(a) };
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
        out.print(gpa, "{s}\n", .{path}) catch return .cold;
    }
    if (out.items.len > 0) _ = corpus.writeStdout(out.items);
    return .{ .served = if (any) 0 else 1 };
}

/// Emit a fully-assembled pre-rendered `lines` answer (the daemon already
/// produced cold's exact bytes, path-sorted) and return rg's exit code. Bounded
/// by `writeStdoutCapped`, not a raw `writeStdout`: the whole answer is one
/// buffer, so the soft agent-context guard must be applied HERE (at a whole-line
/// boundary) rather than trusting the per-fragment straddle — otherwise a warm
/// hit dumps the firehose a daemon-less cold run would have truncated.
fn emitRaw(bytes: []const u8, matched: bool) Outcome {
    if (bytes.len > 0) _ = corpus.writeStdoutCapped(bytes);
    return .{ .served = if (matched) 0 else 1 };
}

/// Emit a zero-copy `lines` answer: `mmap` the passed shm fd read-only for
/// exactly `length` bytes and write it to stdout in one shot, so the answer
/// bytes never traversed the socket. Owns `shm_fd` (always closed here). Any
/// mmap failure → `.cold` (fail-open; the caller re-runs cold, nothing emitted).
/// The bytes are byte-identical to what the `chunk` stream would have carried.
fn emitFd(shm_fd: std.posix.fd_t, length: u64, matched: bool, prior_chunks: usize) Outcome {
    defer _ = std.c.close(shm_fd);
    if (prior_chunks != 0) return .cold; // chunks before a chunk_fd is a protocol violation
    const len: usize = @intCast(length);
    if (len == 0) return .{ .served = if (matched) 0 else 1 }; // empty answer; nothing to map
    const view = switch (shm.mapReadonly(shm_fd, len)) {
        .declined => return .cold, // no mapped view here — re-ask cold, byte-identical
        .got => |v| v,
    };
    defer shm.unmap(view);
    // Same soft-cap bound as `emitRaw` — the mapped answer is one buffer, so the
    // guard is applied here at a whole-line boundary (see `writeStdoutCapped`).
    _ = corpus.writeStdoutCapped(view[0..len]);
    return .{ .served = if (matched) 0 else 1 };
}
