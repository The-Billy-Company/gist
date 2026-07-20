// MONOLITHIC: warm-session engine — the freshness seqlock, reconcile overlay, and the three answer faces (fold, lines, record stream) share one mutex-guarded session state
//! gist resident session — the warm, in-memory search engine (ADR-352 rung 2.5).
//!
//! A `ResidentSession` owns the corpus bytes + trigram index for one repository,
//! held warm across many queries so an eligible request (`request.zig`) answers
//! without re-paying the process + index-mmap + candidate-read startup the cold
//! subprocess pays every call. It lowers each request through the shared search
//! core (`engine/query.zig`) — the SAME compile → trigram-prefilter → match
//! kernels the cold CLI is built on — driven directly over the warm corpus, so
//! the warm and cold answers cannot drift. Because that core **returns errors**
//! (`error.Unsupported`) instead of calling `die()`, a bad request surfaces here
//! as `error.Stale` (→ cold fallback) and can never terminate the daemon — the
//! exact hazard ADR-352 defers the C FFI on.
//!
//! ## The corpus is a faithful mirror
//!
//! Base docs load through `corpus.zig`: full reads (no cap), BOM/UTF-16 decode,
//! whole-body first-NUL offsets, empty docs dropped — the same per-file ingest
//! a cold run applies. Binary docs are ADMITTED (cold does not skip a walked
//! binary; it searches up to the buffer that revealed the first NUL), and each
//! mode applies cold's own binary rule at answer time:
//!
//!   - `files` (`-l`): match only within complete buffers before the NUL one
//!     (`grepfile.handleBinary`'s files_only policy).
//!   - `count` (`-c`): an implicit binary file is suppressed entirely.
//!   - `lines` (bare `gist <pattern>`): emit pre-NUL-buffer matches + WARNING,
//!     rendered by `render.zig` through the cold Emitter itself.
//!   - `search` (FFI record stream): a doc cold `--json` would skip (its 8 KiB
//!     `isBinary` window) is skipped, keeping the record stream byte-identical.
//!
//! ## Read-your-writes: a fail-closed reconcile barrier
//!
//! The invariant is `resident matches == gist --no-index matches == rg matches`.
//! It holds because both the base corpus and every reconcile re-derive their file
//! set from the cold path's OWN certified walk (`runtime/cold/engine/serial.zig::
//! defaultFileSet` — hidden-file exclusion, `.gitignore`/`.ignore` precedence,
//! `.git` skip, root scope), never `haystack`'s coarse superset. The warm set is
//! therefore byte-identical to what a rootless `gist <pattern>` would walk:
//!
//!   - A query is answered from resident bytes directly ONLY when the freshness
//!     barrier proves the roots quiescent since the last reconcile — a
//!     watcher-clean window (`markClean`/`markDirty`, driven by inotify on Linux
//!     / FSEvents on macOS; `src/session/watch.zig`). This is the microsecond path.
//!   - Otherwise (no watcher, any pending event, first query) the session
//!     RECONCILES: it re-walks the authoritative set and diffs it against
//!     base + overlay — a path that left the set (deleted, or newly
//!     hidden/ignored) is tombstoned; a new path is read in; a known path whose
//!     mtime/ctime advanced past the freshness cursor is re-read — then answers
//!     over (base ∪ overlay) − tombstones. Fail-closed: a rebuilt index
//!     (`pair.gen` drift), a reconcile allocation failure, or a WALK ERROR (an
//!     unreadable directory — cold reports it and exits 2, so a warm answer over
//!     a silently gapped set would lie) surfaces as `error.Stale` and the daemon
//!     declines, so the client falls back to the certified cold path. (A
//!     catastrophic OOM inside the shared walk itself exits the daemon via
//!     `die()`; the client's dropped connection then falls back cold and the
//!     next query re-spawns a fresh daemon — fail-open too.)
//!
//! Queries are serialized by `mutex`; the watcher only ever touches the atomic
//! `dirty_seq`/`clean` pair, never the overlay, so the barrier is a lock-free
//! seqlock over a mutex-guarded engine.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const bulkstat = @import("../../../corpus/tree/bulkstat.zig");
const corpus = @import("corpus.zig");
const render = @import("render.zig");
const parallel = @import("../../../kernel/primitives/parallel.zig");
// The resident file set is the certified rg-default walk the cold path uses, NOT
// `haystack`'s coarse superset — this is what makes `resident == --no-index ==
// rg` true for hidden files, `.gitignore` precedence, and root scope. `session`
// depending on `faces/search` is a one-way edge (serial.zig never imports
// session), so no import cycle.
const run = @import("../cold/engine/serial.zig");
const grepfile = @import("../cold/read/grepfile.zig");
const dirtylog = @import("dirty.zig");
const delta_mod = @import("delta.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const Index = @import("../../../corpus/index/trigrams/trigram.zig").Index;
const query_mod = @import("../../../kernel/match/query.zig");
const CompiledQuery = query_mod.CompiledQuery;
const Scratch = query_mod.Scratch;
const MatchScratch = query_mod.MatchScratch;
const Span = query_mod.Span;
const request = @import("request.zig");
const Dir = std.Io.Dir;

pub const Mode = request.Mode;
pub const Request = request.Request;

pub const QueryError = error{
    /// The session cannot prove freshness (no valid build anchor, or the index
    /// was rebuilt out from under it and could not be reloaded) — answer cold.
    Stale,
    OutOfMemory,
};

/// One eligible query's answer. `files` aliases session-owned path strings
/// (mirror path table or overlay keys) valid until the next reconcile; the
/// caller (daemon frame builder / test) copies them out under the session lock.
pub const Result = struct { mode: Mode, files: []const []const u8 = &.{}, count: u64 = 0 };

/// A `lines`-mode answer: the pre-rendered output bytes (owned by the caller's
/// arena) and whether any file matched (cold's exit-code boolean).
pub const Lines = struct { out: []const u8, matched: bool };

/// One streamed selection: a matching line, or a zero-span nonmatching line for
/// `-v` (ADR-352 rung 3 — the in-process FFI's output unit). `path` aliases the
/// mirror path table / overlay key; `text` is
/// the line CONTENT without its `\n` terminator and aliases session bytes;
/// `spans` alias `search`'s per-line scratch. All three are valid ONLY during
/// the `emit` call — the sink must copy anything it keeps. `line_number` is
/// 1-based over rg's line model, and every span is a non-empty `[start,end)`
/// byte range within `text`, byte-identical to the cold `gist --json` submatch
/// stream (`runtime/cold/emit/json.zig`).
pub const MatchKind = enum(u32) { match, context };
pub const MatchRecord = struct { path: []const u8, line_number: u64, text: []const u8, spans: []const Span, kind: MatchKind = .match };

// The caller's streaming sink for `search` — the FFI's no-stdout, no-exit
// output channel. Any pointer type `*Sink` with a `pub fn emit(self: *Sink,
// rec: MatchRecord) bool` method qualifies (checked at the `search`/`emitDoc`
// call site, comptime-monomorphized — no vtable, no `*anyopaque`, no reverse
// pointer cast). `emit` is invoked once per matching line, synchronously,
// under the session lock; it must not re-enter the session. It returns `true`
// to STOP the stream early (the caller has enough — a bound, a first hit, its
// own abort) or `false` to keep receiving lines; a stop leaves the corpus
// otherwise unscanned, so bounded queries cost only what they read.

/// A candidate doc gathered before answering so results leave in a
/// deterministic path order. `bytes` aliases mirror/overlay memory; `nul` is
/// the first-NUL byte offset (null ⇒ text), driving each mode's binary rule.
/// Shape-shared with the renderer's `render.Doc`, so the `lines` face hands
/// its gathered slice straight through without a copy.
const DocRef = render.Doc;

/// Separator-aware path order — the SAME `pathLess` cold's `--sort path`
/// comparator uses (`runtime/cold/engine/serial.zig::cmpFiles`). Cold's default
/// parallel pipeline emits in worker-discovery order (nondeterministic);
/// warm canonicalizes to this deterministic total order instead — per-file
/// bytes stay identical, and the rgsuite oracle's own equivalence
/// (`sort_lines(gist) == sort_lines(rg)`) certifies the file-order freedom.
fn docLess(_: void, a: DocRef, b: DocRef) bool {
    return run.pathLess(a.path, b.path);
}

/// The scanned-byte weight of one gathered doc — the sharding key for the
/// parallel record stream (`streamParallel`), so `greedyBounds` balances threads
/// by bytes-to-span-scan and one huge file can't stall a shard.
fn docRefWeight(_: void, d: DocRef) usize {
    return d.bytes.len;
}

/// Which docs a gather admits: the FFI record stream skips what cold `--json`
/// skips (its 8 KiB `isBinary` window); the `lines` renderer admits every doc
/// and lets `grepfile.handleBinary` apply cold's NUL-cut policy per file.
const Admit = enum { json_stream, lines };

/// A base doc's live substitute: a replacement document (gpa-owned bytes +
/// first-NUL offset), or a tombstone (deleted / left the walk set / read empty).
const Overlay = union(enum) { doc: corpus.OwnedDoc, tombstone };

pub const ResidentSession = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    roots_arena: std.heap.ArenaAllocator,
    roots: []const []const u8,

    mir: corpus.Mirror,
    idx: Index,
    /// doc-id lookup for overlay substitution (aliases `mir.paths`).
    by_path: std.StringHashMap(u32),

    /// The published index generation this session bound to ("" = legacy/none),
    /// gpa-owned; a `pair.gen` change triggers a reload.
    index_gen: []u8,
    /// Freshness cursor: files touched at/after this instant are reconciled on
    /// the next non-clean query. Starts at the build anchor, advances to the
    /// pre-walk instant after each reconcile (incremental catch-up).
    fresh_ns: i128,

    /// path (gpa-owned key) → mutation overlay. Accumulates across reconciles;
    /// bounded because a re-touched path replaces its entry in place.
    overlay: std.StringHashMap(Overlay),

    mutex: std.Io.Mutex = .init,
    /// Set by a watcher that is actively proving quiescence; without one the
    /// session reconciles on every query (correct, just not microsecond-fast).
    watcher_active: bool = false,
    /// Bumped by the watcher on every filesystem event (seqlock counter).
    dirty_seq: std.atomic.Value(u64) = .init(0),
    /// True only when a watcher has proven no event since the last reconcile.
    clean: std.atomic.Value(bool) = .init(false),
    /// Set once by a watcher backend that lost coverage it cannot recover (an
    /// inotify queue overflow, an unwatchable new directory): the clean fast
    /// path is permanently disabled and every query reconciles (fail-closed).
    poisoned: std.atomic.Value(bool) = .init(false),

    /// The exact dirty-path hand-off from a path-reporting watcher backend
    /// (macOS FSEvents today). When its drain is exact and doubt-free, the
    /// reconcile verifies ONLY the drained paths — O(changed), not O(tree).
    dirty_log: dirtylog.DirtyLog,
    /// A scoped reconcile is sound only downstream of one full walk that
    /// overlapped the live event stream (the watcher arms before the first
    /// query, so the first reconcile is always the covering full pass).
    full_pass_done: bool = false,
    /// Observability + test hooks: how many reconciles took each path.
    scoped_reconciles: u64 = 0,
    full_reconciles: u64 = 0,

    /// Monotonic per-daemon-boot id, echoed to clients so they can detect a
    /// restarted daemon and re-handshake. Assigned by the server.
    daemon_gen: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !ResidentSession {
        var roots_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer roots_arena.deinit();
        const ra = roots_arena.allocator();
        const owned_roots = try ra.alloc([]const u8, roots.len);
        for (roots, 0..) |r, i| owned_roots[i] = try ra.dupe(u8, r);

        // The freshness cursor is captured BEFORE the corpus read so a write
        // racing the load is caught by the first reconcile, never baked silently
        // into stale base bytes (no false negatives). The session builds its OWN
        // in-memory index over these live bytes, so its baseline is this load
        // instant — NOT the persisted index's on-disk anchor, which belongs to a
        // different index and predates any tree touched since the last `gist
        // index` (using it would re-read the whole corpus on every query).
        const load_ns = std.Io.Clock.now(.real, io).nanoseconds;
        // Select the corpus with the certified rg-default walk (hidden-file
        // exclusion + `.gitignore` precedence + root scope) and mirror exactly
        // that set — so the resident base matches cold's live walk
        // byte-for-byte, never `haystack`'s coarse superset. A walk error here
        // doesn't fail init (the daemon may still come up); the first reconcile
        // re-walks and declines the query if the error persists. A short-lived
        // arena owns the path list just for the read.
        var mir = blk: {
            var sel_arena = std.heap.ArenaAllocator.init(gpa);
            defer sel_arena.deinit();
            const sel = run.defaultFileSet(sel_arena.allocator(), io, owned_roots);
            break :blk try corpus.load(gpa, io, sel.paths);
        };
        errdefer mir.deinit();
        var idx = try Index.build(gpa, mir.docs);
        errdefer idx.deinit();

        var by_path = std.StringHashMap(u32).init(gpa);
        errdefer by_path.deinit();
        try by_path.ensureTotalCapacity(@intCast(mir.paths.len));
        for (mir.paths, 0..) |p, i| by_path.putAssumeCapacity(p, @intCast(i));

        const gen = try readGen(gpa, io);
        errdefer gpa.free(gen);

        return .{ .gpa = gpa, .io = io, .roots_arena = roots_arena, .roots = owned_roots, .mir = mir, .idx = idx, .by_path = by_path, .index_gen = gen, .fresh_ns = load_ns, .overlay = std.StringHashMap(Overlay).init(gpa), .dirty_log = dirtylog.DirtyLog.init(gpa) };
    }

    pub fn deinit(self: *ResidentSession) void {
        self.dirty_log.deinit();
        self.clearOverlay();
        self.overlay.deinit();
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.mir.deinit();
        self.roots_arena.deinit();
    }

    fn freeOverlayValue(self: *ResidentSession, ov: Overlay) void {
        if (ov == .doc) self.gpa.free(ov.doc.bytes);
    }

    fn clearOverlay(self: *ResidentSession) void {
        var it = self.overlay.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.freeOverlayValue(e.value_ptr.*);
        }
        self.overlay.clearRetainingCapacity();
    }

    /// Set the overlay for `path`, freeing any prior value and reusing the key.
    fn putOverlay(self: *ResidentSession, path: []const u8, ov: Overlay) !void {
        const gop = try self.overlay.getOrPut(path);
        if (gop.found_existing) {
            self.freeOverlayValue(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch |e| {
                _ = self.overlay.remove(path);
                return e;
            };
        }
        gop.value_ptr.* = ov;
    }

    // ── watcher hooks (called from the watch thread; lock-free) ──

    /// A filesystem event arrived: the next query must reconcile. A backend
    /// that reports exact paths `note`s them into `dirty_log` FIRST, so any
    /// event counted by a reconcile's pre-drain seq read is already visible
    /// to that drain.
    pub fn markDirty(self: *ResidentSession) void {
        _ = self.dirty_seq.fetchAdd(1, .monotonic);
        self.clean.store(false, .release);
    }

    /// The watcher lost event coverage it cannot win back (inotify queue
    /// overflow, an unwatchable new directory): permanently disable the clean
    /// fast path. Every later query reconciles — slower, never stale.
    pub fn markDoubtForever(self: *ResidentSession) void {
        self.poisoned.store(true, .release);
        self.markDirty();
    }

    /// Declare that a watcher is live and proving quiescence.
    pub fn armWatcher(self: *ResidentSession) void {
        self.watcher_active = true;
    }

    // ── freshness + reload ──

    /// Rebuild the resident corpus/index when the on-disk index generation has
    /// advanced (someone ran `gist index`). Heavy but rare; holds the caller's
    /// lock. On rebuild failure the session keeps its old state and reports
    /// `error.Stale` so the query is answered cold.
    fn maybeReload(self: *ResidentSession) QueryError!void {
        const cur = readGen(self.gpa, self.io) catch return QueryError.Stale;
        defer self.gpa.free(cur);
        if (std.mem.eql(u8, cur, self.index_gen)) return;

        // Build the replacement engine BEFORE tearing the stale one down, so a
        // rebuild failure leaves this session fully intact (→ Stale, cold
        // fallback). init dupes `self.roots` into its own arena before we free
        // the old roots_arena below.
        var fresh = ResidentSession.init(self.gpa, self.io, self.roots) catch return QueryError.Stale;
        // The watcher notes into THIS session's log; the replacement's own
        // (empty) log is surplus. `full_pass_done` survives: the event stream
        // ran across the rebuild, so init's fresh corpus read IS a covering
        // full pass and pending events stay queued for the next drain.
        fresh.dirty_log.deinit();

        // Free only the stale DATA.
        self.clearOverlay();
        self.overlay.deinit();
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.mir.deinit();
        self.roots_arena.deinit();

        // Move the fresh engine's data fields into place, field-by-field, and
        // leave the synchronization + identity fields alone: `mutex` is HELD by
        // the caller (a whole-struct `self.* = fresh` reset it to `.unlocked`,
        // so the caller's `defer unlock` hit `unreachable`); the watcher seqlock
        // (`dirty_seq`/`clean`) stays monotonic; `gpa`/`io`/`daemon_gen`/
        // `watcher_active` are unchanged. `fresh`'s own mutex/atomics/identity
        // are default-initialized and unused, and every owning field has been
        // moved out of it, so it needs no deinit.
        self.roots_arena = fresh.roots_arena;
        self.roots = fresh.roots;
        self.mir = fresh.mir;
        self.idx = fresh.idx;
        self.by_path = fresh.by_path;
        self.index_gen = fresh.index_gen;
        self.fresh_ns = fresh.fresh_ns;
        self.overlay = fresh.overlay;

        self.markDirty(); // a rebuilt index demands a reconcile pass
    }

    /// Bring the overlay current against the certified rg-default walk. No-op on
    /// the watcher-clean fast path. Re-derives the authoritative file set the
    /// cold path would walk RIGHT NOW and diffs it against the resident base +
    /// overlay: a file that left the set (deleted, or newly hidden/ignored) is
    /// tombstoned; a new file is read in; a file whose mtime/ctime advanced past
    /// the freshness cursor is re-read. This is the whole read-your-writes
    /// barrier — the set comes from the SAME walk as cold, so warm answers can't
    /// drift from `gist --no-index`/`rg`. A reconcile allocation failure OR a
    /// walk error (unreadable directory — cold reports it and exits 2) surfaces
    /// as `error.Stale` (→ cold fallback); see the module header on walk OOM.
    fn reconcile(self: *ResidentSession) QueryError!void {
        try self.maybeReload();
        const poisoned = self.poisoned.load(.acquire);
        if (self.watcher_active and !poisoned and self.clean.load(.acquire)) return;

        const seq0 = self.dirty_seq.load(.acquire);
        const now = std.Io.Clock.now(.real, self.io).nanoseconds;

        // Drain the exact dirty set (always — even a full walk must consume
        // it, or stale entries would replay forever). The scoped path is taken
        // only when EVERY soundness gate holds: a live watcher whose backend
        // reports exact paths, no doubt (overflow/drop/unclassifiable event),
        // no poison, and one prior full pass that overlapped the stream.
        var drained = self.dirty_log.drain(self.gpa);
        defer drained.deinit(self.gpa);
        const scoped_eligible = self.watcher_active and !poisoned and
            self.full_pass_done and drained.exact and !drained.doubt;
        const applied = scoped_eligible and try self.reconcileScoped(drained.paths);
        if (applied) {
            self.scoped_reconciles += 1;
        } else {
            try self.reconcileFull();
            if (self.watcher_active) self.full_pass_done = true;
            self.full_reconciles += 1;
        }

        self.fresh_ns = now;
        // Only trust the clean short-circuit if a watcher is live AND no event
        // raced this reconcile (seqlock recheck). Without a watcher, stay dirty.
        if (self.watcher_active and !poisoned and self.dirty_seq.load(.acquire) == seq0)
            self.clean.store(true, .release);
    }

    /// The O(tree) barrier: re-derive the whole authoritative set and diff it
    /// against base + overlay. Always sound; the scoped path's fallback.
    fn reconcileFull(self: *ResidentSession) QueryError!void {
        var walk_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer walk_arena.deinit();
        const fs = run.defaultFileSet(walk_arena.allocator(), self.io, self.roots);
        // An errored walk is a GAPPED set. Cold would report the unreadable
        // directory to stderr and exit 2; serving a clean-looking warm answer
        // over the gap would silently drop its files. Decline (and never mark
        // clean) until a walk completes without error.
        if (fs.path_error) return QueryError.Stale;
        const cur = fs.paths;

        var cur_set = std.StringHashMap(void).init(self.gpa);
        defer cur_set.deinit();
        try cur_set.ensureTotalCapacity(@intCast(cur.len));
        for (cur) |p| cur_set.putAssumeCapacity(p, {});

        for (cur) |p| try self.reconcileOne(p);
        try self.tombstoneVanished(&cur_set);
    }

    /// The O(changed) barrier: verify ONLY the drained watcher paths against
    /// the live tree, with `delta.Delta` re-deriving each membership verdict
    /// through the walk's own ignore machinery. Returns false whenever ANY
    /// resolution cannot be scoped soundly (ignore-source edit, root event,
    /// unmappable or non-ASCII path, unreadable directory) — the caller then
    /// runs the full walk. Partial overlay mutations before a false return are
    /// harmless: each only moved a path toward its current on-disk truth, and
    /// the full walk re-derives everything.
    fn reconcileScoped(self: *ResidentSession, abs_paths: []const []const u8) QueryError!bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var dl = delta_mod.Delta.init(a, self.io, self.roots);
        if (!dl.enabled) return false;

        var gones: std.StringHashMapUnmanaged(void) = .empty; // ASCII-folded gone keys
        var subtrees: std.ArrayList([]const u8) = .empty;
        for (abs_paths) |p| {
            const verdict = dl.resolve(p);
            switch (verdict) {
                .skip => {},
                .needs_full => return false,
                .file => |rel| try self.reconcileOne(rel),
                .subtree => |rel| try subtrees.append(a, rel),
                .gone => |rel| try gones.put(a, try delta_mod.foldLower(a, rel), {}),
            }
            // A case-insensitive filesystem resolves an event's own spelling to
            // a possibly-different canonical key (a case-rename's OLD spelling
            // realpaths to the NEW file). When they differ, the raw spelling
            // names a corpus key that may have just become stale — sweep it
            // like a gone (its keys survive only if still provably current).
            const canon_rel: ?[]const u8 = switch (verdict) {
                .file, .subtree, .gone => |rel| rel,
                else => null,
            };
            if (canon_rel) |rel| if (dl.rawKey(p)) |raw| {
                if (!std.mem.eql(u8, raw, rel)) try gones.put(a, try delta_mod.foldLower(a, raw), {});
            };
        }
        for (subtrees.items) |rel| if (!try self.applySubtree(&dl, a, rel)) return false;
        if (gones.count() != 0) try self.applyGones(&dl, a, &gones);
        return true;
    }

    /// Fold one live-directory event into the overlay: read/refresh everything
    /// the walk admits under it right now, then tombstone every corpus key in
    /// its (ASCII-fold) scope that the fresh enumeration didn't produce and
    /// that is no longer a current, canonically-spelled member — deletes,
    /// newly-hidden files, and stale case spellings after a rename all fall
    /// out of the same predicate.
    fn applySubtree(self: *ResidentSession, dl: *delta_mod.Delta, a: std.mem.Allocator, rel: []const u8) QueryError!bool {
        var sink: std.StringHashMapUnmanaged(void) = .empty;
        dl.walkSubtree(rel, &sink) catch |e| switch (e) {
            error.NeedFull => return false,
            error.OutOfMemory => return QueryError.OutOfMemory,
        };
        var it = sink.keyIterator();
        while (it.next()) |k| try self.reconcileOne(k.*);

        const fold_rel = try delta_mod.foldLower(a, rel);
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.gpa);
        var keys = self.liveKeys();
        while (keys.next()) |k| {
            if (!delta_mod.foldUnderLower(k, fold_rel)) continue;
            if (sink.contains(k)) continue; // freshly verified member
            if (dl.keyIsCurrent(k)) continue; // distinct sibling on a case-sensitive fs
            try doomed.append(self.gpa, k);
        }
        for (doomed.items) |k| try self.putOverlay(k, .tombstone);
        return true;
    }

    /// Fold the drained gone-set into the overlay: any corpus key at-or-under
    /// a gone path (ASCII-folded, so a case-variant event spelling still finds
    /// its canonical key) is tombstoned unless the live tree proves it is
    /// still a current, canonically-spelled member.
    fn applyGones(self: *ResidentSession, dl: *delta_mod.Delta, a: std.mem.Allocator, gones: *const std.StringHashMapUnmanaged(void)) QueryError!void {
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.gpa);
        var keys = self.liveKeys();
        while (keys.next()) |k| {
            const lk = try delta_mod.foldLower(a, k);
            var hit = gones.contains(lk);
            var i: usize = 0;
            while (!hit) {
                const slash = std.mem.indexOfScalarPos(u8, lk, i, '/') orelse break;
                hit = gones.contains(lk[0..slash]);
                i = slash + 1;
            }
            if (!hit) continue;
            if (dl.keyIsCurrent(k)) continue;
            try doomed.append(self.gpa, k);
        }
        for (doomed.items) |k| try self.putOverlay(k, .tombstone);
    }

    /// Iterate every key currently answerable from the session: base docs not
    /// yet tombstoned, plus overlay replacement docs for paths outside the
    /// base corpus. (A tombstoned key is already gone; re-checking it is
    /// wasted work, and re-tombstoning would be a no-op anyway.)
    fn liveKeys(self: *ResidentSession) LiveKeys {
        return .{ .session = self, .overlay_it = self.overlay.iterator() };
    }

    const LiveKeys = struct {
        session: *ResidentSession,
        base_idx: usize = 0,
        overlay_it: std.StringHashMap(Overlay).Iterator,

        fn next(self: *LiveKeys) ?[]const u8 {
            const s = self.session;
            while (self.base_idx < s.mir.paths.len) {
                const p = s.mir.paths[self.base_idx];
                self.base_idx += 1;
                if (s.overlay.get(p)) |ov| if (ov == .tombstone) continue;
                return p;
            }
            while (self.overlay_it.next()) |e| {
                if (e.value_ptr.* != .doc) continue;
                if (s.by_path.contains(e.key_ptr.*)) continue; // yielded above
                return e.key_ptr.*;
            }
            return null;
        }
    };

    /// Fold one currently-authoritative path into the overlay. A new or
    /// reappeared (previously tombstoned) path is read unconditionally; an
    /// already-known path is re-read only when its mtime/ctime advanced past the
    /// freshness cursor — the incremental catch-up that keeps reconcile from
    /// re-reading an unchanged corpus every query.
    fn reconcileOne(self: *ResidentSession, p: []const u8) QueryError!void {
        if (self.overlay.get(p)) |ov| switch (ov) {
            .tombstone => return self.readInto(p), // reappeared since its delete
            .doc => {}, // already substituted — fall through to the mtime gate
        } else if (!self.by_path.contains(p)) {
            return self.readInto(p); // brand-new file, not in the base corpus
        }
        const st = Dir.cwd().statFile(self.io, p, .{}) catch return self.readInto(p);
        if (bulkstat.needsLiveRead(self.fresh_ns, st.mtime.nanoseconds, st.ctime.nanoseconds))
            return self.readInto(p);
    }

    /// Read `p` into an overlay entry with the SAME faithful ingest the base
    /// mirror applies (full read, BOM/UTF-16 decode, whole-body NUL offset), or
    /// a tombstone when it is gone/unreadable/empty — the only cases that can
    /// never produce cold output. A file that turned binary stays IN the
    /// overlay with its `nul` recorded, so each mode applies cold's binary rule.
    fn readInto(self: *ResidentSession, p: []const u8) QueryError!void {
        const doc = corpus.readDocOwned(self.gpa, self.io, p) orelse
            return self.putOverlay(p, .tombstone);
        return self.putOverlay(p, .{ .doc = doc });
    }

    /// Tombstone every base doc or overlaid file that is no longer in the
    /// authoritative set (deleted, or newly hidden/gitignored). Removals are
    /// collected before mutating `overlay` (no mutation mid-iteration).
    fn tombstoneVanished(self: *ResidentSession, cur_set: *const std.StringHashMap(void)) QueryError!void {
        var gone: std.ArrayList([]const u8) = .empty;
        defer gone.deinit(self.gpa);
        var keys = self.liveKeys();
        while (keys.next()) |k| if (!cur_set.contains(k)) try gone.append(self.gpa, k);
        for (gone.items) |p| try self.putOverlay(p, .tombstone);
    }

    // ── the query ──

    /// Compile the request's pattern for `mode` through the shared core; a
    /// pattern it declines is `error.Stale` (→ certified cold fallback).
    /// Case state lowers through `effectiveIgnoreCase` — the single smart-case
    /// resolution site — so the engine fold AND the compiled query's
    /// `caseless` (which drives the trigram-prefilter decline) both see the
    /// RESOLVED value, exactly as cold's finalize fold produces it.
    fn compileFor(self: *ResidentSession, req: Request, mode: Mode) QueryError!CompiledQuery {
        return CompiledQuery.compile(self.gpa, .{
            .pattern = req.pattern,
            .mode = mode,
            .fixed = req.fixed,
            .ignore_case = req.effectiveIgnoreCase(),
            .unicode = req.unicode,
            // `-w`: the shared core owns the word-valid span decision, so every
            // face (docMatches for -l, countLines for -c, collectSpans for the
            // record stream) applies cold's exact rule. The word check runs on
            // the ORIGINAL bytes regardless of the case fold above.
            .word = req.word,
            // `-m N`: the per-file count cap (`null` ⇒ 0 ⇒ unlimited). `-m0`
            // (match nothing) never reaches here — every entry point below
            // short-circuits `req.matchNothing()` before compiling.
            .max_count = req.max_count orelse 0,
        }) catch return QueryError.Stale;
    }

    /// Answer an eligible `-l`/`-c` request over the warm engine. `arena` owns
    /// the returned `files` slice (the path strings themselves alias session
    /// memory, stable until the next reconcile — copy under the lock if needed).
    /// A `.lines` request is `error.Stale` here — its chunk-streamed
    /// presentation is `queryLines`' answer, and routing it through the file/
    /// count folder would silently produce the wrong shape.
    pub fn query(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!Result {
        if (req.mode == .lines) return QueryError.Stale;
        // `-m0`: ripgrep matches nothing in every mode — an empty answer, no
        // corpus walk (cold exits 1 before searching a byte; `serial.zig`).
        if (req.matchNothing()) return .{ .mode = req.mode, .files = &.{}, .count = 0 };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();
        if (req.invert) return self.queryInvert(arena, req);

        // Lower the request through the shared search core (`engine/query.zig`):
        // the SAME compile → prefilter → match kernels the cold CLI is built on,
        // but returning errors instead of `die()`ing. A pattern outside the
        // linear-time syntax surfaces as `error.Stale` → certified cold fallback.
        var cq = try self.compileFor(req, req.mode);
        defer cq.deinit(self.gpa);

        // The reconcile walk-diff already tombstones any delete it observes, but a
        // file can vanish in the race between that walk and this report. On the
        // watcher-clean path a live watcher has tombstoned every delete, so trust
        // it (microsecond no-stat path); otherwise confirm each matched path still
        // exists (a cheap stat per hit) so a just-removed file is never reported.
        const verify = !self.clean.load(.acquire);

        // The trigram base candidate ids, shared by the serial and the sharded
        // base fold. A common token yields a LARGE candidate set whose serial fold
        // is the 1-core-vs-16-core loss to cold; above the shared byte floor the
        // base fold shards across cores (a contiguous id range + its own scratch
        // and accumulator per thread), else it folds serially — byte-identical.
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand = try self.candidateIds(&cq, &cand_buf);

        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();
        var acc = Accumulator{ .mode = req.mode, .arena = arena, .io = self.io, .verify_existence = verify, .cq = &cq, .sc = &sc };
        if (!try self.foldBaseParallel(arena, req, &cq, cand, verify, &acc))
            try self.eachBase(cand, &acc);
        try self.eachOverlay(&acc); // the (bounded) overlay always folds serially

        if (req.mode == .files) std.mem.sort([]const u8, acc.files.items, {}, lessPath);
        return .{ .mode = req.mode, .files = acc.files.items, .count = acc.count };
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
    /// `eachBase` with its OWN match scratch and per-shard `Accumulator` over the
    /// immutable mirror + shared compiled query, then the shard results merge
    /// into `acc`: `-c` SUMS the per-shard counts, `-l` CONCATENATES the per-shard
    /// path lists (the caller sorts once with `lessPath`). Each merged path aliases
    /// immutable mirror memory, so a shard's arena — which backed only its
    /// transient list — is freed here. The overlay is the caller's serial job.
    fn foldBaseParallel(self: *ResidentSession, arena: std.mem.Allocator, req: Request, cq: *const CompiledQuery, cand: []const u32, verify: bool, acc: *Accumulator) QueryError!bool {
        const bounds = parallel.shardBounds(u32, cand, self, candWeight, render.par_min_bytes, render.par_max_shards, arena) orelse return false;
        const nthr = bounds.len - 1;

        const Shard = struct {
            session: *ResidentSession,
            cq: *const CompiledQuery,
            ids: []const u32,
            mode: Mode,
            verify: bool,
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
                sh.session.eachBase(sh.ids, &a) catch |e| {
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

    /// Answer `-v -l` / `-v -c` by SET-COMPLEMENT (Lever A): the non-matching
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
    fn queryInvert(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!Result {
        // Uncapped match kernel: `-m N` bounds the COMPLEMENT (non-matching)
        // output per file, applied below once the true match count is known —
        // a capped matcher would under-count matches and over-count the invert.
        var mreq = req;
        mreq.max_count = null;
        var cq = try self.compileFor(mreq, req.mode);
        defer cq.deinit(self.gpa);
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand = try self.candidateIds(&cq, &cand_buf);
        const is_cand = try self.gpa.alloc(bool, self.mir.docs.len);
        defer self.gpa.free(is_cand);
        @memset(is_cand, false);
        for (cand) |id| is_cand[id] = true;

        var inv = InvertFold{ .mode = req.mode, .arena = arena, .io = self.io, .cap = req.max_count, .verify_existence = !self.clean.load(.acquire) };
        for (self.mir.paths, self.mir.docs, self.mir.nuls, self.mir.lines, 0..) |path, bytes, nul, nlines, i| {
            if (nlines == 0) continue; // empty / NUL-in-first-buffer: cold suppresses it
            if (self.overlay.contains(path)) continue; // the overlay pass owns it
            const matches = if (is_cand[i]) gatedMatches(&cq, &sc, bytes, nul) else 0;
            try inv.fold(path, nlines, matches);
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| {
                const nlines = corpus.gatedLineCount(d.bytes, d.nul);
                if (nlines == 0) continue;
                // Overlay docs (changed/new since the build) are stale in the
                // index, so they always run the matcher — the same rule the
                // positive walk applies.
                try inv.fold(e.key_ptr.*, nlines, gatedMatches(&cq, &sc, d.bytes, d.nul));
            },
        };

        if (req.mode == .files) std.mem.sort([]const u8, inv.files.items, {}, lessPath);
        return .{ .mode = req.mode, .files = inv.files.items, .count = inv.count };
    }

    /// Answer a bare `gist <pattern>` (`.lines`) request: the default
    /// `path:text` / `-n` `path:line:text` presentation, pre-rendered into one
    /// buffer through the cold engine's OWN Emitter (`render.zig`) so the bytes
    /// cannot drift from a piped cold run. Same reconcile + freshness barrier +
    /// trigram prefilter + fail-closed existence check as `query`; docs render
    /// in the warm canonical `pathLess` file order (see `docLess`); binary
    /// docs get cold's exact NUL-cut policy. `arena` owns the returned bytes.
    /// A pattern outside the linear
    /// engine (or a mid-render OOM) is `error.Stale`/`OutOfMemory` → the daemon
    /// declines and the client answers cold.
    pub fn queryLines(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!Lines {
        if (req.matchNothing()) return .{ .out = "", .matched = false }; // `-m0` (see `query`)
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        var cq = try self.compileFor(req, .files); // the whole-doc gate; presentation is render's job
        defer cq.deinit(self.gpa);
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        // Admit every doc (binary included — the renderer applies cold's cut).
        // The whole-doc gate over full bytes is a sound superset: a binary doc
        // whose only match sits past its NUL buffer renders to nothing, exactly
        // as cold's emit loop produces nothing for it. Under `-v` every text
        // doc is admitted whole (a doc with zero matching lines is entirely
        // selected), so the emit gather walks every doc — the invert emit's own
        // cost, which Lever B parallelizes.
        const docs = try self.matchingDocs(arena, &cq, &sc, .lines, req.invert);
        var out: std.ArrayList(u8) = .empty;
        // Both faces shard the emit over cores through the SAME primitive
        // (`render.renderLinesParallel` → `parallel.shardBounds`): `-v` selects
        // nearly every line of every doc, and a common positive token prunes to
        // a candidate set large enough that the serial render is the
        // 1-core-vs-16-core loss to cold's fused scan. Below the shared byte
        // floor it falls through to the serial core; either way the concatenated
        // bytes are identical to the serial render.
        const matched = render.renderLinesParallel(self.gpa, arena, req, docs, &out) catch |e| switch (e) {
            error.OutOfMemory => return QueryError.OutOfMemory,
            error.Unsupported => return QueryError.Stale,
        };
        return .{ .out = out.items, .matched = matched };
    }

    /// Answer an eligible `-q`/`--quiet` request: does ANY line match, anywhere
    /// in the corpus? rg's `-q` prints nothing and exits 0 the instant the first
    /// match is found (else 1) — so this is an EARLY-HALTING existence walk: the
    /// `Exister` visitor raises `stop` on its first hit and `eachCandidate`
    /// abandons the rest of the corpus unscanned. That short-circuit IS the warm
    /// win (a bounded prefix instead of the whole tree). Binary/empty handling
    /// mirrors cold's `anyMatch` (an implicit-binary file is skipped whole, not
    /// pre-NUL sliced like `-l`); off the watcher-clean path the first hit is
    /// existence-checked so a just-deleted file never fabricates a match. No
    /// arena: only a boolean crosses back. `-m0` short-circuits to `false`.
    pub fn queryExists(self: *ResidentSession, req: Request) QueryError!bool {
        if (req.matchNothing()) return false; // `-m0` (see `query`)
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        var cq = try self.compileFor(req, .files); // the whole-doc gate is all `-q` needs
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
            .verify_existence = !self.clean.load(.acquire),
        };
        defer ex.spans.deinit(self.gpa);
        if (req.invert) try self.eachDoc(&ex) else try self.eachCandidate(&cq, &ex);
        return ex.found;
    }

    /// Stream one `MatchRecord` per matching LINE over the warm corpus to `sink`
    /// — the in-process FFI's search entry (ADR-352 rung 3). Same reconcile +
    /// freshness barrier + trigram-prefilter + fail-closed existence check as
    /// `query`, but instead of folding to a file set / line count it emits, per
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
    /// outside the linear-time syntax surfaces as `error.Stale` (→ cold
    /// fallback), exactly like `query` — the C boundary never sees a `die()`.
    pub fn search(self: *ResidentSession, arena: std.mem.Allocator, req: Request, sink: anytype) QueryError!bool {
        if (req.matchNothing()) return false;
        if (req.quiet) return self.queryExists(req);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        // Mode is irrelevant to span emission — compile the cheap `files` body.
        var cq = try self.compileFor(req, .files);
        defer cq.deinit(self.gpa);
        // The boolean sim is the whole-doc reject gate: a trigram candidate set is
        // a SUPERSET (false positives, plus the alternation cover's
        // over-approximation), so gating each doc with the cheap `docMatches` — the
        // SAME `-l` decision `query` uses — keeps the expensive per-line span scan
        // (and the sort, and the existence stat) off every non-matching candidate.
        // This pulls the stream to the files/count path's efficiency instead of
        // span-scanning the whole superset. The span VM (`matchScratch`) fires only
        // on the gated docs, so it is allocated per-shard (parallel feed) or once
        // (serial fall-through), never over the superset.
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        const docs = try self.matchingDocs(arena, &cq, &sc, .json_stream, req.invert);

        // A common token's matching-doc set is large enough that the per-line span
        // scan — not the sink emit — is the 1-core-vs-16-core loss to cold. Above
        // the shared byte floor, shard that scan across cores and feed the sink
        // serially in doc order (byte-identical stream, same early-stop); below it,
        // fall through to the serial stream.
        if (try self.streamParallel(arena, req, &cq, docs, sink)) |any| return any;

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
        return any;
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
        const bounds = parallel.shardBounds(DocRef, docs, {}, docRefWeight, render.par_min_bytes, render.par_max_shards, arena) orelse return null;
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
            session: *ResidentSession,
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
            .session = self,
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

    /// Gather searchable docs (base ∪ overlay − tombstones) into a path-sorted
    /// slice, shared by the `lines` renderer and the FFI record stream. Positive
    /// searches require the whole-doc match gate; invert admits every text doc
    /// because any one of its lines may be selected. Off the
    /// watcher-clean path a matching doc is then existence-checked (the same
    /// fail-closed stat-per-hit `query` uses) so a file removed in the
    /// walk→report window is never reported. `admit` selects the binary policy
    /// (see `Admit`). The sort is `run.pathLess` — the warm canonical file
    /// order (see `docLess`) — so downstream output is deterministic.
    fn matchingDocs(self: *ResidentSession, arena: std.mem.Allocator, cq: *const CompiledQuery, sc: *Scratch, admit: Admit, invert: bool) QueryError![]const DocRef {
        var g = Gather{ .arena = arena, .io = self.io, .cq = cq, .sc = sc, .admit = admit, .require_match = !invert, .check_exists = !self.clean.load(.acquire) };
        if (invert) try self.eachDoc(&g) else try self.eachCandidate(cq, &g);
        std.mem.sort(DocRef, g.docs.items, {}, docLess);
        return g.docs.items;
    }

    /// Walk every live document without trigram pruning. Invert-match needs this:
    /// a document excluded by the positive candidate set may be entirely made of
    /// selected nonmatching lines.
    fn eachDoc(self: *ResidentSession, v: anytype) QueryError!void {
        for (self.mir.paths, self.mir.docs, self.mir.nuls) |path, bytes, nul| {
            if (self.overlay.contains(path)) continue;
            try v.visit(path, bytes, nul);
            if (wantsStop(v)) return;
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| {
                try v.visit(e.key_ptr.*, d.bytes, d.nul);
                if (wantsStop(v)) return;
            },
        };
    }

    /// Walk every candidate doc through `v.visit(path, bytes, nul)`: first the
    /// trigram-pruned base docs (`candidateIds`) that are not overlaid, then
    /// the overlay's replacement docs — the visitor verifies each with the
    /// shared match kernel. Overlay docs (changed/new since the build) are
    /// always visited directly — the index is stale for exactly those. Shared
    /// by the files/count fold (`Accumulator`) and the doc gather (`Gather`),
    /// so every answer face prunes candidates identically.
    fn eachCandidate(self: *ResidentSession, cq: *const CompiledQuery, v: anytype) QueryError!void {
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        try self.eachBase(try self.candidateIds(cq, &cand_buf), v);
        if (wantsStop(v)) return;
        try self.eachOverlay(v);
    }

    /// The base half of `eachCandidate`: visit each trigram base candidate id in
    /// `cand` that is not shadowed by the overlay. Split out so the `-l`/`-c`
    /// fold can SHARD this walk across cores (a contiguous id range per thread,
    /// each with its own scratch over the immutable mirror), while the bounded
    /// overlay stays serial. `cand` is contiguous and ordered, so a sharded walk
    /// yields the same visits in the same per-shard order.
    fn eachBase(self: *ResidentSession, cand: []const u32, v: anytype) QueryError!void {
        for (cand) |id| {
            if (self.overlay.contains(self.mir.paths[id])) continue; // overlay owns it
            try v.visit(self.mir.paths[id], self.mir.docs[id], self.mir.nuls[id]);
            if (wantsStop(v)) return; // `-q` early-halt (comptime no-op for other visitors)
        }
    }

    /// The overlay half of `eachCandidate`: visit each overlay replacement doc.
    /// Overlay docs (changed/new since the build) are always visited directly —
    /// the index is stale for exactly those. A reconcile tombstones any overlay
    /// path that left the walk set, but (as for base docs) a delete can still
    /// race the walk→report window, so off the watcher-clean path each visitor
    /// existence-checks its match (the same fail-closed stat-per-hit the base
    /// docs get); the clean path already tombstoned any delete, keeping the
    /// no-stat path. Bounded by the mutation count since build, so always serial.
    fn eachOverlay(self: *ResidentSession, v: anytype) QueryError!void {
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| {
                try v.visit(e.key_ptr.*, d.bytes, d.nul);
                if (wantsStop(v)) return;
            },
        };
    }

    /// The base-doc candidate ids for `cq`: the sound trigram prefilter's index
    /// hits (a single required literal → `queryLiteral`; an alternation cover →
    /// `queryAny`), or every doc id when nothing is prunable or the index query
    /// fails. `buf` owns any index-allocated slice (freed by the caller). Shared
    /// by the files/count `answer`, the `lines` renderer, and the FFI match
    /// stream (`matchingDocs`) so all faces prune candidates identically.
    fn candidateIds(self: *ResidentSession, cq: *const CompiledQuery, buf: *?[]u32) QueryError![]const u32 {
        var one: [1][]const u8 = undefined;
        const pf = cq.prefilter(&one);
        const hit: ?[]u32 = switch (pf.len) {
            0 => null,
            1 => self.idx.queryLiteral(self.gpa, pf[0]) catch null,
            else => self.idx.queryAny(self.gpa, pf) catch null,
        };
        const c = hit orelse blk: {
            const all = try self.gpa.alloc(u32, self.mir.docs.len);
            for (all, 0..) |*x, i| x.* = @intCast(i);
            break :blk all;
        };
        buf.* = c;
        return c;
    }
};

/// Does `path` still exist right now? The fail-closed stat-per-hit every
/// answer face applies off the watcher-clean path — one definition, so the
/// fold accumulator and the doc gather can never drift on this check.
fn fileExists(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// A walk visitor MAY expose a `stop: bool` to abandon `eachCandidate` early
/// (the `-q` existence halt). The `@hasField` guard is comptime, so a visitor
/// without the field compiles the check away entirely — no runtime branch is
/// added to the fold/gather hot walk.
inline fn wantsStop(v: anytype) bool {
    if (comptime @hasField(std.meta.Child(@TypeOf(v)), "stop")) return v.stop;
    return false;
}

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

    fn visit(self: *Exister, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        if (bytes.len == 0) return;
        if (nul != null and corpus_mod.isBinary(bytes)) return;
        if (self.invert) {
            var pos: usize = 0;
            while (pos < bytes.len) {
                const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n');
                const end = nl orelse bytes.len;
                self.spans.clearRetainingCapacity();
                self.cq.collectSpans(self.gpa, bytes[pos..end], self.msc, &self.spans) catch
                    return QueryError.OutOfMemory;
                if (self.spans.items.len == 0) break;
                if (nl == null) return;
                pos = end + 1;
            } else return;
        } else if (!self.cq.docMatches(bytes, self.sc)) return;
        if (self.verify_existence and !fileExists(self.io, path)) return;
        self.found = true;
        self.stop = true;
    }
};

/// The `matchingDocs` visitor — one admission decision per candidate doc:
/// binary policy, whole-doc gate, existence check, append.
const Gather = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    cq: *const CompiledQuery,
    sc: *Scratch,
    admit: Admit,
    require_match: bool,
    check_exists: bool,
    docs: std.ArrayList(DocRef) = .empty,

    fn visit(self: *Gather, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        // Cold `--json` skips a doc its 8 KiB `isBinary` window flags; a doc whose
        // first NUL sits past the window is streamed in full. Match that exactly.
        if (self.admit == .json_stream and nul != null and corpus_mod.isBinary(bytes)) return;
        if (self.require_match and !self.cq.docMatches(bytes, self.sc)) return;
        if (self.check_exists and !fileExists(self.io, path)) return;
        try self.docs.append(self.arena, .{ .path = path, .bytes = bytes, .nul = nul });
    }
};

/// One doc's emission outcome: whether it had a matching line, and whether the
/// sink asked to halt the whole stream on one of them.
const DocEmit = struct { matched: bool, halt: bool };

/// Emit every selected LINE of one doc to `sink`, ascending by line number,
/// over rg's line model (`\n` terminates, no phantom final line). `spans` is a
/// caller-owned per-line buffer, cleared and refilled per line so no allocation
/// survives the call. `max_count` caps matching lines PER FILE, then advances to
/// the next doc; a sink stop still halts the whole stream. `matchingDocs`
/// (`.json_stream`) admits only non-empty docs cold `--json` would search, so
/// the binary/empty skips that path applies are already upstream.
fn emitDoc(gpa: std.mem.Allocator, cq: *const CompiledQuery, msc: *MatchScratch, spans: *std.ArrayList(Span), d: DocRef, invert: bool, before: u64, after: u64, max_count: ?u64, sink: anytype) error{OutOfMemory}!DocEmit {
    if (before != 0 or after != 0)
        return emitDocContext(gpa, cq, msc, spans, d, invert, before, after, max_count, sink);
    var any = false;
    var emitted: u64 = 0;
    var pos: usize = 0;
    var lineno: u64 = 0;
    while (pos < d.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, d.bytes, pos, '\n');
        const end = nl orelse d.bytes.len;
        lineno += 1;
        const view = d.bytes[pos..end];
        spans.clearRetainingCapacity();
        try cq.collectSpans(gpa, view, msc, spans);
        if ((spans.items.len > 0) != invert) {
            any = true;
            emitted += 1;
            if (sink.emit(.{ .path = d.path, .line_number = lineno, .text = view, .spans = spans.items }))
                return .{ .matched = true, .halt = true };
            if (max_count) |cap| if (emitted == cap) break;
        }
        if (nl == null) break;
        pos = end + 1;
    }
    return .{ .matched = any, .halt = false };
}

const LineKind = enum(u2) { none, context, match };
const PlannedLine = struct { start: usize, end: usize, kind: LineKind = .none };

/// Context needs a file-local plan: classify capped match lines first, paint
/// their merged neighborhoods with match precedence, then emit in line order.
/// This mirrors cold JSON's `emitFile` state machine without reproducing its
/// matcher—the shared `CompiledQuery.collectSpans` remains the sole oracle.
fn emitDocContext(gpa: std.mem.Allocator, cq: *const CompiledQuery, msc: *MatchScratch, spans: *std.ArrayList(Span), d: DocRef, invert: bool, before: u64, after: u64, max_count: ?u64, sink: anytype) error{OutOfMemory}!DocEmit {
    var lines: std.ArrayList(PlannedLine) = .empty;
    defer lines.deinit(gpa);
    var pos: usize = 0;
    while (pos < d.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, d.bytes, pos, '\n');
        const end = nl orelse d.bytes.len;
        try lines.append(gpa, .{ .start = pos, .end = end });
        if (nl == null) break;
        pos = end + 1;
    }

    const bcap = std.math.cast(usize, before) orelse std.math.maxInt(usize);
    const acap = std.math.cast(usize, after) orelse std.math.maxInt(usize);
    var selected: u64 = 0;
    for (lines.items, 0..) |*line, i| {
        spans.clearRetainingCapacity();
        try cq.collectSpans(gpa, d.bytes[line.start..line.end], msc, spans);
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
            try cq.collectSpans(gpa, d.bytes[line.start..line.end], msc, spans);
        if (sink.emit(.{
            .path = d.path,
            .line_number = lineno,
            .text = d.bytes[line.start..line.end],
            .spans = spans.items,
            .kind = if (line.kind == .match) .match else .context,
        })) return .{ .matched = true, .halt = true };
    }
    return .{ .matched = true, .halt = false };
}

/// Folds matched docs into either the file-path set (`-l`) or the matching-line
/// total (`-c`), so both fold modes share one candidate walk. The match
/// decision itself is the shared `CompiledQuery` kernel (`engine/query.zig`);
/// the binary rule per mode is cold's own (see the module header).
const Accumulator = struct {
    mode: Mode,
    arena: std.mem.Allocator,
    io: std.Io,
    verify_existence: bool,
    cq: *const CompiledQuery,
    sc: *Scratch,
    files: std.ArrayList([]const u8) = .empty,
    count: u64 = 0,

    fn visit(self: *Accumulator, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        switch (self.mode) {
            .files => {
                // Binary `-l` observes only complete buffers before the one that
                // revealed the first NUL (`grepfile.handleBinary` files_only) —
                // a match past the cut must not turn the file into a false path.
                const gated = if (nul) |n| bytes[0 .. (n / grepfile.BUFCAP) * grepfile.BUFCAP] else bytes;
                if (gated.len == 0) return; // NUL in the first buffer ⇒ cold sees zero lines
                if (!self.cq.docMatches(gated, self.sc)) return;
                if (self.verify_existence and !fileExists(self.io, path)) return;
                try self.files.append(self.arena, path);
            },
            .count => {
                // Cold `-c` suppresses an implicit binary file entirely (rg
                // scans, detects the NUL, drops the count) — whole-body NUL,
                // exactly the offset the mirror recorded at ingest.
                if (nul != null) return;
                const n = self.cq.countLines(bytes, self.sc);
                if (n == 0) return;
                if (self.verify_existence and !fileExists(self.io, path)) return;
                self.count += n;
            },
            // The lines presentation never routes through the fold — `query`
            // rejects it up front and `queryLines` renders via `render.zig`.
            .lines => unreachable,
        }
    }
};

/// Matching-line count over the region cold actually searches — the whole body
/// of a text doc, or the complete buffers before a binary doc's first NUL (the
/// same cut `corpus.gatedLineCount` measures, so `matches ≤ lines` always) —
/// the `matching(f)` term of the `-v` complement. `cq` must be compiled
/// UNCAPPED (`queryInvert` nulls `max_count`) so the count is the true total.
fn gatedMatches(cq: *const CompiledQuery, sc: *Scratch, bytes: []const u8, nul: ?usize) u64 {
    const gated = if (nul) |n| bytes[0 .. (n / grepfile.BUFCAP) * grepfile.BUFCAP] else bytes;
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
        if (self.verify_existence and !fileExists(self.io, path)) return;
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

/// The published `pair.gen` (gpa-owned; "" when absent). A rebuilt index changes
/// this, triggering `maybeReload`.
fn readGen(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const buf = Dir.cwd().readFileAlloc(io, persist.generationFile(), gpa, .limited(128)) catch
        return gpa.alloc(u8, 0);
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len) return buf;
    defer gpa.free(buf);
    return gpa.dupe(u8, trimmed);
}
