//! gist resident session — the warm, in-memory search engine (ADR-352 rung 2.5).
//!
//! A `ResidentSession` owns the corpus bytes + trigram index for one repository,
//! held warm across many queries so an eligible request (`request.zig`) answers
//! without re-paying the process + index-mmap + candidate-read startup the cold
//! subprocess pays every call. It lowers each request through the shared search
//! core (`kernel/match/query.zig`) — the SAME compile → trigram-prefilter → match
//! kernels the cold CLI is built on — driven directly over the warm corpus, so
//! the warm and cold answers cannot drift. Because that core **returns errors**
//! (`error.Unsupported`) instead of calling `die()`, a bad request declines with
//! `freshness_unprovable` (→ cold fallback) and can never terminate the daemon — the
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
//!     a silently gapped set would lie) declines with `freshness_unprovable`, so
//!     the client falls back to the certified cold path. (A
//!     catastrophic OOM inside the shared walk itself exits the daemon via
//!     `die()`; the client's dropped connection then falls back cold and the
//!     next query re-spawns a fresh daemon — fail-open too.)
//!
//! Concurrent reads overlap under a shared `Ward` lease
//! (`kernel/primitives/ward.zig`) while a reconcile runs alone under the
//! exclusive lease; the watcher only ever touches the shared `Seqlock`
//! (`seqlock.zig`), never the overlay, so the barrier is a lock-free seqlock
//! over a ward-guarded engine.
//!
//! ## Where the engine lives
//!
//! This file owns the session's STATE — the mirror + index it binds at `init`,
//! the overlay and freshness fields, and `beginRead`, the lease every answer
//! passes through. The behavior lives in siblings, bound back into the struct by
//! the decl table at its foot, so a caller still writes `sess.query(...)`:
//!
//!   - `answer.zig` — the answer + budget vocabulary, re-exported below.
//!   - `overlay.zig` — the mutation store: substitutions, tombstones, twins.
//!   - `reconcile.zig` — the fail-closed barrier + the `-t`/`-g` extras guard.
//!   - `gather.zig` — compile, trigram prune, and the candidate walk every face shares.
//!   - `fold.zig` — the `-l`/`-c` set/count face and its `-v` complement.
//!   - `present.zig` — the rendered faces: `lines`, its shm sibling, `--rank`.
//!   - `stream.zig` — the FFI record stream and the `-q` existence probe.

const std = @import("std");
const corpus = @import("corpus.zig");
const answer = @import("answer.zig");
const overlay_mod = @import("overlay.zig");
const reconcile = @import("reconcile.zig");
const fold = @import("fold.zig");
const present = @import("present.zig");
const stream = @import("stream.zig");
const Ward = @import("../../../kernel/primitives/ward.zig").Ward;
// The resident file set is the certified rg-default walk the cold path uses, NOT
// `haystack`'s coarse superset — this is what makes `resident == --no-index ==
// rg` true for hidden files, `.gitignore` precedence, and root scope. `session`
// depending on `surface/exec/cold` is a one-way edge (serial.zig never imports
// session), so no import cycle.
const run = @import("../cold/engine/serial.zig");
const dirtylog = @import("dirty.zig");
const annalslog = @import("annals.zig");
const Seqlock = @import("seqlock.zig").Seqlock;
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const Index = @import("../../../corpus/index/trigrams/trigram.zig").Index;
// Path-scope predicate (`underRoot`/`normalizeRoot`) — the served-scope subset
// check reuses the exact primitive the request `PathFilter` prunes with.
const scope = @import("../../../corpus/scope/glob.zig");
const request = @import("request.zig");

pub const Mode = request.Mode;
pub const Request = request.Request;
/// The resolved path-scope a request confines its answer to (roots today) — the
/// candidate walk prunes/gates with it; empty is the rootless whole-corpus search.
pub const PathFilter = request.PathFilter;

// The answer + budget vocabulary lives in `answer.zig`; re-exported here so the
// engine and its contract are one import for every caller (`resident.MatchRecord`
// and `answer.MatchRecord` are the same type).
pub const QueryError = answer.QueryError;
pub const Answer = answer.Answer;
pub const CancelToken = answer.CancelToken;
pub const RunBudget = answer.RunBudget;
pub const Ceiling = answer.Ceiling;
pub const Result = answer.Result;
pub const Lines = answer.Lines;
pub const MatchKind = answer.MatchKind;
pub const MatchRecord = answer.MatchRecord;

/// A base doc's live substitute: a replacement document (gpa-owned bytes +
/// first-NUL offset), or a tombstone (deleted / left the walk set / read empty).
pub const Overlay = union(enum) { doc: corpus.OwnedDoc, tombstone };

pub const readGen = persist.readPublishedGeneration;

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

    /// Reader/writer discipline (ADR-352 rung 2.5): `reconcile.barrier` (overlay
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
    /// overlay chokepoint (`overlay.put`) and rebuilt on reload; unused (empty)
    /// on every other target, where the fs is byte-exact.
    nonascii_keys: std.StringHashMapUnmanaged(void) = .empty,

    /// The reachable file-level un-hide/un-ignore candidates the certified
    /// default walk SKIPPED (`serial.zig::Extra`): hidden dotfiles and directly
    /// gitignored leaves whose parent directory the walk still descended. These
    /// are EXACTLY the files a `-t`/`-g` query surfaces (rg / cold) but the
    /// mirror — built from the same hidden/ignore-excluding walk — cannot supply.
    /// `reconcile.guardExtras` consults this list to fail a filtered warm query
    /// over to the certified cold path, restoring `resident == --no-index == rg`
    /// for `-t`/`-g`. Owned by `extras_arena` (rebuilt whole on refresh → arena reset).
    extras: []const run.Extra = &.{},
    extras_arena: std.heap.ArenaAllocator,
    /// A scoped reconcile (O(changed)) does NOT recompute `extras`, so a filtered
    /// query afterward cannot trust the list — `guardExtras` forces one full
    /// extras walk (`refreshExtras`) before deciding; a full reconcile clears
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
            const sel = try run.defaultFileSetExtras(sel_arena.allocator(), io, owned_roots, &sel_extras);
            owned_extras = try reconcile.dupeExtras(extras_arena.allocator(), sel_extras);
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
        var nonascii = try overlay_mod.buildNonAscii(gpa, mir.paths);
        errdefer overlay_mod.freeNonAscii(&nonascii, gpa);

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
        overlay_mod.clear(self);
        self.overlay.deinit();
        overlay_mod.freeNonAscii(&self.nonascii_keys, self.gpa);
        self.gpa.free(self.index_gen);
        self.by_path.deinit();
        self.idx.deinit();
        self.mir.deinit();
        self.extras_arena.deinit();
        self.roots_arena.deinit();
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

    // ── the read lease + its wall-clock ceiling ──

    /// Build this query's wall-clock ceiling from the configured budget — a
    /// disabled ceiling when unbudgeted (the embedder/FFI/test default), which
    /// skips every clock read. Called under the session lock at the top of each
    /// query and threaded into the reconcile + the fold/gather walks, so one
    /// value spans the whole query without any shared session field the
    /// concurrent readers would race.
    fn ceiling(self: *const ResidentSession, tripped: *std.atomic.Value(bool)) Ceiling {
        return .{ .deadline_ns = if (self.query_budget_ns != 0)
            std.Io.Clock.now(.awake, self.io).nanoseconds + self.query_budget_ns
        else
            0, .tripped = tripped };
    }

    /// Record a budget decline — the client answers on
    /// the certified cold path exactly as for a lost freshness anchor. Atomic
    /// because a parallel fold/stream shard may be the one that trips the ceiling.
    pub fn noteBudgetAbort(self: *ResidentSession) void {
        _ = self.budget_aborts.fetchAdd(1, .monotonic);
    }

    /// A held read lease over the fresh session plus this query's wall-clock
    /// ceiling — what `beginRead` hands each answer face, which holds it for the
    /// answer and `held.lease.release()`s on the way out.
    pub const Held = struct { lease: Ward.Read, ceil: Ceiling };

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
    pub fn beginRead(self: *ResidentSession, tripped: *std.atomic.Value(bool)) QueryError!Answer(Held) {
        const ceil = self.ceiling(tripped);
        var declined = false;
        const Ctx = struct { s: *ResidentSession, c: Ceiling, declined: *bool };
        const lease = try self.ward.readReconciled(
            self.io,
            Ctx{ .s = self, .c = ceil, .declined = &declined },
            struct {
                fn fresh(x: Ctx) bool {
                    return x.s.seqlock.skip(); // watcher-clean witness
                }
            }.fresh,
            struct {
                fn refresh(x: Ctx) QueryError!void {
                    if (!try reconcile.barrier(x.s, x.c)) x.declined.* = true;
                }
            }.refresh,
        );
        if (declined or ceil.declined()) {
            lease.release();
            return .{ .declined = .freshness_unprovable };
        }
        return .{ .got = .{ .lease = lease, .ceil = ceil } };
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

    // ── the answer faces ──
    //
    // Each body lives in the sibling that owns its shape; a decl alias binds it
    // back as a real method, so every call site stays `sess.query(arena, req)`.
    // Private helpers need no alias — siblings call them directly.

    /// The `-l`/`-c` set/count fold (`fold.zig`), `-v` included.
    pub const query = fold.query;
    /// The default `path:text` line presentation (`present.zig`).
    pub const queryLines = present.queryLines;
    /// `queryLines` with a shared-memory transport above the caller's floor.
    pub const queryLinesShm = present.queryLinesShm;
    /// The gist-native definition-first ranked view (`--rank`).
    pub const queryRank = present.queryRank;
    /// The early-halting `-q` existence probe (`stream.zig`).
    pub const queryExists = stream.queryExists;
    /// The in-process FFI's per-line record stream (`stream.zig`).
    pub const search = stream.search;
};
