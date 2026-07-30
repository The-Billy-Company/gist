//! The per-line faces — the in-process FFI's record stream (ADR-352 rung 3) and
//! the `-q` existence probe, plus rg's line model that both walk.
//!
//! Everything above this file answers in whole documents; everything here
//! answers in lines, so `LineWalk` is the single line-splitting authority all of
//! it shares. `\n` TERMINATES a line — a body ending in `\n` has no phantom
//! final line — and because the probe, the record stream, the context planner,
//! and `corpus.gatedLineCount` all count that same split, none of them can drift
//! from the others by re-deriving the walk locally.
//!
//! The two faces sit here together because `-q` IS a stream that stops at its
//! first record: `search` delegates to `queryExists` when the request is quiet,
//! and the probe's early halt (the `Exister` raising `stop`, abandoning the rest
//! of the corpus unscanned) is the whole quiet win.
//!
//! Above the shared byte floor the record stream shards the expensive per-line
//! span scan across cores and feeds the real sink serially in doc order, so the
//! stream is byte-identical and stops at the same record as the serial loop.

// The caller's streaming sink for `search` — the FFI's no-stdout, no-exit
// output channel. Any pointer type `*Sink` with a `pub fn emit(self: *Sink,
// rec: MatchRecord) bool` method qualifies (checked at the `search`/`emitDoc`
// call site, comptime-monomorphized — no vtable, no `*anyopaque`, no reverse
// pointer cast). `emit` is invoked once per matching line, synchronously,
// under the session lock; it must not re-enter the session. It returns `true`
// to STOP the stream early (the caller has enough — a bound, a first hit, its
// own abort) or `false` to keep receiving lines; a stop leaves the corpus
// otherwise unscanned, so bounded queries cost only what they read.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const render = @import("render.zig");
const parallel = @import("../../../kernel/math/parallel.zig");
const query_mod = @import("../../../kernel/query/query.zig");
const answer = @import("../answer/answer.zig");
const gather = @import("../answer/gather.zig");
const reconcile = @import("../reconcile/reconcile.zig");
const resident = @import("../warm/resident.zig");
const ResidentSession = resident.ResidentSession;
const DocRef = answer.DocRef;
const MatchRecord = answer.MatchRecord;
const QueryError = answer.QueryError;
const Request = resident.Request;
const CompiledQuery = query_mod.CompiledQuery;
const MatchScratch = query_mod.MatchScratch;
const Scratch = query_mod.Scratch;
const Span = query_mod.Span;

/// Answer an eligible `-q`/`--quiet` request: does ANY line match, anywhere
/// in the corpus? rg's `-q` prints nothing and exits 0 the instant the first
/// match is found (else 1) — so this is an EARLY-HALTING existence walk: the
/// `Exister` visitor raises `stop` on its first hit and `gather.eachCandidate`
/// abandons the rest of the corpus unscanned. That short-circuit IS the warm
/// win (a bounded prefix instead of the whole tree). Binary/empty handling
/// mirrors cold's `anyMatch` (an implicit-binary file is skipped whole, not
/// pre-NUL sliced like `-l`); off the watcher-clean path the first hit is
/// existence-checked so a just-deleted file never fabricates a match. No
/// arena: only a boolean crosses back. `-m0` short-circuits to `false`.
pub fn queryExists(self: *ResidentSession, req: Request) QueryError!answer.Answer(bool) {
    if (req.matchNothing()) return .{ .got = false }; // `-m0` (see `fold.query`)
    var tripped: std.atomic.Value(bool) = .init(false);
    var held = switch (try self.beginRead(&tripped)) {
        .got => |h| h,
        .declined => |d| return .{ .declined = d },
    };
    defer held.lease.release();
    switch (try reconcile.guardExtras(self, &held, req)) {
        .got => {},
        .declined => |d| return .{ .declined = d },
    }
    const ceil = held.ceil;

    var cq = switch (try gather.compileFor(self, req, .files)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    }; // the whole-doc gate is all `-q` needs
    defer cq.deinit(self.gpa);
    var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
    defer sc.deinit();

    var msc = cq.matchScratch(self.gpa) catch return QueryError.OutOfMemory;
    defer msc.deinit();
    var ex = Exister{
        .gpa = self.gpa,
        .io = self.io,
        .cq = &cq,
        .sc = &sc,
        .msc = &msc,
        .invert = req.invert,
        .verify_existence = !self.seqlock.provenClean(),
    };
    defer ex.spans.deinit(self.gpa);
    if (req.invert) try gather.eachDoc(self, req.filter, &ex, ceil) else try gather.eachCandidate(self, &cq, req.filter, &ex, ceil);
    return if (ceil.declined()) .{ .declined = .freshness_unprovable } else .{ .got = ex.found };
}

/// Stream one `MatchRecord` per matching LINE over the warm corpus to `sink`
/// — the in-process FFI's search entry (ADR-352 rung 3). Same reconcile +
/// freshness barrier + trigram-prefilter + fail-closed existence check as
/// `fold.query`, but instead of folding to a file set / line count it emits, per
/// matching line, the path, 1-based line number, the line content, and the
/// line's non-empty submatch spans — through the shared core's
/// `collectSpans`, so each record is byte-identical to the cold `gist --json`
/// stream. Docs are emitted in ascending path order; lines within a doc
/// ascend by number. `arena` owns only the transient candidate list; every
/// string/span handed to the sink aliases session/scratch memory valid for
/// that `emit` call alone. Returns whether any line matched. The sink may
/// return `true` from `emit` to STOP early (a bounded / first-match query):
/// the doc loop halts at once and no further candidate is scanned, so the
/// return still reports whether a line matched before the stop. A pattern
/// outside the linear-time syntax declines with `freshness_unprovable` (→ cold
/// fallback), exactly like `fold.query` — the C boundary never sees a `die()`.
pub fn search(self: *ResidentSession, arena: std.mem.Allocator, req: Request, sink: anytype) QueryError!answer.Answer(bool) {
    if (req.matchNothing()) return .{ .got = false };
    if (req.quiet) return queryExists(self, req);
    var tripped: std.atomic.Value(bool) = .init(false);
    var held = switch (try self.beginRead(&tripped)) {
        .got => |h| h,
        .declined => |d| return .{ .declined = d },
    };
    defer held.lease.release();
    switch (try reconcile.guardExtras(self, &held, req)) {
        .got => {},
        .declined => |d| return .{ .declined = d },
    }
    const ceil = held.ceil;

    // Mode is irrelevant to span emission — compile the cheap `files` body.
    var cq = switch (try gather.compileFor(self, req, .files)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    };
    defer cq.deinit(self.gpa);
    // The boolean sim is the whole-doc reject gate: a trigram candidate set is
    // a SUPERSET (false positives, plus the alternation cover's
    // over-approximation), so gating each doc with the cheap `docMatches` — the
    // SAME `-l` decision `fold.query` uses — keeps the expensive per-line span scan
    // (and the sort, and the existence stat) off every non-matching candidate.
    // This pulls the stream to the files/count path's efficiency instead of
    // span-scanning the whole superset. The span VM (`matchScratch`) fires only
    // on the gated docs, so it is allocated per-shard (parallel feed) or once
    // (serial fall-through), never over the superset.
    var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
    defer sc.deinit();

    const docs = try gather.matchingDocs(self, arena, &cq, req.filter, &sc, .json_stream, req.invert, gather.sinkBudget(sink), ceil);

    // A common token's matching-doc set is large enough that the per-line span
    // scan — not the sink emit — is the 1-core-vs-16-core loss to cold. Above
    // the shared byte floor, shard that scan across cores and feed the sink
    // serially in doc order (byte-identical stream, same early-stop); below it,
    // fall through to the serial stream.
    if (try streamParallel(self, arena, req, &cq, docs, sink)) |any|
        return if (ceil.declined()) .{ .declined = .freshness_unprovable } else .{ .got = any };

    var msc = cq.matchScratch(self.gpa) catch return QueryError.OutOfMemory;
    defer msc.deinit();
    var spans: std.ArrayList(Span) = .empty;
    defer spans.deinit(self.gpa);
    var any = false;
    for (docs) |d| {
        const o = try emitDoc(self.gpa, &cq, &msc, &spans, d, req.invert, req.before, req.after, req.max_count, sink);
        any = any or o.matched;
        if (o.halt) break; // sink asked to stop — leave the rest unscanned
    }
    return if (ceil.declined()) .{ .declined = .freshness_unprovable } else .{ .got = any };
}

/// Stream the record set across cores when the matching docs clear the shared
/// byte floor (`parallel.shardBounds`); returns null — the caller streams
/// serially — below the floor or with one usable core. Each shard COLLECTS
/// its contiguous doc range's records (the expensive per-line span scan) into
/// its own arena through the SAME `emitDoc`, buffering (its sink never halts,
/// only copies each record's spans off the transient per-line scratch) rather
/// than emitting; then the buffered records feed the REAL `sink` serially in
/// doc order (shard 0's docs first — the docs are path-sorted and sharded into
/// contiguous ranges), honoring an early `halt` exactly as the serial loop.
/// The record stream is byte-identical and stops at the same record; `any`
/// (a record was emitted before the halt) equals the serial `or o.matched`
/// because every matching doc yields ≥1 record. A sink that halts early may
/// waste the already-collected tail — the floor keeps that off tiny queries,
/// and the win is the large unbounded stream where the scan, not the emit,
/// dominates. The real sink copies each record, so shard arenas free here.
fn streamParallel(self: *ResidentSession, arena: std.mem.Allocator, req: Request, cq: *const CompiledQuery, docs: []const DocRef, sink: anytype) QueryError!?bool {
    const bounds = parallel.shardBounds(DocRef, docs, {}, render.docWeight, render.par_min_bytes, render.par_max_shards, arena) orelse return null;
    const nthr = bounds.len - 1;

    // Buffers instead of emitting: `emit` copies each record's spans off the
    // per-line scratch into the shard arena (path/text already alias mirror
    // memory valid for the whole locked call) and never halts, so the shard
    // collects its full range; the serial feed downstream applies the halt.
    const Buffer = struct {
        arena: std.mem.Allocator,
        recs: std.ArrayList(MatchRecord) = .empty,
        oom: bool = false,

        fn emit(b: *@This(), rec: MatchRecord) bool {
            const spans = b.arena.alloc(Span, rec.spans.len) catch return b.fail();
            @memcpy(spans, rec.spans);
            b.recs.append(b.arena, .{ .path = rec.path, .line_number = rec.line_number, .text = rec.text, .spans = spans, .kind = rec.kind }) catch return b.fail();
            return false;
        }
        fn fail(b: *@This()) bool {
            b.oom = true;
            return true;
        }
    };

    const Shard = struct {
        cq: *const CompiledQuery,
        req: Request,
        docs: []const DocRef,
        arena: std.heap.ArenaAllocator,
        recs: []const MatchRecord = &.{},
        err: ?QueryError = null,

        fn run(sh: *@This()) void {
            const sa = sh.arena.allocator();
            var msc = sh.cq.matchScratch(sa) catch {
                sh.err = QueryError.OutOfMemory; // an already-linear cq only fails scratch on OOM
                return;
            };
            var spans: std.ArrayList(Span) = .empty;
            var buf = Buffer{ .arena = sa };
            for (sh.docs) |d| {
                _ = emitDoc(sa, sh.cq, &msc, &spans, d, sh.req.invert, sh.req.before, sh.req.after, sh.req.max_count, &buf) catch |e| {
                    sh.err = e;
                    return;
                };
                if (buf.oom) {
                    sh.err = QueryError.OutOfMemory;
                    return;
                }
            }
            sh.recs = buf.recs.items;
        }
    };

    const shards = try arena.alloc(Shard, nthr);
    for (shards, 0..) |*sh, i| sh.* = .{
        .cq = cq,
        .req = req,
        .docs = docs[bounds[i]..bounds[i + 1]],
        .arena = std.heap.ArenaAllocator.init(self.gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = try arena.alloc(std.Thread, nthr);
    parallel.fanOut(Shard, shards, threads, Shard.run);

    var any = false;
    for (shards) |*sh| {
        if (sh.err) |e| return e;
        for (sh.recs) |rec| {
            any = true;
            if (sink.emit(rec)) return any; // sink halted — stop feeding, leave the rest
        }
    }
    return any;
}

/// One line's byte range within a doc body, `\n` excluded.
const LineSpan = struct { start: usize, end: usize };

/// rg's line model over a doc body, as an iterator: `\n` TERMINATES a line, so a
/// body ending in `\n` has no phantom final line, and a body that doesn't ends
/// with one partial line. It is the single line-splitting authority every warm
/// per-line face walks — the `-q` invert existence probe, the record stream, and
/// the context planner — so none of them can drift from the others (or from
/// `corpus.gatedLineCount`, which counts the same split) by re-deriving the
/// `indexOfScalarPos` walk locally. `inline` so each caller keeps the same
/// straight-line loop it hand-rolled.
const LineWalk = struct {
    bytes: []const u8,
    pos: usize = 0,
    /// The last line had no terminator, so the body is exhausted even though
    /// `pos` still points inside it.
    partial: bool = false,

    inline fn next(self: *LineWalk) ?LineSpan {
        if (self.partial or self.pos >= self.bytes.len) return null;
        const nl = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, '\n');
        const span = LineSpan{ .start = self.pos, .end = nl orelse self.bytes.len };
        if (nl) |n| self.pos = n + 1 else self.partial = true;
        return span;
    }
};

/// The `-q` existence visitor: cold `anyMatch`'s exact admission — an
/// implicit-binary file (a NUL inside the first 8 KiB) is skipped WHOLE (unlike
/// `-l`'s pre-NUL slice), an empty body never matches — then the shared
/// whole-doc gate. The first hit sets `found` and raises `stop`, so the corpus
/// walk halts at once (the early-out the quiet perf win rests on).
const Exister = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    cq: *const CompiledQuery,
    sc: *Scratch,
    msc: *MatchScratch,
    invert: bool,
    verify_existence: bool,
    spans: std.ArrayList(Span) = .empty,
    found: bool = false,
    stop: bool = false,

    pub fn visit(self: *Exister, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        if (bytes.len == 0) return;
        if (nul != null and corpus_mod.isBinary(bytes)) return;
        if (self.invert) {
            // `-v -q` asks only whether SOME line fails to match; the first such
            // line is the answer, and a body whose every line matches has none.
            var walk = LineWalk{ .bytes = bytes };
            const nonmatching = while (walk.next()) |line| {
                self.spans.clearRetainingCapacity();
                self.cq.collectSpans(self.gpa, bytes[line.start..line.end], self.msc, &self.spans) catch
                    return QueryError.OutOfMemory;
                if (self.spans.items.len == 0) break true;
            } else false;
            if (!nonmatching) return;
        } else if (!self.cq.docMatches(bytes, self.sc)) return;
        if (self.verify_existence and !gather.fileExists(self.io, path)) return;
        self.found = true;
        self.stop = true;
    }
};

/// One doc's emission outcome: whether it had a matching line, and whether the
/// sink asked to halt the whole stream on one of them.
const DocEmit = struct { matched: bool, halt: bool };

/// Emit every selected LINE of one doc to `sink`, ascending by line number,
/// over rg's line model (`\n` terminates, no phantom final line). `spans` is a
/// caller-owned per-line buffer, cleared and refilled per line so no allocation
/// survives the call. `max_count` caps matching lines PER FILE, then advances to
/// the next doc; a sink stop still halts the whole stream. `gather.matchingDocs`
/// (`.json_stream`) admits only non-empty docs cold `--json` would search, so
/// the binary/empty skips that path applies are already upstream.
fn emitDoc(gpa: std.mem.Allocator, cq: *const CompiledQuery, msc: *MatchScratch, spans: *std.ArrayList(Span), d: DocRef, invert: bool, before: u64, after: u64, max_count: ?u64, sink: anytype) error{OutOfMemory}!DocEmit {
    if (before != 0 or after != 0)
        return emitDocContext(gpa, cq, msc, spans, d, invert, before, after, max_count, sink);
    var any = false;
    var emitted: u64 = 0;
    var lineno: u64 = 0;
    var walk = LineWalk{ .bytes = d.bytes };
    while (walk.next()) |line| {
        lineno += 1;
        const view = d.bytes[line.start..line.end];
        spans.clearRetainingCapacity();
        try cq.collectSpans(gpa, view, msc, spans);
        if ((spans.items.len > 0) != invert) {
            any = true;
            emitted += 1;
            if (sink.emit(.{ .path = d.path, .line_number = lineno, .text = view, .spans = spans.items }))
                return .{ .matched = true, .halt = true };
            if (max_count) |cap| if (emitted == cap) break;
        }
    }
    return .{ .matched = any, .halt = false };
}

const LineKind = enum(u2) { none, context, match };
/// One planned line: its `LineSpan` plus the role the context pass painted on it.
const PlannedLine = struct { span: LineSpan, kind: LineKind = .none };

/// Context needs a file-local plan: classify capped match lines first, paint
/// their merged neighborhoods with match precedence, then emit in line order.
/// This mirrors cold JSON's `emitFile` state machine without reproducing its
/// matcher—the shared `CompiledQuery.collectSpans` remains the sole oracle.
fn emitDocContext(gpa: std.mem.Allocator, cq: *const CompiledQuery, msc: *MatchScratch, spans: *std.ArrayList(Span), d: DocRef, invert: bool, before: u64, after: u64, max_count: ?u64, sink: anytype) error{OutOfMemory}!DocEmit {
    var lines: std.ArrayList(PlannedLine) = .empty;
    defer lines.deinit(gpa);
    var walk = LineWalk{ .bytes = d.bytes };
    while (walk.next()) |line| try lines.append(gpa, .{ .span = line });

    const bcap = std.math.cast(usize, before) orelse std.math.maxInt(usize);
    const acap = std.math.cast(usize, after) orelse std.math.maxInt(usize);
    var selected: u64 = 0;
    for (lines.items, 0..) |*line, i| {
        spans.clearRetainingCapacity();
        try cq.collectSpans(gpa, d.bytes[line.span.start..line.span.end], msc, spans);
        if ((spans.items.len > 0) == invert) continue;
        if (max_count) |cap| if (selected >= cap) break;
        selected += 1;
        line.kind = .match;

        var n: usize = 1;
        while (n <= bcap and n <= i) : (n += 1) {
            const prior = &lines.items[i - n];
            if (prior.kind == .none) prior.kind = .context;
        }
        n = 1;
        while (n <= acap and n <= lines.items.len - i - 1) : (n += 1) {
            const following = &lines.items[i + n];
            if (following.kind == .none) following.kind = .context;
        }
    }
    if (selected == 0) return .{ .matched = false, .halt = false };

    for (lines.items, 1..) |line, lineno| {
        if (line.kind == .none) continue;
        spans.clearRetainingCapacity();
        if (line.kind == .match and !invert)
            try cq.collectSpans(gpa, d.bytes[line.span.start..line.span.end], msc, spans);
        if (sink.emit(.{
            .path = d.path,
            .line_number = lineno,
            .text = d.bytes[line.span.start..line.span.end],
            .spans = spans.items,
            .kind = if (line.kind == .match) .match else .context,
        })) return .{ .matched = true, .halt = true };
    }
    return .{ .matched = true, .halt = false };
}
