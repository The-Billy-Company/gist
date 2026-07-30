//! The fold face — answers that are a SET of paths (`-l`) or a COUNT of
//! matching lines (`-c`), including their `-v` complements.
//!
//! Both modes share one candidate walk and differ only in what they accumulate,
//! which is why `Accumulator` carries the mode rather than the walk having two
//! shapes. Above the shared byte floor the base half of that walk shards across
//! cores — a contiguous id range per thread with its own scratch over the
//! immutable mirror — and the shard results merge (`-c` sums, `-l` concatenates
//! then sorts once), byte-identical to the serial fold.
//!
//! `-v` is the interesting one. It is answered by SET COMPLEMENT rather than by
//! abandoning the index: the non-matching lines of a file are
//! `lines(f) − matching(f)`, the trigram prefilter is sound for the POSITIVE
//! set, and `lines(f)` is a corpus invariant paid once at load — so a ruled-out
//! file needs no scan at all and warm does strictly less work than cold, which
//! scans every file. The "index is unsound for -v" framing was pruning the
//! wrong set.

const std = @import("std");
const corpus = @import("../warm/mirror.zig");
const render = @import("render.zig");
const parallel = @import("../../../kernel/math/parallel.zig");
const query_mod = @import("../../../kernel/query/query.zig");
const answer = @import("../answer/answer.zig");
const gather = @import("../answer/gather.zig");
const reconcile = @import("../reconcile/reconcile.zig");
const resident = @import("../warm/resident.zig");
// The cold path's own path comparator — the warm `-l` answer's file order.
const run = @import("../../cold/engine/serial.zig");
const ResidentSession = resident.ResidentSession;
const Ceiling = answer.Ceiling;
const QueryError = answer.QueryError;
const Result = answer.Result;
const Mode = resident.Mode;
const Request = resident.Request;
const CompiledQuery = query_mod.CompiledQuery;
const Scratch = query_mod.Scratch;

/// Answer an eligible `-l`/`-c` request over the warm engine. `arena` owns
/// the returned `files` slice (the path strings themselves alias session
/// memory, stable until the next reconcile — copy under the lock if needed).
/// A `.lines` request declines here — its chunk-streamed
/// presentation is `queryLines`' answer, and routing it through the file/
/// count folder would silently produce the wrong shape.
pub fn query(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!answer.Answer(Result) {
    if (req.mode == .lines) return .{ .declined = .freshness_unprovable };
    // `-m0`: ripgrep matches nothing in every mode — an empty answer, no
    // corpus walk (cold exits 1 before searching a byte; `serial.zig`).
    if (req.matchNothing()) return .{ .got = .{ .mode = req.mode, .files = &.{}, .count = 0 } };
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
    if (req.invert) {
        return try queryInvert(self, arena, req, ceil);
    }

    // Lower the request through the shared search core (`kernel/query/query.zig`):
    // the SAME compile → prefilter → match kernels the cold CLI is built on,
    // but returning errors instead of `die()`ing. A pattern outside the
    // linear-time syntax declines with `freshness_unprovable` → certified cold
    // fallback.
    var cq = switch (try gather.compileFor(self, req, req.mode)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    };
    defer cq.deinit(self.gpa);

    // The reconcile walk-diff already tombstones any delete it observes, but a
    // file can vanish in the race between that walk and this report. On the
    // watcher-clean path a live watcher has tombstoned every delete, so trust
    // it (microsecond no-stat path); otherwise confirm each matched path still
    // exists (a cheap stat per hit) so a just-removed file is never reported.
    const verify = !self.seqlock.provenClean();

    // The trigram base candidate ids, shared by the serial and the sharded
    // base fold. A common token yields a LARGE candidate set whose serial fold
    // is the 1-core-vs-16-core loss to cold; above the shared byte floor the
    // base fold shards across cores (a contiguous id range + its own scratch
    // and accumulator per thread), else it folds serially — byte-identical.
    var cand_buf: ?[]u32 = null;
    defer if (cand_buf) |c| self.gpa.free(c);
    const cand = try gather.candidateIds(self, &cq, req.filter, &cand_buf);

    var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
    defer sc.deinit();
    var acc = Accumulator{ .mode = req.mode, .arena = arena, .io = self.io, .verify_existence = verify, .cq = &cq, .sc = &sc };
    if (!try foldBaseParallel(self, arena, req, &cq, cand, verify, &acc, ceil))
        try gather.eachBase(self, cand, &acc, ceil);
    try gather.eachOverlay(self, req.filter, &acc); // the (bounded) overlay always folds serially

    if (req.mode == .files) std.mem.sort([]const u8, acc.files.items, {}, lessPath);
    if (ceil.declined()) return .{ .declined = .freshness_unprovable };
    return .{ .got = .{ .mode = req.mode, .files = try ownFiles(arena, acc.files.items), .count = acc.count } };
}

/// The scanned-byte weight of one base candidate id — the sharding key for
/// the parallel fold / record stream (a ruled-out overlaid id still weighs
/// its bytes; the tiny imbalance is cheaper than a second overlay lookup).
fn candWeight(self: *ResidentSession, id: u32) usize {
    return self.mir.docs[id].len;
}

/// Fold the base candidate set into `acc` across cores when it is large
/// enough to amortize thread spawn (the shared `parallel.shardBounds` gate);
/// returns false — the caller folds serially — below the byte floor or with
/// one usable core. Each shard walks a contiguous, ordered id range through
/// `gather.eachBase` with its OWN match scratch and per-shard `Accumulator` over
/// the immutable mirror + shared compiled query, then the shard results merge
/// into `acc`: `-c` SUMS the per-shard counts, `-l` CONCATENATES the per-shard
/// path lists (the caller sorts once with `lessPath`). Each merged path aliases
/// immutable mirror memory, so a shard's arena — which backed only its
/// transient list — is freed here. The overlay is the caller's serial job.
fn foldBaseParallel(self: *ResidentSession, arena: std.mem.Allocator, req: Request, cq: *const CompiledQuery, cand: []const u32, verify: bool, acc: *Accumulator, ceil: Ceiling) QueryError!bool {
    const bounds = parallel.shardBounds(u32, cand, self, candWeight, render.par_min_bytes, render.par_max_shards, arena) orelse return false;
    const nthr = bounds.len - 1;

    const Shard = struct {
        session: *ResidentSession,
        cq: *const CompiledQuery,
        ids: []const u32,
        mode: Mode,
        verify: bool,
        ceil: Ceiling,
        arena: std.heap.ArenaAllocator,
        files: std.ArrayList([]const u8) = .empty,
        count: u64 = 0,
        err: ?QueryError = null,

        fn run(sh: *@This()) void {
            // Per-thread scratch off the shared immutable `cq`, drawn from THIS
            // shard's arena — the corpus is read-only under the held session
            // lock, so the only mutable state is this thread's own arena (freed
            // as a unit by the caller, so scratch needs no separate deinit).
            const sa = sh.arena.allocator();
            var sc = sh.cq.scratch(sa) catch {
                sh.err = QueryError.OutOfMemory; // an already-linear cq only fails scratch on OOM
                return;
            };
            var a = Accumulator{ .mode = sh.mode, .arena = sa, .io = sh.session.io, .verify_existence = sh.verify, .cq = sh.cq, .sc = &sc };
            gather.eachBase(sh.session, sh.ids, &a, sh.ceil) catch |e| {
                sh.err = e;
                return;
            };
            sh.files = a.files;
            sh.count = a.count;
        }
    };

    const shards = try arena.alloc(Shard, nthr);
    for (shards, 0..) |*sh, i| sh.* = .{
        .session = self,
        .cq = cq,
        .ids = cand[bounds[i]..bounds[i + 1]],
        .mode = req.mode,
        .verify = verify,
        .ceil = ceil,
        .arena = std.heap.ArenaAllocator.init(self.gpa),
    };
    defer for (shards) |*sh| sh.arena.deinit();

    const threads = try arena.alloc(std.Thread, nthr);
    parallel.fanOut(Shard, shards, threads, Shard.run);

    for (shards) |*sh| {
        if (sh.err) |e| return e;
        acc.count += sh.count;
        if (req.mode == .files) try acc.files.appendSlice(acc.arena, sh.files.items);
    }
    return true;
}

/// Answer `-v -l` / `-v -c` by SET-COMPLEMENT: the non-matching
/// lines of a file are `lines(f) − matching(f)`. The trigram prefilter is
/// sound for the POSITIVE match set (a ruled-out file has zero matches by
/// construction, so its whole cached `lines(f)` is non-matching and needs
/// NO scan — strictly less work than cold, which scans every file), and
/// `lines(f)` is a corpus invariant (`corpus.gatedLineCount`, paid once at
/// load). So only candidate files run the matcher, exactly as the positive
/// search does — the "index is unsound for -v" framing was pruning the wrong
/// set. `-v -l`: a file qualifies iff `matching(f) < lines(f)`. `-v -c`: the
/// wire total is `Σ (lines(f) − matching(f))`, `-m N` capping each file's
/// non-matching contribution. Binary/empty parity is folded into the cached
/// count (a NUL-in-first-buffer file caches `lines = 0` and drops out, as
/// cold suppresses it; a later-NUL file counts its pre-NUL buffers).
fn queryInvert(self: *ResidentSession, arena: std.mem.Allocator, req: Request, ceil: Ceiling) QueryError!answer.Answer(Result) {
    // Uncapped match kernel: `-m N` bounds the COMPLEMENT (non-matching)
    // output per file, applied below once the true match count is known —
    // a capped matcher would under-count matches and over-count the invert.
    var mreq = req;
    mreq.max_count = null;
    var cq = switch (try gather.compileFor(self, mreq, req.mode)) {
        .got => |compiled| compiled,
        .declined => |d| return .{ .declined = d },
    };
    defer cq.deinit(self.gpa);
    var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
    defer sc.deinit();

    var cand_buf: ?[]u32 = null;
    defer if (cand_buf) |c| self.gpa.free(c);
    const cand = try gather.candidateIds(self, &cq, req.filter, &cand_buf);
    const is_cand = try self.gpa.alloc(bool, self.mir.docs.len);
    defer self.gpa.free(is_cand);
    @memset(is_cand, false);
    for (cand) |id| is_cand[id] = true; // pruned to in-scope ids by the filter

    var inv = InvertFold{ .mode = req.mode, .arena = arena, .io = self.io, .cap = req.max_count, .verify_existence = !self.seqlock.provenClean() };
    for (self.mir.paths, self.mir.docs, self.mir.nuls, self.mir.lines, 0..) |path, bytes, nul, nlines, i| {
        if (ceil.over(self.io, i)) {
            self.noteBudgetAbort();
            return .{ .declined = .freshness_unprovable };
        }
        if (nlines == 0) continue; // empty / NUL-in-first-buffer: cold suppresses it
        if (self.overlay.contains(path)) continue; // the overlay pass owns it
        if (!req.filter.admits(path)) continue; // out-of-scope: cold never walks it under `-v`
        const matches = if (is_cand[i]) gatedMatches(&cq, &sc, bytes, nul) else 0;
        try inv.fold(path, nlines, matches);
    }
    var it = self.overlay.iterator();
    while (it.next()) |e| switch (e.value_ptr.*) {
        .tombstone => {},
        .doc => |d| {
            if (!req.filter.admits(e.key_ptr.*)) continue;
            const nlines = corpus.gatedLineCount(d.bytes, d.nul);
            if (nlines == 0) continue;
            // Overlay docs (changed/new since the build) are stale in the
            // index, so they always run the matcher — the same rule the
            // positive walk applies.
            try inv.fold(e.key_ptr.*, nlines, gatedMatches(&cq, &sc, d.bytes, d.nul));
        },
    };

    if (req.mode == .files) std.mem.sort([]const u8, inv.files.items, {}, lessPath);
    return .{ .got = .{ .mode = req.mode, .files = try ownFiles(arena, inv.files.items), .count = inv.count } };
}

/// Folds matched docs into either the file-path set (`-l`) or the matching-line
/// total (`-c`), so both fold modes share one candidate walk. The match
/// decision itself is the shared `CompiledQuery` kernel (`kernel/query/query.zig`);
/// the binary rule per mode is cold's own (see the `resident.zig` header).
const Accumulator = struct {
    mode: Mode,
    arena: std.mem.Allocator,
    io: std.Io,
    verify_existence: bool,
    cq: *const CompiledQuery,
    sc: *Scratch,
    files: std.ArrayList([]const u8) = .empty,
    count: u64 = 0,

    pub fn visit(self: *Accumulator, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        switch (self.mode) {
            .files => {
                // Binary `-l` observes only complete buffers before the one that
                // revealed the first NUL (`binary.handleBinary` files_only) —
                // a match past the cut must not turn the file into a false path.
                const gated = corpus.gatedBody(bytes, nul);
                if (gated.len == 0) return; // NUL in the first buffer ⇒ cold sees zero lines
                if (!self.cq.docMatches(gated, self.sc)) return;
                if (self.verify_existence and !gather.fileExists(self.io, path)) return;
                try self.files.append(self.arena, path);
            },
            .count => {
                // Cold `-c` suppresses an implicit binary file entirely (rg
                // scans, detects the NUL, drops the count) — whole-body NUL,
                // exactly the offset the mirror recorded at ingest.
                if (nul != null) return;
                const n = self.cq.countLines(bytes, self.sc);
                if (n == 0) return;
                if (self.verify_existence and !gather.fileExists(self.io, path)) return;
                self.count += n;
            },
            // The lines presentation never routes through the fold — `query`
            // rejects it up front and `queryLines` renders via `render.zig`.
            .lines => unreachable,
        }
    }
};

/// Matching-line count over `corpus.gatedBody` — the same region cold searches
/// and `corpus.gatedLineCount` measures, so `matches ≤ lines` always — i.e. the
/// `matching(f)` term of the `-v` complement. `cq` must be compiled UNCAPPED
/// (`queryInvert` nulls `max_count`) so the count is the true total.
fn gatedMatches(cq: *const CompiledQuery, sc: *Scratch, bytes: []const u8, nul: ?usize) u64 {
    const gated = corpus.gatedBody(bytes, nul);
    if (gated.len == 0) return 0;
    return cq.countLines(gated, sc);
}

/// Folds each file's `(lines, matches)` into the `-v` answer: `-l` lists a file
/// iff it has ≥1 non-matching line; `-c` sums the per-file non-matching count,
/// each capped by `-m N`. Off the watcher-clean path a qualifying file is
/// existence-checked (the same fail-closed stat the positive fold applies) so a
/// file removed in the walk→report window is never reported.
const InvertFold = struct {
    mode: Mode,
    arena: std.mem.Allocator,
    io: std.Io,
    cap: ?u64,
    verify_existence: bool,
    files: std.ArrayList([]const u8) = .empty,
    count: u64 = 0,

    fn fold(self: *InvertFold, path: []const u8, lines: u32, matches: u64) QueryError!void {
        const nonmatch = @as(u64, lines) - matches; // matches ⊆ lines ⇒ never underflows
        if (nonmatch == 0) return; // every line matched: excluded from -l, contributes 0 to -c
        if (self.verify_existence and !gather.fileExists(self.io, path)) return;
        switch (self.mode) {
            .files => try self.files.append(self.arena, path),
            .count => self.count += if (self.cap) |m| @min(nonmatch, m) else nonmatch,
            .lines => unreachable, // the emit face renders through `queryLines`
        }
    }
};

/// Separator-aware path order for the `-l` answer — the SAME `pathLess` order
/// cold's file sort applies (sort key `.none`), so the warm file list is
/// byte-identical to a cold `gist -l` run, not merely set-equal.
fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return run.pathLess(a, b);
}

/// Copy a matched-path list into the caller's per-query `arena`, so the returned
/// `Result.files` OWNS its bytes instead of aliasing session memory (mirror path
/// table or overlay keys). This is what decouples an answer from the session
/// lock: with the paths duped, the daemon worker can release the read lock before
/// encoding the frame, and a concurrent reconcile writer can't pull the bytes out
/// from under an in-flight `-l` response. The lists are file-set sized (small);
/// `queryLines`/`queryRank`/shm answers are already arena-rendered, so only the
/// `-l` faces need this.
fn ownFiles(arena: std.mem.Allocator, files: []const []const u8) QueryError![]const []const u8 {
    const out = try arena.alloc([]const u8, files.len);
    for (files, out) |src, *dst| dst.* = try arena.dupe(u8, src);
    return out;
}
