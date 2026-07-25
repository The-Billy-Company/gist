// MONOLITHIC: warm-session engine — the freshness seqlock, reconcile overlay, and the three answer faces (fold, lines, record stream) share one ward-guarded session state
//! gist resident session — the warm, in-memory search engine (ADR-352 rung 2.5).
//!
//! A `ResidentSession` owns the corpus bytes + trigram index for one repository,
//! held warm across many queries so an eligible request (`request.zig`) answers
//! without re-paying the process + index-mmap + candidate-read startup the cold
//! subprocess pays every call. It lowers each request through the shared search
//! core (`kernel/match/query.zig`) — the SAME compile → trigram-prefilter → match
//! kernels the cold CLI is built on — driven directly over the warm corpus, so
//! the warm and cold answers cannot drift. Because that core **returns errors**
//! (`error.Unsupported`) instead of calling `die()`, a bad request surfaces here
//! as `error.Stale` (→ cold fallback) and can never terminate the daemon — the
//! exact hazard ADR-352 defers the C FFI on.
//!
//! ## The corpus is a faithful mirror
//!
//! Base docs load through `corpus.zig` as a TWO-TIER byte store: an unchanged
//! member binds its bytes to the persisted `content.shard` mmap (zero heap,
//! page-cache-evictable), and only a changed/new/binary/oversize/BOM-carrying
//! doc — or the whole corpus when no shard is on disk — heap-reads. Either tier
//! yields the SAME faithful ingest a cold run applies: full body (no cap),
//! BOM/UTF-16 decode, whole-body first-NUL offsets, empty docs dropped, so
//! resident heap drops from O(corpus) to O(churn + exceptions) with no answer
//! drift. Binary docs are ADMITTED (cold does not skip a walked
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
//! set from the cold path's OWN certified walk (`surface/exec/cold/engine/serial.zig::
//! defaultFileSet` — hidden-file exclusion, `.gitignore`/`.ignore` precedence,
//! `.git` skip, root scope), never `haystack`'s coarse superset. The warm set is
//! therefore byte-identical to what a rootless `gist <pattern>` would walk:
//!
//!   - A query is answered from resident bytes directly ONLY when the freshness
//!     barrier proves the roots quiescent since the last reconcile — a
//!     watcher-clean window (`markClean`/`markDirty`, driven by inotify on Linux
//!     / kqueue on macOS; `src/surface/exec/session/watch.zig`). This is the microsecond path.
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
//! Concurrent reads overlap under a shared `Ward` lease
//! (`kernel/primitives/ward.zig`) while a reconcile runs alone under the
//! exclusive lease; the watcher only ever touches the shared `Seqlock`
//! (`seqlock.zig`), never the overlay, so the barrier is a lock-free seqlock
//! over a ward-guarded engine.

const std = @import("std");
const builtin = @import("builtin");
const assay = @import("../../../assay/assay.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const bulkstat = @import("../../../corpus/tree/bulkstat.zig");
const corpus = @import("corpus.zig");
const render = @import("render.zig");
const parallel = @import("../../../kernel/primitives/parallel.zig");
const Ward = @import("../../../kernel/primitives/ward.zig").Ward;
// The resident file set is the certified rg-default walk the cold path uses, NOT
// `haystack`'s coarse superset — this is what makes `resident == --no-index ==
// rg` true for hidden files, `.gitignore` precedence, and root scope. `session`
// depending on `surface/exec/cold` is a one-way edge (serial.zig never imports
// session), so no import cycle.
const run = @import("../cold/engine/serial.zig");
// The parallel fused walk (`parallel.zig`), reached ONLY through its callable
// `collectFileSet` — the full-reconcile file set via the same work-stealing
// getattrlistbulk walk the cold `--files` path uses, ~3x faster than the serial
// `defaultFileSet` readdir walk. Named `pengine` because `parallel` above binds
// the kernel thread-pool primitive. One-way edge (cold never imports session).
const pengine = @import("../cold/engine/parallel.zig");
// The gist-native `--rank` kernel (`ranked.zig`): its `renderLive` extracts
// features over in-memory `LiveFile`s, fuses via RRF, and renders the top-K —
// the SAME emission cold's `runLive` produces, returned to buffer instead of
// stdout. A one-way edge (ranked never imports session), so no cycle.
const ranked = @import("../cold/engine/ranked.zig");
const grepfile = @import("../cold/read/grepfile.zig");
const dirtylog = @import("dirty.zig");
const annalslog = @import("annals.zig");
const Seqlock = @import("seqlock.zig").Seqlock;
const delta_mod = @import("delta.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const Index = @import("../../../corpus/index/trigrams/trigram.zig").Index;
const query_mod = @import("../../../kernel/match/query.zig");
// Path-scope predicate (`underRoot`/`normalizeRoot`) — the served-scope subset
// check reuses the exact primitive the request `PathFilter` prunes with.
const scope = @import("../../../corpus/scope/glob.zig");
const CompiledQuery = query_mod.CompiledQuery;
const Scratch = query_mod.Scratch;
const MatchScratch = query_mod.MatchScratch;
const Span = query_mod.Span;
const request = @import("request.zig");
const Dir = std.Io.Dir;

/// A case-INsensitive filesystem (macOS APFS/HFS+) folds ASCII case AND Unicode
/// normalization (NFC/NFD) to one on-disk spelling, so a scoped reconcile there
/// must sweep the corpus's non-ASCII keys against the `realpath` oracle to catch
/// a stale twin the ASCII fold can't equate. Linux only ever scopes over
/// case-SENSITIVE (byte-exact) roots (watch.zig gates casefold roots to coarse),
/// so no sweep is needed and the set stays unused (zero cost).
const is_macos = builtin.os.tag == .macos;

pub const Mode = request.Mode;
pub const Request = request.Request;
/// The resolved path-scope a request confines its answer to (roots today) — the
/// candidate walk prunes/gates with it; empty is the rootless whole-corpus search.
const PathFilter = request.PathFilter;

/// Budget checkpoints are strided: `overBudget` reads the clock only when the
/// caller's loop index masks to zero against this power-of-two-minus-one, so a
/// budgeted scan of a huge candidate set pays ~one clock read per 1024 visits.
const budget_stride: usize = 1023;

pub const QueryError = error{
    /// The session cannot prove freshness (no valid build anchor, or the index
    /// was rebuilt out from under it and could not be reloaded) — answer cold.
    Stale,
    OutOfMemory,
};

/// A cooperative, thread-safe cancellation flag, shared by reference into a
/// search's `RunBudget`. Any thread may `cancel()` while the engine scans; the
/// scan observes it at a strided gather checkpoint AND at every record boundary
/// (the hosted collector) and stops cleanly, keeping whatever it gathered. Bare
/// atomic-builtin bool so it needs no allocation and no std version pin. The
/// hosted `api.CancelToken` is this type — it lives with the engine core it
/// bounds, not the veneer that names it.
pub const CancelToken = struct {
    flag: bool = false,

    pub fn cancel(self: *CancelToken) void {
        @atomicStore(bool, &self.flag, true, .seq_cst);
    }

    pub fn requested(self: *const CancelToken) bool {
        return @atomicLoad(bool, &self.flag, .seq_cst);
    }

    pub fn reset(self: *CancelToken) void {
        @atomicStore(bool, &self.flag, false, .seq_cst);
    }
};

/// A per-search cooperative halt the DOC GATHER honors so a scan that emits few
/// or no records (a rare pattern, an invert walk, a `-l` superset that mostly
/// fails the whole-doc gate) still respects a hosted `cancel` / `timeout_ns`
/// instead of running the whole corpus first. Distinct from the daemon's
/// `query_budget_ns` ceiling (which DECLINES to the certified cold path via
/// `Stale`): a gather halt is a CLEAN partial stop — the docs gathered so far
/// stand, no `Stale` is raised — mirroring the record-boundary budget the
/// hosted collector already applies at emit. Empty (both null) for the daemon
/// and FFI-callback faces, whose completeness is guarded by the session ceiling
/// instead, so the check compiles away for them.
pub const RunBudget = struct {
    cancel: ?*const CancelToken = null,
    /// Absolute monotonic (`.awake`) deadline in ns; null = no wall-clock cap.
    deadline_ns: ?i128 = null,
};

/// The per-query wall-clock ceiling — computed once under the lock at the top of
/// each query and threaded down the O(corpus) walks as a VALUE, not session
/// state, so concurrent readers each carry their own deadline (the reader/writer
/// session runs many folds at once). `deadline_ns` is an absolute `.awake`
/// instant; 0 disables the ceiling (the embedder/FFI/test default), which
/// short-circuits before any clock read. Distinct from `RunBudget`, the hosted
/// record stream's cooperative CLEAN halt: an overrun here DECLINES the query
/// (→ certified cold path via `Stale`), it is the daemon's liveness backstop.
pub const Ceiling = struct {
    deadline_ns: i128 = 0,

    /// Has this query overrun its ceiling? Sampled at strided checkpoints in the
    /// O(corpus) walks — the caller passes its loop index, so the clock is read
    /// at most once per `budget_stride` visits (amortized to noise; the fast
    /// path returns before the first sample for a small candidate set). An
    /// unbudgeted query short-circuits before any clock read. Each parallel
    /// shard walks its own contiguous range with its own index, so the read-only
    /// deadline is sampled independently per shard.
    inline fn over(self: Ceiling, io: std.Io, i: usize) bool {
        if (self.deadline_ns == 0) return false;
        if (i & budget_stride != 0) return false;
        return std.Io.Clock.now(.awake, io).nanoseconds >= self.deadline_ns;
    }
};

/// One eligible query's answer. `files` are duped into the caller's per-query
/// arena (see `ownFiles`), so they own their bytes rather than aliasing session
/// memory — the caller may release the session read lock before encoding the
/// answer, which is what lets concurrent readers overlap.
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
/// stream (`surface/exec/cold/emit/json.zig`).
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
/// comparator uses (`surface/exec/cold/engine/serial.zig::cmpFiles`). Cold's default
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

    /// Reader/writer discipline (ADR-352 rung 2.5): `reconcile` (overlay
    /// mutation, `maybeReload` engine swap, `fresh_ns` + counter bumps) is the
    /// WRITER; all five answer faces are READERS over the then-immutable mirror +
    /// overlay. Concurrent warm queries thus overlap — the whole point of the
    /// daemon worker pool — while a reconcile still runs alone. `beginRead` owns
    /// the fast-clean-read / drop-to-write / reconcile / drop-to-read dance,
    /// which the `Ward` (`kernel/primitives/ward.zig`) gathers into one
    /// double-checked primitive — `beginRead` just supplies the freshness
    /// predicate and the reconcile. Writer-preferring (a queued reconcile can't
    /// be starved by a stream of readers) over the same `io` seam the mutex used.
    ward: Ward = .{},
    /// The freshness barrier: the watcher-driven seqlock (event counter, clean
    /// witness, permanent-doubt latch) whose subtle memory ordering lives once
    /// in `seqlock.zig`. Without a live watcher it never proves clean, so every
    /// query reconciles (correct, just not microsecond-fast).
    seqlock: Seqlock = .{},

    /// The exact dirty-path hand-off from a path-reporting watcher backend
    /// (Linux inotify · macOS kqueue). When its drain is exact and doubt-free,
    /// the reconcile verifies ONLY the drained paths — O(changed), not O(tree).
    dirty_log: dirtylog.DirtyLog,
    /// The never-drained sibling ledger: every exact watcher delivery accretes
    /// as `path → last delivery instant`, so a one-shot `gist index` amend can
    /// dial in and ask "what changed since anchor S?" without a stat walk.
    /// Armed by the watcher (single-root watches only, for one unambiguous
    /// prefix); fail-closed everywhere else (`annals.zig`). Like `dirty_log`, it
    /// belongs to the SESSION's lifetime, not an index generation — reloads
    /// leave it untouched.
    annals: annalslog.Annals,
    /// A scoped reconcile is sound only downstream of one full walk that
    /// overlapped the live event stream (the watcher arms before the first
    /// query, so the first reconcile is always the covering full pass).
    full_pass_done: bool = false,
    /// Observability + test hooks: how many reconciles took each path. Atomic
    /// because the daemon's poll thread samples them (for its operator `note`
    /// line) while a worker mutates them under the write lock (the increments
    /// themselves are serialized by that lock; the atomicity is for the reader).
    scoped_reconciles: std.atomic.Value(u64) = .init(0),
    full_reconciles: std.atomic.Value(u64) = .init(0),

    /// macOS only: the live corpus keys carrying a byte ≥ 0x80 (owned dupes,
    /// independent of base/overlay key lifetimes). A scoped reconcile on a
    /// case-insensitive fs re-verifies exactly this (almost always empty) set
    /// through `keyIsCurrent`, tombstoning a stale Unicode normalization/case
    /// TWIN of a path the batch never named — the one aliasing the ASCII fold
    /// in `applyGones`/`applySubtree` cannot model. Maintained at the single
    /// overlay chokepoint (`putOverlay`) and rebuilt on reload; unused (empty)
    /// on every other target, where the fs is byte-exact.
    nonascii_keys: std.StringHashMapUnmanaged(void) = .empty,

    /// The reachable file-level un-hide/un-ignore candidates the certified
    /// default walk SKIPPED (`serial.zig::Extra`): hidden dotfiles and directly
    /// gitignored leaves whose parent directory the walk still descended. These
    /// are EXACTLY the files a `-t`/`-g` query surfaces (rg / cold) but the
    /// mirror — built from the same hidden/ignore-excluding walk — cannot supply.
    /// `declineForExtras` consults this list to fail a filtered warm query over
    /// to the certified cold path, restoring `resident == --no-index == rg` for
    /// `-t`/`-g`. Owned by `extras_arena` (rebuilt whole on refresh → arena reset).
    extras: []const run.Extra = &.{},
    extras_arena: std.heap.ArenaAllocator,
    /// A scoped reconcile (O(changed)) does NOT recompute `extras`, so a filtered
    /// query afterward cannot trust the list — `declineForExtras` forces one full
    /// extras walk (`ensureExtrasFresh`) before deciding; a full reconcile clears
    /// it. Quiescent trees (watcher-clean) keep whatever the last reconcile set,
    /// so a `-t`/`-g` query pays the refresh only right after a real change. Set
    /// only under the write lock, read only under the read lock (no torn access).
    extras_stale: bool = false,

    /// Monotonic per-daemon-boot id, echoed to clients so they can detect a
    /// restarted daemon and re-handshake. Assigned by the server.
    daemon_gen: u64 = 0,

    /// Per-query wall-clock ceiling in nanoseconds (0 ⇒ disabled — the default
    /// for every embedder/FFI/test session, so their behavior is unchanged).
    /// The resident daemon sets it (see `serve.zig`) so one runaway — or a query
    /// a client already timed out and abandoned — can't pin the single daemon
    /// thread the ~10 coworker agents share. It is a liveness backstop, not a
    /// latency SLA: no legitimate local warm query approaches it, and overrunning
    /// it declines the query (→ certified cold path), never a wrong answer.
    query_budget_ns: i128 = 0,
    /// Observability: how many queries the budget declined. Atomic because the
    /// abort can fire inside a parallel fold/stream shard.
    budget_aborts: std.atomic.Value(u64) = .init(0),

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
        // The un-hide/un-ignore extras (see the `extras` field) are captured from
        // this SAME walk and duped into a session-lived arena, so the very first
        // filtered query already decides against a real list, no cold-start walk.
        var extras_arena = std.heap.ArenaAllocator.init(gpa);
        errdefer extras_arena.deinit();
        var owned_extras: []const run.Extra = &.{};
        var mir = blk: {
            var sel_arena = std.heap.ArenaAllocator.init(gpa);
            defer sel_arena.deinit();
            var sel_extras: []const run.Extra = &.{};
            const sel = run.defaultFileSetExtras(sel_arena.allocator(), io, owned_roots, &sel_extras);
            owned_extras = try dupeExtras(extras_arena.allocator(), sel_extras);
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

        // Seed the non-ASCII key sweep set (macOS only; empty elsewhere) from the
        // base mirror, so the very first scoped reconcile already covers a stale
        // normalization/case twin among the loaded corpus keys.
        var nonascii = try buildNonAscii(gpa, mir.paths);
        errdefer freeNonAscii(&nonascii, gpa);

        return .{ .gpa = gpa, .io = io, .roots_arena = roots_arena, .roots = owned_roots, .mir = mir, .idx = idx, .by_path = by_path, .index_gen = gen, .fresh_ns = load_ns, .overlay = std.StringHashMap(Overlay).init(gpa), .dirty_log = dirtylog.DirtyLog.init(gpa), .annals = annalslog.Annals.init(gpa), .extras = owned_extras, .extras_arena = extras_arena, .nonascii_keys = nonascii };
    }

    /// Does this daemon serve no explicit scope — the bare `gist serve` whole-CWD
    /// tree? Then its mirror is the full corpus and admits any relative subtree.
    fn rootless(self: *const ResidentSession) bool {
        return self.roots.len == 0 or
            (self.roots.len == 1 and (self.roots[0].len == 0 or std.mem.eql(u8, self.roots[0], ".")));
    }

    /// May this daemon answer a request scoped to `req_roots`? A rootless query
    /// (no roots) is served over whatever this daemon mirrors — the unchanged
    /// bare-`gist` behavior, independent of how the daemon was launched. A SCOPED
    /// query is sound only when its mirror is a superset of the requested roots:
    /// a rootless daemon mirrors the whole CWD tree and admits any relative root,
    /// while an explicitly-scoped daemon admits a scoped query only when every
    /// requested root lies at/under one of its served roots (else its mirror is
    /// missing files cold would search — decline → certified cold).
    pub fn servesScope(self: *const ResidentSession, req_roots: []const []const u8) bool {
        if (req_roots.len == 0 or self.rootless()) return true;
        for (req_roots) |rr| {
            const nr = scope.normalizeRoot(rr);
            for (self.roots) |sr| {
                if (scope.underRoot(nr, scope.normalizeRoot(sr))) break;
            } else return false;
        }
        return true;
    }

    pub fn deinit(self: *ResidentSession) void {
        self.annals.deinit();
        self.dirty_log.deinit();
        self.clearOverlay();
        self.overlay.deinit();
        freeNonAscii(&self.nonascii_keys, self.gpa);
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.mir.deinit();
        self.extras_arena.deinit();
        self.roots_arena.deinit();
    }

    /// True when `s` carries any byte outside 7-bit ASCII — the keys the scoped
    /// reconcile's ASCII fold cannot canonicalize, and thus the ones the sweep
    /// must re-verify against the `realpath` oracle on a case-insensitive fs.
    fn hasNonAscii(s: []const u8) bool {
        for (s) |b| if (b >= 0x80) return true;
        return false;
    }

    /// Build the non-ASCII key set (owned dupes) from a path list — a no-op
    /// returning empty off macOS, where the fs is byte-exact and no sweep runs.
    fn buildNonAscii(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
        var set: std.StringHashMapUnmanaged(void) = .empty;
        if (comptime !is_macos) return set;
        errdefer freeNonAscii(&set, gpa);
        for (paths) |p| if (hasNonAscii(p)) {
            const owned = try gpa.dupe(u8, p);
            set.put(gpa, owned, {}) catch |e| {
                gpa.free(owned);
                return e;
            };
        };
        return set;
    }

    /// Free every owned key and the set itself.
    fn freeNonAscii(set: *std.StringHashMapUnmanaged(void), gpa: std.mem.Allocator) void {
        var it = set.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        set.deinit(gpa);
        set.* = .empty;
    }

    /// Keep the non-ASCII key set in step with one overlay mutation: a `.doc`
    /// makes a non-ASCII key live (tracked), a `.tombstone` retires it. Zero
    /// cost off macOS and for the ASCII-only common case. A tracking OOM
    /// propagates so the reconcile declines to cold rather than sweep an
    /// incomplete set (fail-closed).
    fn trackNonAscii(self: *ResidentSession, path: []const u8, live: bool) std.mem.Allocator.Error!void {
        if (comptime !is_macos) return;
        if (!hasNonAscii(path)) return;
        if (live) {
            if (self.nonascii_keys.contains(path)) return;
            const owned = try self.gpa.dupe(u8, path);
            self.nonascii_keys.put(self.gpa, owned, {}) catch |e| {
                self.gpa.free(owned);
                return e;
            };
        } else if (self.nonascii_keys.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
        }
    }

    /// Dupe an `Extra` slice (path bytes + kind) into `a` — the session-lived
    /// copy of the walk-arena list, so it survives the walk arena's teardown.
    fn dupeExtras(a: std.mem.Allocator, src: []const run.Extra) std.mem.Allocator.Error![]const run.Extra {
        const out = try a.alloc(run.Extra, src.len);
        for (src, out) |s, *d| d.* = .{ .rel = try a.dupe(u8, s.rel), .kind = s.kind };
        return out;
    }

    /// Replace `extras` with a freshly-walked list, resetting the owning arena,
    /// and clear the scoped-staleness latch. Writer-only (`reconcileFull` and
    /// `ensureExtrasFresh`).
    fn setExtras(self: *ResidentSession, src: []const run.Extra) QueryError!void {
        _ = self.extras_arena.reset(.retain_capacity);
        self.extras = dupeExtras(self.extras_arena.allocator(), src) catch return QueryError.OutOfMemory;
        self.extras_stale = false;
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

    /// Set the overlay for `path`, freeing any prior value and reusing the key,
    /// and keep the non-ASCII sweep set in step (`.doc` ⇒ live, `.tombstone` ⇒
    /// retired) — the single overlay chokepoint every mutation flows through.
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
        try self.trackNonAscii(path, ov == .doc);
    }

    // ── watcher hooks (called from the watch thread; lock-free) ──

    /// A filesystem event arrived: the next query must reconcile. A backend
    /// that reports exact paths `note`s them into `dirty_log` FIRST, so any
    /// event counted by a reconcile's pre-drain seq read is already visible
    /// to that drain.
    pub fn markDirty(self: *ResidentSession) void {
        self.seqlock.markDirty();
    }

    /// The watcher lost event coverage it cannot win back (inotify queue
    /// overflow, an unwatchable new directory): permanently disable the clean
    /// fast path. Every later query reconciles — slower, never stale.
    pub fn markDoubtForever(self: *ResidentSession) void {
        self.seqlock.markDoubtForever();
    }

    /// Declare that a watcher is live and proving quiescence.
    pub fn armWatcher(self: *ResidentSession) void {
        self.seqlock.arm();
    }

    /// The watcher gave its coverage back on purpose — an idle daemon releasing
    /// one descriptor per watched vnode (`watch.zig::shed`). Every later query
    /// reconciles fully, and the scoped path's three preconditions are all
    /// withdrawn with the stream that justified them: the fast path closes
    /// (`seqlock`), the exactness promise lapses (`dirty_log`), and the covering
    /// full pass is spent — so when a watcher arms again the first pass under it
    /// is the full one, exactly as at boot. Reversible, unlike `markDoubtForever`.
    /// Caller must hold the session quiescent (`serve.zig` sheds only with zero
    /// connections and nothing in flight).
    pub fn disarmWatcher(self: *ResidentSession) void {
        self.seqlock.disarm();
        self.dirty_log.disarmExact();
        self.full_pass_done = false;
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
        // The watcher notes into THIS session's log + annals; the replacement's
        // own (empty) pair is surplus. `full_pass_done` survives: the event
        // stream ran across the rebuild, so init's fresh corpus read IS a
        // covering full pass and pending events stay queued for the next drain.
        fresh.dirty_log.deinit();
        fresh.annals.deinit();

        // Free only the stale DATA.
        self.clearOverlay();
        self.overlay.deinit();
        freeNonAscii(&self.nonascii_keys, self.gpa);
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.mir.deinit();
        self.extras_arena.deinit();
        self.roots_arena.deinit();

        // Move the fresh engine's data fields into place, field-by-field, and
        // leave the synchronization + identity fields alone: the `ward` is HELD
        // exclusively by the caller (reconcile is the writer; a whole-struct
        // `self.* = fresh` would reset it, dropping the write lock out from under
        // the caller's `defer`); the `seqlock` (event counter, clean witness,
        // arm/poison state) stays monotonic; `gpa`/`io`/`daemon_gen` are
        // unchanged. `fresh`'s own ward/seqlock/identity are
        // default-initialized and unused, and every owning field has been moved
        // out of it, so it needs no deinit.
        self.roots_arena = fresh.roots_arena;
        self.roots = fresh.roots;
        self.mir = fresh.mir;
        self.idx = fresh.idx;
        self.by_path = fresh.by_path;
        self.index_gen = fresh.index_gen;
        self.fresh_ns = fresh.fresh_ns;
        self.overlay = fresh.overlay;
        // The rebuilt corpus carries its own freshly-seeded non-ASCII key set.
        self.nonascii_keys = fresh.nonascii_keys;
        // The fresh init re-walked the extras from the rebuilt corpus (fresh and
        // authoritative); move the arena + list and drop the scoped-stale latch.
        self.extras_arena = fresh.extras_arena;
        self.extras = fresh.extras;
        self.extras_stale = fresh.extras_stale;

        self.markDirty(); // a rebuilt index demands a reconcile pass
    }

    /// Build this query's wall-clock ceiling from the configured budget — a
    /// disabled ceiling when unbudgeted (the embedder/FFI/test default), which
    /// skips every clock read. Called under the session lock at the top of each
    /// query and threaded into `reconcile` + the fold/gather walks, so one value
    /// spans the whole query without any shared session field the concurrent
    /// readers would race.
    fn ceiling(self: *const ResidentSession) Ceiling {
        return .{ .deadline_ns = if (self.query_budget_ns != 0)
            std.Io.Clock.now(.awake, self.io).nanoseconds + self.query_budget_ns
        else
            0 };
    }

    /// Record a budget decline and surface it as `Stale` — the client answers on
    /// the certified cold path exactly as for a lost freshness anchor. Atomic
    /// because a parallel fold/stream shard may be the one that trips the ceiling.
    fn budgetAbort(self: *ResidentSession) QueryError {
        _ = self.budget_aborts.fetchAdd(1, .monotonic);
        return QueryError.Stale;
    }

    /// A held read lease over the fresh session plus this query's wall-clock
    /// ceiling — what `beginRead` hands each answer face, which holds it for the
    /// answer and `held.lease.release()`s on the way out.
    const Held = struct { lease: Ward.Read, ceil: Ceiling };

    /// Acquire the session for READING over a fresh corpus, returning the read
    /// lease + this query's ceiling. On success the caller holds the READ lock
    /// and MUST `held.lease.release()`; on error nothing is held (so a `defer`
    /// registered only after the `try` never runs on the error path).
    ///
    /// The fast/slow dance lives in `Ward.readReconciled` (the double-checked
    /// upgrade): the fast path answers under the read lock when the watcher
    /// proves the tree clean (`seqlock.skip()`) — no writer, no reconcile, where
    /// concurrent warm queries overlap; the slow path drops read, takes WRITE,
    /// reconciles (which re-checks `skip()` at its top, so a writer that raced us
    /// and already brought the tree current makes ours a no-op), and downgrades
    /// back to read. The write→read downgrade gap only admits staleness a
    /// concurrent writer would introduce — already covered by the
    /// `provenClean`-gated existence stat every answer face applies off the clean
    /// path — so a just-deleted file is still never reported.
    fn beginRead(self: *ResidentSession) QueryError!Held {
        const ceil = self.ceiling();
        const Ctx = struct { s: *ResidentSession, c: Ceiling };
        const lease = try self.ward.readReconciled(
            self.io,
            Ctx{ .s = self, .c = ceil },
            struct {
                fn fresh(x: Ctx) bool {
                    return x.s.seqlock.skip(); // watcher-clean witness
                }
            }.fresh,
            struct {
                fn refresh(x: Ctx) QueryError!void {
                    return x.s.reconcile(x.c);
                }
            }.refresh,
        );
        return .{ .lease = lease, .ceil = ceil };
    }

    /// Copy the published index generation under a shared lease so a concurrent
    /// reconcile's `maybeReload` engine swap (which frees + reassigns
    /// `index_gen`) can't free the slice mid-read. The daemon's poll thread
    /// reads this for the READY handshake OFF the query path while worker-pool
    /// threads may be reconciling; `daemon_gen` beside it is boot-constant and
    /// needs no lease. Caller owns the returned dupe.
    pub fn indexGenDup(self: *ResidentSession, a: std.mem.Allocator) ![]u8 {
        const lease = self.ward.read(self.io);
        defer lease.release();
        return a.dupe(u8, self.index_gen);
    }

    /// Re-derive `extras` from one certified default walk (extras-only; the
    /// mirror was already reconciled), replacing the prior list and clearing the
    /// scoped-stale latch. A gapped walk declines (→ cold), like `reconcileFull`.
    /// Writer-only — the caller holds the exclusive lease.
    fn refreshExtras(self: *ResidentSession) QueryError!void {
        var walk_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer walk_arena.deinit();
        var sel_extras: []const run.Extra = &.{};
        const fs = run.defaultFileSetExtras(walk_arena.allocator(), self.io, self.roots, &sel_extras);
        if (fs.path_error) return QueryError.Stale;
        try self.setExtras(sel_extras);
    }

    /// Fail-closed guard for the `Extra` gap (`serial.zig`): a `-t`/`-g` query
    /// un-hides/un-ignores files the mirror — built from the same
    /// hidden/ignore-excluding walk — cannot hold. If any reachable extra would
    /// be surfaced by this request's filter, decline so the client answers on the
    /// certified cold path (which walks them): the flagship "index changes speed,
    /// never results" claim, restored for filtered queries. A request with no
    /// type/glob filter can't surface an extra and returns at once (the common
    /// path pays only two length checks). When a prior scoped reconcile left the
    /// list stale, upgrade the held lease to exclusive, refresh with one walk, and
    /// downgrade back — the double-checked dance `Ward.reconcileHeld` runs — so
    /// `*held` always ends holding a valid read lease and the caller's `defer`
    /// release stays balanced on every path, error included.
    fn guardExtras(self: *ResidentSession, held: *Held, req: Request) QueryError!void {
        if (req.filter.exts.len == 0 and req.filter.includes.len == 0) return;
        const res = self.ward.reconcileHeld(
            held.lease,
            self,
            struct {
                fn fresh(s: *ResidentSession) bool {
                    return !s.extras_stale;
                }
            }.fresh,
            struct {
                fn refresh(s: *ResidentSession) QueryError!void {
                    return s.refreshExtras();
                }
            }.refresh,
        );
        held.lease = res.lease; // always live — the caller's `defer` stays balanced
        if (res.err) |e| return e;
        for (self.extras) |ex| if (req.filter.surfacesHidden(ex.rel, ex.kind == .ignored)) return QueryError.Stale;
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
    fn reconcile(self: *ResidentSession, ceil: Ceiling) QueryError!void {
        try self.maybeReload();
        if (self.seqlock.skip()) return;

        const seq0 = self.seqlock.enter();
        const now = std.Io.Clock.now(.real, self.io).nanoseconds;

        // Drain the exact dirty set (always — even a full walk must consume
        // it, or stale entries would replay forever). The scoped path is taken
        // only when EVERY soundness gate holds: a live watcher whose backend
        // reports exact paths, no doubt (overflow/drop/unclassifiable event),
        // no poison, and one prior full pass that overlapped the stream.
        var drained = self.dirty_log.drain(self.gpa);
        defer drained.deinit(self.gpa);
        const scoped_eligible = self.seqlock.eligible() and
            self.full_pass_done and drained.exact and !drained.doubt;
        const applied = scoped_eligible and try self.reconcileScoped(drained.paths);
        if (applied) {
            _ = self.scoped_reconciles.fetchAdd(1, .monotonic);
            // A scoped pass touched only the changed paths, never the whole-tree
            // extras derivation — so a `-t`/`-g` query must refresh before it can
            // trust the list (`guardExtras` → `refreshExtras`).
            self.extras_stale = true;
        } else {
            try self.reconcileFull(ceil);
            if (self.seqlock.armed()) self.full_pass_done = true;
            _ = self.full_reconciles.fetchAdd(1, .monotonic);
        }

        self.fresh_ns = now;
        // Republish the clean short-circuit only if a watcher is live AND no
        // event raced this reconcile (the seqlock recheck). Without a watcher,
        // `commit` is a no-op and the session stays dirty.
        self.seqlock.commit(seq0);
    }

    /// The O(tree) barrier: re-derive the whole authoritative set and diff it
    /// against base + overlay. Always sound; the scoped path's fallback.
    fn reconcileFull(self: *ResidentSession, ceil: Ceiling) QueryError!void {
        const trace = assay.lit(.reconcile);
        var span: assay.Span = if (trace) assay.Span.open(self.io) else undefined;
        var walk_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer walk_arena.deinit();
        // Re-derive the whole authoritative set through the parallel fused walk
        // (`collectFileSet`) — the same ignore-certified work-stealing
        // getattrlistbulk enumeration the cold `--files` path uses, ~3x faster
        // than the serial readdir walk. Ground truth: no phantom snapshot, so a
        // file created since the last index build is seen. Its `-t`/`-g` extras
        // are NOT gathered here (a files-only walk drops rejected entries), so
        // they are deferred below exactly as the scoped path defers them.
        const fs = pengine.collectFileSet(self.gpa, self.io, self.roots, walk_arena.allocator());
        // An errored walk is a GAPPED set. Cold would report the unreadable
        // directory to stderr and exit 2; serving a clean-looking warm answer
        // over the gap would silently drop its files. Decline (and never mark
        // clean) until a walk completes without error.
        if (fs.walk_error) return QueryError.Stale;
        const cur = fs.entries;
        const walk_dur: assay.Duration = if (trace) span.lap(self.io) else undefined;

        var cur_set = std.StringHashMap(void).init(self.gpa);
        defer cur_set.deinit();
        try cur_set.ensureTotalCapacity(@intCast(cur.len));
        for (cur) |e| cur_set.putAssumeCapacity(e.path, {});

        for (cur, 0..) |e, i| {
            if (ceil.over(self.io, i)) return self.budgetAbort();
            try self.reconcileOne(e.path, e.mtime_ns, e.ctime_ns);
        }
        if (trace) {
            assay.diag("reconcileFull: walk {d:.1} ms ({d} files) · reread {d:.1} ms\n", .{
                walk_dur.ms(), cur.len, span.read(self.io).ms(),
            });
        }
        try self.tombstoneVanished(&cur_set);
        // The parallel files walk yields no `-t`/`-g` extras, so latch them stale
        // (like the scoped path): the next `-t`/`-g` query fail-closed-refreshes
        // via `guardExtras` → `refreshExtras`. Set only after a clean, complete
        // pass — a budget abort above returns first, keeping the prior list.
        self.extras_stale = true;
    }

    /// The O(changed) barrier: verify ONLY the drained watcher paths against
    /// the live tree, with `delta.Delta` re-deriving each membership verdict
    /// through the walk's own ignore machinery. Returns false whenever ANY
    /// resolution cannot be scoped soundly (ignore-source edit, root event,
    /// unmappable path, unreadable directory) — the caller then runs the full
    /// walk. Partial overlay mutations before a false return are harmless: each
    /// only moved a path toward its current on-disk truth, and the full walk
    /// re-derives everything. Non-ASCII paths ARE scoped (the `realpath` oracle
    /// canonicalizes them); a stale normalization/case twin the batch never
    /// named is caught by the closing `sweepNonAscii` on a case-insensitive fs.
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
                .file => |rel| try self.reconcileOne(rel, null, null),
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
        if (comptime is_macos) try self.sweepNonAscii(&dl);
        return true;
    }

    /// Re-verify every live corpus key carrying a byte ≥ 0x80 against the
    /// `realpath` oracle, tombstoning any that is no longer a current,
    /// canonically-spelled member. This is the one aliasing the ASCII fold in
    /// `applyGones`/`applySubtree` can't model: on a case-insensitive fs a stale
    /// Unicode normalization/case TWIN of a path this batch never named (café
    /// NFC vs NFD, café.txt after a case-rename its own event didn't carry) is
    /// invisible to byte/ASCII-fold matching but resolves — through realpath — to
    /// a DIFFERENT on-disk key than it spells. O(|non-ASCII keys|), zero when the
    /// set is empty (the overwhelming common case). macOS-only (the caller gates
    /// it); Linux scopes only byte-exact roots, so no twin can exist.
    fn sweepNonAscii(self: *ResidentSession, dl: *delta_mod.Delta) QueryError!void {
        if (self.nonascii_keys.count() == 0) return;
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.gpa);
        var it = self.nonascii_keys.keyIterator();
        while (it.next()) |k| if (!dl.keyIsCurrent(k.*)) try doomed.append(self.gpa, k.*);
        // `putOverlay(.tombstone)` retires each doomed key FROM the set as it
        // goes; `doomed` holds the distinct backing slices, so this drains the
        // snapshot without mutating the map mid-iteration.
        for (doomed.items) |k| try self.putOverlay(k, .tombstone);
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
        while (it.next()) |k| try self.reconcileOne(k.*, null, null);

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
    /// re-reading an unchanged corpus every query. `mtime_ns`/`ctime_ns` are the
    /// clocks the enumerating walk already captured (`collectFileSet`'s
    /// `getattrlistbulk` listing); null (the scoped/subtree callers) falls back
    /// to one `statFile`. Using the walk-time clocks is sound: `fresh_ns` is
    /// anchored BEFORE the walk (see `reconcile`), so any write the walk didn't
    /// observe is caught on the next pass — the same window `statFile` raced.
    fn reconcileOne(self: *ResidentSession, p: []const u8, mtime_ns: ?i128, ctime_ns: ?i128) QueryError!void {
        if (self.overlay.get(p)) |ov| switch (ov) {
            .tombstone => return self.readInto(p), // reappeared since its delete
            .doc => {}, // already substituted — fall through to the mtime gate
        } else if (!self.by_path.contains(p)) {
            return self.readInto(p); // brand-new file, not in the base corpus
        }
        var mt = mtime_ns;
        var ct = ctime_ns;
        if (mt == null or ct == null) {
            const st = Dir.cwd().statFile(self.io, p, .{}) catch return self.readInto(p);
            mt = st.mtime.nanoseconds;
            ct = st.ctime.nanoseconds;
        }
        if (bulkstat.needsLiveRead(self.fresh_ns, mt, ct)) return self.readInto(p);
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
            // `-P`: compile the regex body through the PCRE2 backend behind the
            // shared `Matcher` seam (lookaround/backreferences the linear engine
            // declines). A pattern PCRE2 rejects surfaces as `error.Stale` →
            // certified cold fallback, exactly like a linear-syntax decline.
            .pcre = req.pcre,
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
        var held = try self.beginRead();
        defer held.lease.release();
        try self.guardExtras(&held, req);
        const ceil = held.ceil;
        if (req.invert) return self.queryInvert(arena, req, ceil);

        // Lower the request through the shared search core (`kernel/match/query.zig`):
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
        const verify = !self.seqlock.provenClean();

        // The trigram base candidate ids, shared by the serial and the sharded
        // base fold. A common token yields a LARGE candidate set whose serial fold
        // is the 1-core-vs-16-core loss to cold; above the shared byte floor the
        // base fold shards across cores (a contiguous id range + its own scratch
        // and accumulator per thread), else it folds serially — byte-identical.
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand = try self.candidateIds(&cq, req.filter, &cand_buf);

        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();
        var acc = Accumulator{ .mode = req.mode, .arena = arena, .io = self.io, .verify_existence = verify, .cq = &cq, .sc = &sc };
        if (!try self.foldBaseParallel(arena, req, &cq, cand, verify, &acc, ceil))
            try self.eachBase(cand, &acc, ceil);
        try self.eachOverlay(req.filter, &acc); // the (bounded) overlay always folds serially

        if (req.mode == .files) std.mem.sort([]const u8, acc.files.items, {}, lessPath);
        return .{ .mode = req.mode, .files = try ownFiles(arena, acc.files.items), .count = acc.count };
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
                sh.session.eachBase(sh.ids, &a, sh.ceil) catch |e| {
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
    fn queryInvert(self: *ResidentSession, arena: std.mem.Allocator, req: Request, ceil: Ceiling) QueryError!Result {
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
        const cand = try self.candidateIds(&cq, req.filter, &cand_buf);
        const is_cand = try self.gpa.alloc(bool, self.mir.docs.len);
        defer self.gpa.free(is_cand);
        @memset(is_cand, false);
        for (cand) |id| is_cand[id] = true; // pruned to in-scope ids by the filter

        var inv = InvertFold{ .mode = req.mode, .arena = arena, .io = self.io, .cap = req.max_count, .verify_existence = !self.seqlock.provenClean() };
        for (self.mir.paths, self.mir.docs, self.mir.nuls, self.mir.lines, 0..) |path, bytes, nul, nlines, i| {
            if (ceil.over(self.io, i)) return self.budgetAbort();
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
        return .{ .mode = req.mode, .files = try ownFiles(arena, inv.files.items), .count = inv.count };
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
        var held = try self.beginRead();
        defer held.lease.release();
        try self.guardExtras(&held, req);
        const ceil = held.ceil;

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
        const docs = try self.matchingDocs(arena, &cq, req.filter, &sc, .lines, req.invert, .{}, ceil);
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

    /// Zero-copy sibling of `queryLines`: gather the SAME path-sorted docs under
    /// the same lock+reconcile, then render through `render.renderLinesShm`, which
    /// chooses the transport by answer size — at/above `floor` the daemon hands the
    /// client a shared-memory fd (the answer never traverses the socket); below it,
    /// or on any shm failure, the SAME bytes come back to stream as `chunk` frames.
    /// The caller owns any returned buffer (must close it). Byte-identical to
    /// `queryLines` for the same corpus state; `-m0` is the empty chunk answer.
    pub fn queryLinesShm(self: *ResidentSession, arena: std.mem.Allocator, req: Request, floor: usize) QueryError!render.LinesEmit {
        if (req.matchNothing()) return .{ .chunk = .{ .bytes = "", .matched = false } };
        var held = try self.beginRead();
        defer held.lease.release();
        try self.guardExtras(&held, req);
        const ceil = held.ceil;

        var cq = try self.compileFor(req, .files);
        defer cq.deinit(self.gpa);
        var sc = cq.scratch(self.gpa) catch return QueryError.OutOfMemory;
        defer sc.deinit();

        const docs = try self.matchingDocs(arena, &cq, req.filter, &sc, .lines, req.invert, .{}, ceil);
        return render.renderLinesShm(self.gpa, arena, req, docs, floor) catch |e| switch (e) {
            error.OutOfMemory => return QueryError.OutOfMemory,
            error.Unsupported => return QueryError.Stale,
        };
    }

    /// Answer a `--rank[=N]` request over resident bytes: gist's definition-first
    /// ranked view (`ranked.zig`), the one shape rg can't express. The candidate
    /// set is the SAME trigram-pruned, scope-gated ids the line faces gather (so a
    /// caseless rank prunes soundly instead of scanning the whole tree), gathered
    /// as in-memory `LiveFile`s in ASCENDING mirror-id order — the exact id order
    /// cold's index rank path appends in, so the RRF tiebreak (`rank.zig`: fused
    /// score desc, then array position) is byte-identical on a quiescent tree.
    /// `arena` owns the returned rendered bytes; the overlay's fresher-than-index
    /// docs fold in after the base half (empty on a quiescent tree, so
    /// parity-neutral — under churn warm is simply fresher, the daemon's standing
    /// contract). A pattern outside the linear engine (declined `-F`, or a
    /// compile decline) or an OOM surfaces as `error.Stale`/`OutOfMemory` → cold.
    /// `k` is the surfaced-row cap (`0` ⇒ cold's default 20).
    pub fn queryRank(self: *ResidentSession, arena: std.mem.Allocator, req: Request, k: usize) QueryError![]const u8 {
        var held = try self.beginRead();
        defer held.lease.release();
        try self.guardExtras(&held, req);
        const ceil = held.ceil;

        // The whole-doc gate doubles as the candidate compiler; its regex body IS
        // the linear engine cold ranks with (`serial.zig`'s `re.linear`), compiled
        // from the same pattern/case/unicode — reuse it (no second compile).
        // `--rank` declines `-F` in `classify`, so the body is always a regex here.
        var cq = try self.compileFor(req, .files);
        defer cq.deinit(self.gpa);
        // `--rank` is linear-only: `classify` declines `-F` AND `-P` alongside
        // it, so the body is always the linear arm here (the AST `ranked` ranks
        // with). A PCRE2 or literal body is defensively `error.Stale` → cold.
        const rex = switch (cq.body) {
            .engine => |*m| switch (m.*) {
                .linear => |*r| r,
                .pcre => return QueryError.Stale,
            },
            .literal => return QueryError.Stale,
        };

        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        const cand = try self.candidateIds(&cq, req.filter, &cand_buf);

        // Base candidates in ascending id order (cold's index-rank append order),
        // then the bounded overlay — `renderLive`'s `fileDoc` re-verifies each and
        // drops trigram false positives, so the surviving ranked set is identical
        // to cold's, and the array position (the RRF tiebreak) matches too.
        var files: std.ArrayList(ranked.LiveFile) = .empty;
        for (cand, 0..) |id, i| {
            if (ceil.over(self.io, i)) return self.budgetAbort();
            const path = self.mir.paths[id];
            if (self.overlay.contains(path)) continue; // the overlay pass owns it
            files.append(arena, .{ .path = path, .bytes = self.mir.docs[id] }) catch return QueryError.OutOfMemory;
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| {
                if (!req.filter.admits(e.key_ptr.*)) continue;
                files.append(arena, .{ .path = e.key_ptr.*, .bytes = d.bytes }) catch return QueryError.OutOfMemory;
            },
        };

        var out: std.ArrayList(u8) = .empty;
        // `binary_detect=true` = cold's `!-a` default: `renderLive`'s `fileDoc`
        // clips a NUL-bearing walked file to its committed prefix, so warm rank
        // excludes compiled-binary symbol hits exactly as cold does (the search
        // visitors above already drop them; `-a` is an exotic flag that falls to
        // cold, so the resident rank path never needs to read a binary as text).
        _ = ranked.renderLive(arena, self.io, rex, files.items, k, &out, true) catch |err|
            return if (err == error.OutOfMemory) QueryError.OutOfMemory else QueryError.Stale;
        return out.items;
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
        var held = try self.beginRead();
        defer held.lease.release();
        try self.guardExtras(&held, req);
        const ceil = held.ceil;

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
            .verify_existence = !self.seqlock.provenClean(),
        };
        defer ex.spans.deinit(self.gpa);
        if (req.invert) try self.eachDoc(req.filter, &ex, ceil) else try self.eachCandidate(&cq, req.filter, &ex, ceil);
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
        var held = try self.beginRead();
        defer held.lease.release();
        try self.guardExtras(&held, req);
        const ceil = held.ceil;

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

        const docs = try self.matchingDocs(arena, &cq, req.filter, &sc, .json_stream, req.invert, sinkBudget(sink), ceil);

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
    /// order (see `docLess`) — so downstream output is deterministic. `budget`
    /// is the hosted record stream's cooperative halt (`cancel`/`timeout_ns`):
    /// on trip the gather stops CLEANLY with a partial doc set (no `Stale`), so
    /// a scan that emits few or no records still respects the caller's budget;
    /// it is empty for the daemon `lines` faces, whose completeness the session
    /// ceiling guards instead.
    fn matchingDocs(self: *ResidentSession, arena: std.mem.Allocator, cq: *const CompiledQuery, filter: PathFilter, sc: *Scratch, admit: Admit, invert: bool, budget: RunBudget, ceil: Ceiling) QueryError![]const DocRef {
        var g = Gather{ .arena = arena, .io = self.io, .cq = cq, .sc = sc, .admit = admit, .require_match = !invert, .check_exists = !self.seqlock.provenClean(), .cancel = budget.cancel, .deadline_ns = budget.deadline_ns };
        if (invert) try self.eachDoc(filter, &g, ceil) else try self.eachCandidate(cq, filter, &g, ceil);
        std.mem.sort(DocRef, g.docs.items, {}, docLess);
        return g.docs.items;
    }

    /// Walk every live document without trigram pruning. Invert-match needs this:
    /// a document excluded by the positive candidate set may be entirely made of
    /// selected nonmatching lines.
    fn eachDoc(self: *ResidentSession, filter: PathFilter, v: anytype, ceil: Ceiling) QueryError!void {
        for (self.mir.paths, self.mir.docs, self.mir.nuls, 0..) |path, bytes, nul, i| {
            if (ceil.over(self.io, i)) return self.budgetAbort();
            if (self.overlay.contains(path)) continue;
            if (!filter.admits(path)) continue; // out-of-scope for a scoped `-v` walk
            try v.visit(path, bytes, nul);
            if (wantsStop(v)) return;
        }
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| {
                if (!filter.admits(e.key_ptr.*)) continue;
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
    fn eachCandidate(self: *ResidentSession, cq: *const CompiledQuery, filter: PathFilter, v: anytype, ceil: Ceiling) QueryError!void {
        var cand_buf: ?[]u32 = null;
        defer if (cand_buf) |c| self.gpa.free(c);
        try self.eachBase(try self.candidateIds(cq, filter, &cand_buf), v, ceil);
        if (wantsStop(v)) return;
        try self.eachOverlay(filter, v);
    }

    /// The base half of `eachCandidate`: visit each trigram base candidate id in
    /// `cand` that is not shadowed by the overlay. Split out so the `-l`/`-c`
    /// fold can SHARD this walk across cores (a contiguous id range per thread,
    /// each with its own scratch over the immutable mirror), while the bounded
    /// overlay stays serial. `cand` is contiguous and ordered, so a sharded walk
    /// yields the same visits in the same per-shard order.
    fn eachBase(self: *ResidentSession, cand: []const u32, v: anytype, ceil: Ceiling) QueryError!void {
        for (cand, 0..) |id, i| {
            if (ceil.over(self.io, i)) return self.budgetAbort();
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
    fn eachOverlay(self: *ResidentSession, filter: PathFilter, v: anytype) QueryError!void {
        var it = self.overlay.iterator();
        while (it.next()) |e| switch (e.value_ptr.*) {
            .tombstone => {},
            .doc => |d| {
                if (!filter.admits(e.key_ptr.*)) continue; // out-of-scope overlay doc
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
    fn candidateIds(self: *ResidentSession, cq: *const CompiledQuery, filter: PathFilter, buf: *?[]u32) QueryError![]const u32 {
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
        buf.* = c; // caller frees the full allocation; the pruned view is a prefix of it
        // Scope BEFORE matching: a `PathFilter` (positional roots today) drops
        // out-of-scope candidate ids in place, so the fold/gather never reads a
        // file outside the query's subtree — the "faster than rg" prune the
        // glob module documents, and the reason warm scoped work ≤ cold scoped
        // work. An empty filter returns `c` untouched (rootless pays nothing).
        return filter.prune(self.mir.paths, c);
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

/// The optional cooperative budget a search sink carries into the doc gather.
/// The hosted collector exposes `runBudget()` (its cancel token + deadline) so a
/// scan that never reaches `emit` — a rare pattern, an invert walk, a superset
/// that mostly fails the whole-doc gate — still honors `cancel`/`timeout_ns`.
/// Every other sink (the FFI relay, the parallel-shard buffer) declares none, so
/// the gather runs unbounded and this resolves to an empty budget at comptime.
inline fn sinkBudget(sink: anytype) RunBudget {
    const S = std.meta.Child(@TypeOf(sink));
    if (comptime @hasDecl(S, "runBudget")) return sink.runBudget();
    return .{};
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
    /// Hosted cooperative budget (both null off the hosted record stream). When
    /// tripped `visit` raises `stop`, so `eachCandidate`/`eachDoc` return early
    /// cleanly with the partial doc set — the collector then bounds the emit.
    cancel: ?*const CancelToken = null,
    deadline_ns: ?i128 = null,
    i: usize = 0,
    stop: bool = false,
    docs: std.ArrayList(DocRef) = .empty,

    fn visit(self: *Gather, path: []const u8, bytes: []const u8, nul: ?usize) QueryError!void {
        if (self.budgetTripped()) {
            self.stop = true;
            return;
        }
        // Cold `--json` skips a doc its 8 KiB `isBinary` window flags; a doc whose
        // first NUL sits past the window is streamed in full. Match that exactly.
        if (self.admit == .json_stream and nul != null and corpus_mod.isBinary(bytes)) return;
        if (self.require_match and !self.cq.docMatches(bytes, self.sc)) return;
        if (self.check_exists and !fileExists(self.io, path)) return;
        try self.docs.append(self.arena, .{ .path = path, .bytes = bytes, .nul = nul });
    }

    /// A hosted `cancel` (checked every visit — an armed-only atomic load, cheap
    /// beside the whole-doc gate that follows) or a `timeout_ns` deadline
    /// (sampled once per `budget_stride` visits, so the clock read amortizes to
    /// noise). Both branches compile to a constant `false` when unarmed.
    inline fn budgetTripped(self: *Gather) bool {
        if (self.cancel) |c| if (c.requested()) return true;
        if (self.deadline_ns) |d| {
            self.i +%= 1;
            if (self.i & budget_stride == 0 and std.Io.Clock.now(.awake, self.io).nanoseconds >= d) return true;
        }
        return false;
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
/// decision itself is the shared `CompiledQuery` kernel (`kernel/match/query.zig`);
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

const readGen = persist.readPublishedGeneration;
