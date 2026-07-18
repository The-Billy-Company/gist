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
//! set from the cold path's OWN certified walk (`faces/cli/search/engine/serial.zig::
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
const corpus_mod = @import("../../corpus/corpus.zig");
const bulkstat = @import("../../corpus/bulkstat.zig");
const corpus = @import("corpus.zig");
const render = @import("render.zig");
// The resident file set is the certified rg-default walk the cold path uses, NOT
// `haystack`'s coarse superset — this is what makes `resident == --no-index ==
// rg` true for hidden files, `.gitignore` precedence, and root scope. `session`
// depending on `faces/search` is a one-way edge (serial.zig never imports
// session), so no import cycle.
const run = @import("../faces/cli/search/engine/serial.zig");
const grepfile = @import("../faces/cli/search/read/grepfile.zig");
const dirtylog = @import("dirty.zig");
const delta_mod = @import("delta.zig");
const persist = @import("../kernel/index/persist.zig");
const Index = @import("../kernel/index/trigram.zig").Index;
const query_mod = @import("../kernel/engine/query.zig");
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
pub const Result = struct {
    mode: Mode,
    files: []const []const u8 = &.{},
    count: u64 = 0,
};

/// A `lines`-mode answer: the pre-rendered output bytes (owned by the caller's
/// arena) and whether any file matched (cold's exit-code boolean).
pub const Lines = struct {
    out: []const u8,
    matched: bool,
};

/// One streamed match: a matching LINE (ADR-352 rung 3 — the in-process FFI's
/// output unit). `path` aliases the mirror path table / overlay key; `text` is
/// the line CONTENT without its `\n` terminator and aliases session bytes;
/// `spans` alias `search`'s per-line scratch. All three are valid ONLY during
/// the `emit` call — the sink must copy anything it keeps. `line_number` is
/// 1-based over rg's line model, and every span is a non-empty `[start,end)`
/// byte range within `text`, byte-identical to the cold `gist --json` submatch
/// stream (`faces/cli/search/emit/json.zig`).
pub const MatchRecord = struct {
    path: []const u8,
    line_number: u64,
    text: []const u8,
    spans: []const Span,
};

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
const DocRef = struct {
    path: []const u8,
    bytes: []const u8,
    nul: ?usize = null,

    /// Separator-aware path order — the SAME `pathLess` cold's `--sort path`
    /// comparator uses (`faces/cli/search/engine/serial.zig::cmpFiles`). Cold's default
    /// parallel pipeline emits in worker-discovery order (nondeterministic);
    /// warm canonicalizes to this deterministic total order instead — per-file
    /// bytes stay identical, and the rgsuite oracle's own equivalence
    /// (`sort_lines(gist) == sort_lines(rg)`) certifies the file-order freedom.
    fn less(_: void, a: DocRef, b: DocRef) bool {
        return run.pathLess(a.path, b.path);
    }
};

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
        var sel_arena = std.heap.ArenaAllocator.init(gpa);
        const sel = run.defaultFileSet(sel_arena.allocator(), io, owned_roots);
        var mir = corpus.load(gpa, io, sel.paths) catch |e| {
            sel_arena.deinit();
            return e;
        };
        sel_arena.deinit();
        errdefer mir.deinit();
        var idx = try Index.build(gpa, mir.docs);
        errdefer idx.deinit();

        var by_path = std.StringHashMap(u32).init(gpa);
        errdefer by_path.deinit();
        try by_path.ensureTotalCapacity(@intCast(mir.paths.len));
        for (mir.paths, 0..) |p, i| by_path.putAssumeCapacity(p, @intCast(i));

        const gen = try readGen(gpa, io);
        errdefer gpa.free(gen);

        return .{
            .gpa = gpa,
            .io = io,
            .roots_arena = roots_arena,
            .roots = owned_roots,
            .mir = mir,
            .idx = idx,
            .by_path = by_path,
            .index_gen = gen,
            .fresh_ns = load_ns,
            .overlay = std.StringHashMap(Overlay).init(gpa),
            .dirty_log = dirtylog.DirtyLog.init(gpa),
        };
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

    fn clearOverlay(self: *ResidentSession) void {
        var it = self.overlay.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            switch (e.value_ptr.*) {
                .doc => |d| self.gpa.free(d.bytes),
                .tombstone => {},
            }
        }
        self.overlay.clearRetainingCapacity();
    }

    /// Set the overlay for `path`, freeing any prior value and reusing the key.
    fn putOverlay(self: *ResidentSession, path: []const u8, ov: Overlay) !void {
        const gop = try self.overlay.getOrPut(path);
        if (gop.found_existing) {
            switch (gop.value_ptr.*) {
                .doc => |d| self.gpa.free(d.bytes),
                .tombstone => {},
            }
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
        var applied = false;
        if (scoped_eligible) applied = try self.reconcileScoped(drained.paths);
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
        for (self.mir.paths) |p| {
            if (cur_set.contains(p)) continue;
            if (self.overlay.get(p)) |ov| if (ov == .tombstone) continue; // already gone
            try gone.append(self.gpa, p);
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .doc => if (!cur_set.contains(e.key_ptr.*)) try gone.append(self.gpa, e.key_ptr.*),
            .tombstone => {},
        };
        for (gone.items) |p| try self.putOverlay(p, .tombstone);
    }

    // ── the query ──

    /// Answer an eligible `-l`/`-c` request over the warm engine. `arena` owns
    /// the returned `files` slice (the path strings themselves alias session
    /// memory, stable until the next reconcile — copy under the lock if needed).
    /// A `.lines` request is `error.Stale` here — its chunk-streamed
    /// presentation is `queryLines`' answer, and routing it through the file/
    /// count folder would silently produce the wrong shape.
    pub fn query(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!Result {
        if (req.mode == .lines) return QueryError.Stale;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        // Lower the request through the shared search core (`engine/query.zig`):
        // the SAME compile → prefilter → match kernels the cold CLI is built on,
        // but returning errors instead of `die()`ing. A pattern outside the
        // linear-time syntax surfaces as `error.Stale` → certified cold fallback.
        var cq = CompiledQuery.compile(self.gpa, .{
            .pattern = req.pattern,
            .mode = req.mode,
            .fixed = req.fixed,
            .ignore_case = req.ignore_case,
        }) catch return QueryError.Stale;
        defer cq.deinit(self.gpa);
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        // The reconcile walk-diff already tombstones any delete it observes, but a
        // file can vanish in the race between that walk and this report. On the
        // watcher-clean path a live watcher has tombstoned every delete, so trust
        // it (microsecond no-stat path); otherwise confirm each matched path still
        // exists (a cheap stat per hit) so a just-removed file is never reported.
        var acc = Accumulator{
            .mode = req.mode,
            .arena = arena,
            .io = self.io,
            .verify_existence = !self.clean.load(.acquire),
        };
        try self.answer(&acc, &cq, &sc);

        if (req.mode == .files) std.mem.sort([]const u8, acc.files.items, {}, lessPath);
        return .{ .mode = req.mode, .files = acc.files.items, .count = acc.count };
    }

    /// Answer a bare `gist <pattern>` (`.lines`) request: the default
    /// `path:text` / `-n` `path:line:text` presentation, pre-rendered into one
    /// buffer through the cold engine's OWN Emitter (`render.zig`) so the bytes
    /// cannot drift from a piped cold run. Same reconcile + freshness barrier +
    /// trigram prefilter + fail-closed existence check as `query`; docs render
    /// in the warm canonical `pathLess` file order (see `DocRef.less`); binary
    /// docs get cold's exact NUL-cut policy. `arena` owns the returned bytes.
    /// A pattern outside the linear
    /// engine (or a mid-render OOM) is `error.Stale`/`OutOfMemory` → the daemon
    /// declines and the client answers cold.
    pub fn queryLines(self: *ResidentSession, arena: std.mem.Allocator, req: Request) QueryError!Lines {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        var cq = CompiledQuery.compile(self.gpa, .{
            .pattern = req.pattern,
            .mode = .files, // the whole-doc gate; presentation is render's job
            .fixed = req.fixed,
            .ignore_case = req.ignore_case,
        }) catch return QueryError.Stale;
        defer cq.deinit(self.gpa);
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        // Admit every doc (binary included — the renderer applies cold's cut).
        // The whole-doc gate over full bytes is a sound superset: a binary doc
        // whose only match sits past its NUL buffer renders to nothing, exactly
        // as cold's emit loop produces nothing for it.
        const docs = try self.matchingDocs(arena, &cq, &sc, .lines);
        const rdocs = try arena.alloc(render.Doc, docs.len);
        for (docs, rdocs) |d, *r| r.* = .{ .path = d.path, .bytes = d.bytes, .nul = d.nul };

        var out: std.ArrayList(u8) = .empty;
        const matched = render.renderLines(arena, req, rdocs, &out) catch |e| switch (e) {
            error.OutOfMemory => return QueryError.OutOfMemory,
            error.Unsupported => return QueryError.Stale,
        };
        return .{ .out = out.items, .matched = matched };
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
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.reconcile();

        // Mode is irrelevant to span emission — compile the cheap `files` body.
        var cq = CompiledQuery.compile(self.gpa, .{
            .pattern = req.pattern,
            .mode = .files,
            .fixed = req.fixed,
            .ignore_case = req.ignore_case,
        }) catch return QueryError.Stale;
        defer cq.deinit(self.gpa);
        // Two per-query scratches: the boolean sim is the whole-doc reject gate,
        // the span VM only ever fires on a doc already proven to match. A trigram
        // candidate set is a SUPERSET (false positives, plus the alternation
        // cover's over-approximation), so gating each doc with the cheap
        // `docMatches` — the SAME `-l` decision `query` uses — keeps the expensive
        // per-line span scan (and the sort, and the existence stat) off every
        // non-matching candidate. This is what pulls the stream path to the
        // files/count path's efficiency instead of span-scanning the whole superset.
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();
        var msc = cq.matchScratch(self.gpa) catch return QueryError.OutOfMemory;
        defer msc.deinit();

        const docs = try self.matchingDocs(arena, &cq, &sc, .json_stream);

        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(self.gpa);
        var any = false;
        for (docs) |d| {
            const o = try emitDoc(self.gpa, &cq, &msc, &spans, d, sink);
            any = any or o.matched;
            if (o.halt) break; // sink asked to stop — leave the rest unscanned
        }
        return any;
    }

    /// Gather the MATCHING docs (base ∪ overlay − tombstones) into a path-sorted
    /// slice, shared by the `lines` renderer and the FFI record stream. A doc is
    /// admitted only after it clears the whole-doc gate (the SAME `-l` decision
    /// `query` uses), so the result holds real matches only; off the
    /// watcher-clean path a matching doc is then existence-checked (the same
    /// fail-closed stat-per-hit `query` uses) so a file removed in the
    /// walk→report window is never reported. `admit` selects the binary policy
    /// (see `Admit`). The sort is `run.pathLess` — the warm canonical file
    /// order (see `DocRef.less`) — so downstream output is deterministic.
    fn matchingDocs(self: *ResidentSession, arena: std.mem.Allocator, cq: *const CompiledQuery, sc: *Scratch, admit: Admit) QueryError![]const DocRef {
        const check_exists = !self.clean.load(.acquire);
        var docs: std.ArrayList(DocRef) = .empty;
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand = try self.candidateIds(cq, &cand_buf);
        for (cand) |id| {
            const path = self.mir.paths[id];
            if (self.overlay.contains(path)) continue; // overlay handled below
            try considerDoc(&docs, arena, .{ .path = path, .bytes = self.mir.docs[id], .nul = self.mir.nuls[id] }, cq, sc, admit, check_exists, self);
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| try considerDoc(&docs, arena, .{ .path = e.key_ptr.*, .bytes = d.bytes, .nul = d.nul }, cq, sc, admit, check_exists, self),
        };
        std.mem.sort(DocRef, docs.items, {}, DocRef.less);
        return docs.items;
    }

    /// Prune candidates with the compiled query's sound trigram prefilter (a
    /// single required literal → `queryLiteral`; an alternation cover →
    /// `queryAny`; nothing prunable → every doc), then verify each with the
    /// shared match kernel. Overlay docs (changed/new since the build) are always
    /// verified directly — the index is stale for exactly those.
    fn answer(self: *ResidentSession, acc: *Accumulator, cq: *const CompiledQuery, sc: *Scratch) QueryError!void {
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand = try self.candidateIds(cq, &cand_buf);
        for (cand) |id| {
            if (self.overlay.contains(self.mir.paths[id])) continue; // handled below
            try acc.consider(self.mir.paths[id], self.mir.docs[id], self.mir.nuls[id], cq, sc, acc.verify_existence);
        }
        try self.considerOverlay(acc, cq, sc);
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
        if (pf.len == 1) {
            if (self.idx.queryLiteral(self.gpa, pf[0])) |c| {
                buf.* = c;
                return c;
            } else |_| {}
        } else if (pf.len > 1) {
            if (self.idx.queryAny(self.gpa, pf)) |c| {
                buf.* = c;
                return c;
            } else |_| {}
        }
        return try self.allDocIds(buf);
    }

    /// Verify the mutation overlay (changed base docs + brand-new files) directly
    /// — the index is stale for exactly these, so they never rely on it.
    fn considerOverlay(self: *ResidentSession, acc: *Accumulator, cq: *const CompiledQuery, sc: *Scratch) QueryError!void {
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            // A reconcile tombstones any overlay path that left the walk set, but
            // (as for base docs) a delete can still race the walk→report window.
            // Off the watcher-clean path, existence-check the match (same
            // fail-closed stat-per-hit the base docs use); the clean path already
            // tombstoned any delete, so it keeps the microsecond no-stat path.
            .doc => |d| try acc.consider(e.key_ptr.*, d.bytes, d.nul, cq, sc, acc.verify_existence),
        };
    }

    fn allDocIds(self: *ResidentSession, buf: *?[]u32) QueryError![]const u32 {
        const all = try self.gpa.alloc(u32, self.mir.docs.len);
        for (all, 0..) |*x, i| x.* = @intCast(i);
        buf.* = all;
        return all;
    }
};

/// Does `path` still exist right now? The fail-closed stat-per-hit every
/// answer face applies off the watcher-clean path — one definition, so the
/// fold accumulator and the doc gather can never drift on this check.
fn fileExists(io: std.Io, path: []const u8) bool {
    _ = Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// One `matchingDocs` admission decision: binary policy, whole-doc gate,
/// existence check, append. Free function (not a method) so the hot loop's
/// shape is explicit at both call sites.
fn considerDoc(docs: *std.ArrayList(DocRef), arena: std.mem.Allocator, d: DocRef, cq: *const CompiledQuery, sc: *Scratch, admit: Admit, check_exists: bool, session: *const ResidentSession) QueryError!void {
    // Cold `--json` skips a doc its 8 KiB `isBinary` window flags; a doc whose
    // first NUL sits past the window is streamed in full. Match that exactly.
    if (admit == .json_stream and d.nul != null and corpus_mod.isBinary(d.bytes)) return;
    if (!cq.docMatches(d.bytes, sc)) return; // trigram false positive / no match
    if (check_exists and !fileExists(session.io, d.path)) return;
    try docs.append(arena, d);
}

/// One doc's emission outcome: whether it had a matching line, and whether the
/// sink asked to halt the whole stream on one of them.
const DocEmit = struct { matched: bool, halt: bool };

/// Emit every matching LINE of one doc to `sink`, ascending by line number,
/// over rg's line model (`\n` terminates, no phantom final line). `spans` is a
/// caller-owned per-line buffer, cleared and refilled per line so no allocation
/// survives the call. Stops at the line where the sink returns `true`, reporting
/// the halt so the caller ends the whole stream. `matchingDocs(.json_stream)`
/// admits only non-empty docs cold `--json` would search, so the binary/empty
/// skips that path applies are already upstream.
fn emitDoc(gpa: std.mem.Allocator, cq: *const CompiledQuery, msc: *MatchScratch, spans: *std.ArrayList(Span), d: DocRef, sink: anytype) error{OutOfMemory}!DocEmit {
    var any = false;
    var pos: usize = 0;
    var lineno: u64 = 0;
    while (pos < d.bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, d.bytes, pos, '\n');
        const end = nl orelse d.bytes.len;
        lineno += 1;
        const view = d.bytes[pos..end];
        spans.clearRetainingCapacity();
        try cq.collectSpans(gpa, view, msc, spans);
        if (spans.items.len > 0) {
            any = true;
            if (sink.emit(.{ .path = d.path, .line_number = lineno, .text = view, .spans = spans.items }))
                return .{ .matched = true, .halt = true };
        }
        if (nl == null) break;
        pos = end + 1;
    }
    return .{ .matched = any, .halt = false };
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
    files: std.ArrayList([]const u8) = .empty,
    count: u64 = 0,

    fn consider(self: *Accumulator, path: []const u8, bytes: []const u8, nul: ?usize, cq: *const CompiledQuery, sc: *Scratch, check_exists: bool) QueryError!void {
        switch (self.mode) {
            .files => {
                // Binary `-l` observes only complete buffers before the one that
                // revealed the first NUL (`grepfile.handleBinary` files_only) —
                // a match past the cut must not turn the file into a false path.
                const gated = if (nul) |n| bytes[0 .. (n / grepfile.BUFCAP) * grepfile.BUFCAP] else bytes;
                if (gated.len == 0) return; // NUL in the first buffer ⇒ cold sees zero lines
                if (!cq.docMatches(gated, sc)) return;
                if (check_exists and !fileExists(self.io, path)) return;
                try self.files.append(self.arena, path);
            },
            .count => {
                // Cold `-c` suppresses an implicit binary file entirely (rg
                // scans, detects the NUL, drops the count) — whole-body NUL,
                // exactly the offset the mirror recorded at ingest.
                if (nul != null) return;
                const n = cq.countLines(bytes, sc);
                if (n == 0) return;
                if (check_exists and !fileExists(self.io, path)) return;
                self.count += n;
            },
            // The lines presentation never routes through the fold — `query`
            // rejects it up front and `queryLines` renders via `render.zig`.
            .lines => unreachable,
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
    const buf = Dir.cwd().readFileAlloc(io, persist.generation_file, gpa, .limited(128)) catch
        return gpa.alloc(u8, 0);
    const trimmed = std.mem.trimEnd(u8, buf, "\r\n");
    if (trimmed.len == buf.len) return buf;
    defer gpa.free(buf);
    return gpa.dupe(u8, trimmed);
}
