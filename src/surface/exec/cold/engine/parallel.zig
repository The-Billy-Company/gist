// MONOLITHIC: one fused work-stealing pipeline — queue, walk, ignore chain, elision, per-file search, and the streaming sink share per-worker state; splitting breaks the single-pass flow
//! gist `rg` — the parallel fused walk+read+match+emit engine (the fast path).
//!
//! `run.zig`'s serial engine walks the tree single-threaded, reads candidates
//! in a second phase, then matches+emits in a third — three passes, one core
//! doing the walk and the emit. ripgrep fuses all three into one work-stealing
//! parallel walk (`ignore::WalkParallel`), which is exactly what this module
//! is: a queue of DIRECTORY tasks; each worker pops a directory, lists it in
//! ONE `getattrlistbulk` syscall batch (name+type+mtime+ctime per sibling — the
//! timestamps power inline index elision with no separate freshness stat-walk),
//! applies the ignore verdict, pushes child directories back on the queue, and
//! searches child FILES on the spot (read → BOM decode → literal gate →
//! binary sniff → line match → render), writing each hit to stdout the
//! instant it's rendered via the shared `Sink` (`Sink.emit`, lock-guarded so
//! concurrent workers' output never interleaves) — never globally reordered
//! after the fact. The one exception is the pure path-list modes (`-l`/
//! `--files`), whose records a worker coalesces into ~64 KiB chunks
//! (`bufferPath`/`Sink.emitFilesChunk`) so a high-hit scan pays one lock+write
//! per chunk, not per file — still contiguous, still order-free by contract.
//! This is also what lets gist cancel early: a
//! downstream reader hanging up (`| head`, a closed FD, an interrupted pager)
//! surfaces as a failed write, which flips `Queue.aborted` and unwinds every
//! worker within microseconds instead of finishing the whole tree — the same
//! EPIPE-triggered cooperative-cancellation ripgrep's own printer uses. The
//! cost: output arrives in worker-discovery order, not global path-sort order
//! (gist's own rgsuite harness already treats an order-only diff as a soft
//! pass, since a parallel walker's file order was never a byte-parity promise
//! to begin with — see `bench/rgsuite/run.py`'s `ORDER` bucket).
//!
//! Thread-safety is by construction, not locks: the base `Ignore` (CWD/
//! ancestor tier) is FROZEN before fan-out and read via `decideAt` (root depth
//! passed per call, never a mutable field); each directory's own ignore rules
//! live in an immutable `IgNode` chained to its parent's, built once by the
//! worker that entered the directory and only read thereafter. Workers touch
//! only their own arena; the one shared structure is the task queue (the
//! classic mutex + condvar work-stealing queue idiom).
//!
//! Dispatch policy (`eligible`): the recursive-walk cases every agent session
//! actually hits — default search, `-l`, `-c`, `-o`, `-n`, context, `-w`/`-i`/
//! `-F`/`-x`, `-t`/`-g` scoping, `--files`, `--files-without-match`, `--stats`
//! — run here. The long tail that carries cross-file or stateful semantics
//! (`-L` symlink cycles, `--json` with transforms, `-q`, `-r` captures,
//! `--max-filesize`, explicit FILE args, stdin) stays on the proven serial
//! engine. `--files-without-match` is the invert of `-l` (emit on a miss;
//! index elision IS a miss → emit without reading). `--stats` streams the
//! match body like any content mode and sums a per-worker `grepfile.Stats`
//! into one trailing block (same shape as the `--json` summary fold).

const std = @import("std");
const builtin = @import("builtin");
const corpus_mod = @import("../../../../corpus/tree/corpus.zig");
const args = @import("../argv/args.zig");
const output = @import("../emit/output.zig");
const json = @import("../emit/json.zig");
const ignore = @import("../../../../corpus/tree/ignore.zig");
const grepfile = @import("../read/grepfile.zig");
const ingest = @import("../read/ingest.zig");
const simd = @import("../../../../kernel/match/scan/simd.zig");
const verify = @import("../../../../kernel/match/scan/verify.zig");
const persist = @import("../../../../corpus/index/trigrams/persist.zig");
const fresh = @import("../../../../corpus/index/trigrams/fresh.zig");
const crest = @import("../../../../kernel/primitives/crest.zig");
const bulkstat = @import("../../../../corpus/tree/bulkstat.zig");
const treemap = @import("../../../../corpus/index/phantom/treemap.zig");
const shard_mod = @import("../../../../corpus/index/content/shard.zig");
const paths_mod = @import("../../../../corpus/scope/paths.zig");
const stripDot = paths_mod.stripDot;
const replaceSep = paths_mod.replaceSep;
const joinPath = paths_mod.join;
const rootDepth = paths_mod.rootDepth;
const Opts = args.Opts;
const Emitter = output.Emitter;
const die = args.die;
const oom = args.oom;
const Regex = @import("../../../../kernel/match/regex/linear/core.zig").Regex;
const Matcher = @import("../../../../kernel/match/regex/linear/matcher.zig").Matcher;
const serial = @import("serial.zig");
const hints = @import("../emit/hints.zig");
const Dir = std.Io.Dir;

/// Can this invocation run on the parallel engine byte-identically? Everything
/// here must ALSO hold in `run.zig`'s dispatch (it calls this) — the serial
/// engine remains the semantic reference for whatever this declines.
///
/// `GIST_NO_PARALLEL` (internal, undocumented — the `GIST_WORKERS` idiom)
/// forces every eligible query onto the serial engine anyway. It exists SOLELY
/// so the parity gates (`bench/gates/line_parity.sh`, `bench/rgsuite/run.py`)
/// can run their whole case list against BOTH engines and catch exactly the
/// class of bug this function's own history proves possible: the parallel
/// engine landed a day after a serial-engine-only ignore-parity fix and
/// silently missed it (see `ignore.zig`'s `skipFromVerdict` — it now takes the
/// same whitelist-override pair `shouldSkip` does). No production caller sets
/// this; it is never exposed as a CLI flag.
pub fn eligible(io: std.Io, parsed: args.Parsed, o: Opts) bool {
    if (args.envSpan("GIST_NO_PARALLEL") != null) return false;
    // `-U`/--multiline rides the pipeline: each worker's per-file render goes
    // through the same `Emitter.buffer` whole-buffer model the serial engine
    // uses (multiline.zig owns the span/line semantics), so the walk + literal
    // gate + index elision that carry every linear win apply to `-U` too.
    // `--stats` and `--files-without-match` ride the fused walk (per-worker
    // tallies / inverted `-l` emit); `-q` still needs the serial short-circuit
    // (first hit wins, cancel the walk), and `-r`/`--max-filesize`/`-L` keep
    // their serial collect semantics.
    if (o.follow or o.quiet or o.replace != null or o.max_filesize != 0) return false;
    // `--json` RIDES the walk (the streaming win every other mode gets): each
    // worker emits ripgrep's per-file `begin`/`match`/`end` records via the shared
    // `json.emitOne` and tallies a per-worker `json.Stats`; `run` sums them into
    // the single trailing `summary`. It declines only when it would need
    // per-thread capture scratch (`-r`, gated above) or a content transform
    // (`-z`/`-E`) whose decoded bytes the walk's JSON path doesn't rewrite — those
    // keep the serial collect-then-shard path (`serial.run`'s `o.json` block).
    if (o.json and (o.search_zip or o.encoding != .auto)) return false;
    // `--include-zero` must emit a `path:0` line for EVERY searched file, so it
    // needs the serial engine's whole-file loop with the literal gate + index
    // elision disabled — the streaming sink here culls non-matching files.
    if (o.include_zero) return false;
    // A device-bounded walk (`--one-file-system`) needs cross-file device state
    // the streaming walk can't carry, so it stays serial.
    if (o.one_file_system) return false;
    // `--sort`/`--sortr` rides the fused parallel walk for the PATH key: each
    // worker holds its rendered per-file output (already in its arena) keyed by
    // path instead of racing it to stdout, and `run` orders the whole result
    // once after the walk — a parallel walk+read+match feeding a single sort,
    // which beats ripgrep's single-threaded sorted traversal (`emitSorted`).
    // The exclusions keep byte-parity with the serial sort oracle: time keys
    // (modified/accessed/created) need a per-file stat the fused walk skips;
    // `--files` (no pattern) already wins on the serial stat-only listing; a
    // machine-consumed `--json` stream keeps its serial collect path; and rg
    // orders ASCENDING multi-root path per-argv-root (`lessAscPathWalk`), which
    // the rootless streaming walk doesn't track — descending is global, so it
    // rides regardless of root count.
    switch (o.sort_key) {
        .none => {},
        .path => if (o.json or o.files_list or (parsed.roots.len > 1 and !o.sort_reverse)) return false,
        .modified, .accessed, .created => return false,
    }
    // `-z`/`-E` ride the parallel engine; `--pre`/`--binary` do not (see
    // `transformsRidePipeline`). Kept as a pure, unit-tested seam so a future
    // edit can't silently drop `-z` back to the serial engine unnoticed.
    if (!transformsRidePipeline(o)) return false;
    // `-P`/`--pcre2` rides the parallel engine like the linear default: its
    // per-worker PCRE2 scratch is thread-confined, and the match-limit latch
    // (the exit-2-on-catastrophic-backtracking rg parity) is a process-global
    // atomic every worker stores into, folded into the exit code below.
    // Every positional root must be a directory — an explicit FILE arg carries
    // rg's "never ignore-filtered, error-if-unopenable" semantics (serial).
    for (parsed.roots) |r| {
        var d = Dir.cwd().openDir(io, r, .{}) catch return false;
        d.close(io);
    }
    return true;
}

/// The content-transform half of the pipeline-eligibility contract, factored out
/// pure so the routing decision is unit-testable without a filesystem walk.
///
/// `-z`/`--search-zip` (decompress) and `-E`/`--encoding` (transcode) RIDE the
/// parallel engine: each worker rewrites its own file on a private arena — native
/// `std.compress` in-process, or a thread-safe `std.process.run` for the
/// external-codec tail — then matches+emits it, fusing the decode with the match
/// that rg pays serially per file. `--pre` DECLINES (it must keep rg's
/// "preprocessor receives the file PATH as argv[1]" contract with a single-writer
/// stderr + exit-2 latch on the serial engine); `--binary`/`-uuu` DECLINES (the
/// whole-file NUL-bearing binary search path is serial). `-z` and `-E` are always
/// safe here because their rewrite is a pure per-file byte function. See
/// `ingest.zig` + `searchFile`'s transform branch.
pub fn transformsRidePipeline(o: Opts) bool {
    return o.pre == null and !o.binary;
}

test "transform routing: -z/-E ride the pipeline; --pre/--binary decline" {
    const t = std.testing;
    // plain + the two transforms that ride the parallel engine
    try t.expect(transformsRidePipeline(.{}));
    try t.expect(transformsRidePipeline(.{ .search_zip = true }));
    try t.expect(transformsRidePipeline(.{ .encoding = .utf16le }));
    try t.expect(transformsRidePipeline(.{ .search_zip = true, .encoding = .windows_1252 }));
    // the two that must stay serial
    try t.expect(!transformsRidePipeline(.{ .pre = "decompress.sh" }));
    try t.expect(!transformsRidePipeline(.{ .binary = true }));
    // a transform paired with a serial-only flag still declines (serial wins)
    try t.expect(!transformsRidePipeline(.{ .search_zip = true, .binary = true }));
    try t.expect(!transformsRidePipeline(.{ .search_zip = true, .pre = "p.sh" }));
}

// ─────────────────────────── ignore chain ───────────────────────────

// The per-directory ignore CHAIN (immutable, worker-arena-lived) and its
// build/fold helpers live in `ignore.zig` — one rule core so the serial walker,
// this search engine, and the fused corpus loader (`corpus/tree/loadpar.zig`)
// cannot drift. Aliased here so every existing call site reads unchanged.
const IgNode = ignore.IgNode;
const applyChain = ignore.applyChain;
const readIgnoreFile = ignore.readIgnoreFile;
const appendRules = ignore.appendRules;
const IgPresent = ignore.IgPresent;
const loadNode = ignore.loadNode;
const noteIgnoreFile = ignore.noteIgnoreFile;

/// The full skip decision for one walked entry: frozen-base verdict —
/// `Compiled.matchRank` (hash-probing fast tier) when available, else
/// `decideAt` — overridden by the per-directory chain, then the shared
/// `.git`/hidden folding (`skipFromVerdict`). Threads the same ripgrep
/// whitelist-override pair (`Filter.whitelists`/`whitelistsHidden`) the serial
/// engine's `walkDirLinked` computes per entry — see `Ignore.shouldSkip`'s doc
/// comment for the asymmetry (`-g`/`--iglob` bypasses `.git`+ignore, a `-t`
/// type match only un-hides) this engine must reproduce byte-for-byte.
fn shouldSkip(cfg: *const Cfg, chain: ?*const IgNode, a: std.mem.Allocator, task: DirTask, rel: []const u8, scope_rel: []const u8, is_dir: bool, basename: []const u8) bool {
    const ig = cfg.ig;
    var v: ?bool = null;
    if (cfg.compiled) |c| {
        if (c.matchRank(stripDot(rel), is_dir)) |r| v = !c.rules[r].negated;
    } else v = ig.decideAt(rel, is_dir, task.root_depth);
    applyChain(chain, a, ig.o.ignore_case_insensitive, task.root_depth, rel, is_dir, &v);
    const wl_ig = cfg.o.filter.whitelists(a, scope_rel);
    const wl_hid = cfg.o.filter.whitelistsHidden(a, scope_rel);
    return ig.skipFromVerdict(v, is_dir, basename, wl_ig, wl_hid);
}

// ─────────────────────────── index elision ───────────────────────────

/// Compact exact path→doc lookup for a persisted path table. Slots hold only a
/// u32 doc id; collisions probe onward and always compare the full path before
/// returning, so an unknown/new path can never become an indexed false positive.
/// At ≤50% load this is ~128 KiB for today's 16k-file corpus, versus a
/// StringHashMap node for every non-candidate path.
pub const IndexedPaths = struct {
    const empty = std.math.maxInt(u32);

    slots: []u32,
    mask: usize,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, paths: []const []const u8) std.mem.Allocator.Error!IndexedPaths {
        if (paths.len > std.math.maxInt(usize) / 2) return error.OutOfMemory;
        const capacity = std.math.ceilPowerOfTwo(usize, @max(8, paths.len * 2)) catch return error.OutOfMemory;
        const slots = try gpa.alloc(u32, capacity);
        @memset(slots, empty);
        const table: IndexedPaths = .{ .slots = slots, .mask = capacity - 1, .gpa = gpa };
        for (paths, 0..) |path, doc| {
            var pos = table.slot(path);
            while (slots[pos] != empty) pos = (pos + 1) & table.mask;
            slots[pos] = @intCast(doc);
        }
        return table;
    }

    pub fn get(self: *const IndexedPaths, paths: []const []const u8, path: []const u8) ?u32 {
        var pos = self.slot(path);
        while (true) {
            const doc = self.slots[pos];
            if (doc == empty) return null;
            if (std.mem.eql(u8, paths[doc], path)) return doc;
            pos = (pos + 1) & self.mask;
        }
    }

    pub fn deinit(self: *IndexedPaths) void {
        self.gpa.free(self.slots);
    }

    fn slot(self: *const IndexedPaths, path: []const u8) usize {
        return @as(usize, @truncate(std.hash.Wyhash.hash(0, path))) & self.mask;
    }
};

/// Inline read-elision oracle — `run.zig`'s `IndexSkip` minus the corpus-wide
/// freshness stat-walk: the walk itself already learns every file's mtime and
/// ctime for free (`getattrlistbulk` returns them with the name), so
/// staleness is decided per file against the persisted build anchor instead of
/// via a second full tree traversal. Elide reading P iff P is indexed, NOT a
/// candidate, AND both timestamps prove it predates the anchor.
/// Equality or unavailable metadata forces a live read.
///
/// "Candidate" folds BOTH necessary conditions at assembly time: the trigram
/// prefilter hits AND the crest sieve's survivors (`assembleElide` clears the
/// bit for a doc whose persisted crest vector falls short of ĝ — sound here
/// precisely because `skip` already refuses any file the timestamps can't
/// prove unchanged, which is the exact validity condition of the persisted
/// vector). The sieve is what elides for literal-free class patterns
/// (`[0-9a-f]{8}`) where the trigram filter concedes (research/crest/).
const Elide = struct {
    p: persist.Persisted,
    indexed: IndexedPaths,
    candidates: std.DynamicBitSet,
    anchor: i128,

    fn skip(self: *const Elide, rel: []const u8, mtime_ns: ?i128, ctime_ns: ?i128) bool {
        if (bulkstat.needsLiveRead(self.anchor, mtime_ns, ctime_ns)) return false;
        const doc = self.indexed.get(self.p.paths.items, rel) orelse return false;
        return !self.candidates.isSet(doc);
    }
    fn deinit(self: *Elide) void {
        self.candidates.deinit();
        self.indexed.deinit();
        self.p.deinit();
    }
};

/// The elide oracle is built CONCURRENTLY with the walk. Trusted local blobs now
/// map and structurally validate in sub-millisecond time, but sparse posting
/// decode + path-table construction can still lose to a narrow scoped walk.
/// The loader flips `ready`; files walked before that are deferred per-worker
/// (`Worker.pending`) and elided/searched at the end.
/// Under the local-filesystem model in `corpus/README.md`, elision stays sound
/// either way: a deferred file still requires both timestamps to predate the
/// anchor before it can be skipped.
const LazyElide = struct {
    val: ?Elide = null,
    ready: std.atomic.Value(bool) = .init(false),

    fn loaderMain(le: *LazyElide, gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8, sieve: crest.Vector) void {
        le.val = buildElide(gpa, io, o, filters, sieve);
        le.ready.store(true, .release);
    }
};

/// Explicit nested roots usually finish their scoped walk before a fresh index
/// process can load. Rootless searches, `.`, and whole top-level subtrees are
/// broad enough to plausibly amortize it; narrower scopes stay on the live path.
/// This is a pre-load COST heuristic only (the index's real roots are persisted
/// beside it and load with it): a scoped query that declines here just walks
/// live — same answer, no index load.
fn broadIndexedRoots(roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    for (roots) |raw| {
        var root = raw;
        while (std.mem.startsWith(u8, root, "./")) root = root[2..];
        root = std.mem.trimEnd(u8, root, "/");
        // Empty / `.` = the whole tree; a single path segment = a top-level
        // subtree of the corpus — both plausibly amortize the index load.
        if (root.len == 0 or std.mem.eql(u8, root, ".")) return true;
        if (std.mem.indexOfScalar(u8, root, '/') == null) return true;
    }
    return false;
}

/// Cheap pre-checks before spawning the loader. Short literals cannot query the
/// trigram index; an active crest sieve admits elision even with NO usable
/// trigram filter — the literal-free class-repetition queries are exactly the
/// sieve's raison d'être. Narrow nested roots qualify too: the loader runs
/// CONCURRENTLY with the walk and the end-of-walk flush never blocks on it
/// (`flushPending` `final=true`), so a scoped walk that outruns the load pays
/// only the per-worker deferral append — while a read-heavy subtree the loader
/// DOES beat gets its candidate reads elided like any broad scan.
pub fn indexElisionWanted(io: std.Io, parsed: args.Parsed, filters: []const []const u8, sieve: crest.Vector) bool {
    const o = parsed.opts;
    if (o.files_list or o.no_index) return false;
    // Explicit-file roots elide NOTHING: the index answers "which of the walked
    // files can't match" — but a named file is read no matter what the trigrams
    // say, so loading + decompressing the persisted index and reading the
    // freshness anchor is pure launch-time tax (measured ~1.5 ms on a warm
    // corpus) that only the tree walk ever amortizes. Skip it when every root is
    // a regular file; the mixed / directory / implicit-CWD cases keep it.
    if (rootsAllRegularFiles(io, parsed)) return false;
    return usableFilters(filters) or crest.active(sieve);
}

/// True iff ≥1 root was given and every one stats as a regular file (a lone
/// `gist PAT file.txt`, or several explicit files) — the case where index
/// elision is provably useless. Empty roots (implicit CWD walk) or any
/// directory / symlink-to-dir / unstattable root returns false, so a broad or
/// mixed scan still gets the oracle. The stat is one syscall per root, dwarfed
/// by the index load it avoids.
fn rootsAllRegularFiles(io: std.Io, parsed: args.Parsed) bool {
    if (parsed.roots.len == 0) return false;
    for (parsed.roots) |r| {
        const st = Dir.cwd().statFile(io, r, .{}) catch return false;
        if (st.kind != .file) return false;
    }
    return true;
}

/// Every filter can actually query the trigram index (non-empty, all ≥3 B).
fn usableFilters(filters: []const []const u8) bool {
    if (filters.len == 0) return false;
    for (filters) |f| if (f.len < 3) return false;
    return true;
}

/// Once the index has answered, only build the path table when the corpus and
/// provable savings can amortize it. The loader still degrades to a full live
/// read, so declining here changes cost only.
pub fn indexSavingsWorthTable(total: usize, candidates: usize) bool {
    if (total < 1024 or candidates >= total) return false;
    const elidable = total - candidates;
    const quarter = total / 4 + @intFromBool(total % 4 != 0);
    return elidable >= 512 and elidable >= quarter;
}

fn buildElide(gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8, sieve: crest.Vector) ?Elide {
    if (o.no_index) return null;
    if (!usableFilters(filters) and !crest.active(sieve)) return null;
    return assembleElide(gpa, io, filters, sieve) catch null;
}

/// Fallible half of `buildElide`: every early exit (a missing anchor, an
/// unloadable/unworthwhile index, an OOM) is an error, so `errdefer` sheds the
/// half-built state instead of hand-threading `deinit` down each return path.
fn assembleElide(gpa: std.mem.Allocator, io: std.Io, filters: []const []const u8, sieve: crest.Vector) !Elide {
    const anchor = fresh.readAnchor(gpa, io) orelse return error.NoAnchor;
    var p = (persist.loadQuiet(gpa, io) catch return error.NoIndex) orelse return error.NoIndex;
    errdefer p.deinit();
    var candidates = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer candidates.deinit();
    if (usableFilters(filters)) {
        const cand = try p.queryAny(gpa, filters);
        defer gpa.free(cand);
        for (cand) |d| candidates.set(d);
    } else {
        // Sieve-only elision: every doc starts as a candidate; the crest
        // subtraction below is the sole pruning criterion.
        candidates.setRangeValue(.{ .start = 0, .end = p.paths.items.len }, true);
    }
    // Crest sieve: clear docs whose persisted crest vector provably falls short
    // of ĝ. Valid because `Elide.skip` refuses any file whose timestamps can't
    // prove it predates the anchor — exactly when the vector describes live bytes.
    if (crest.active(sieve)) {
        if (p.crest) |table| {
            for (table, 0..) |v, d| {
                if (crest.pruned(v, sieve)) candidates.unset(d);
            }
        } else if (!usableFilters(filters)) {
            // No table to sieve with and no trigram filter either — nothing
            // can be elided; decline rather than build a can't-prune oracle.
            return error.NotWorthwhile;
        }
    }
    if (!indexSavingsWorthTable(p.paths.items.len, candidates.count())) return error.NotWorthwhile;
    const indexed = try IndexedPaths.init(gpa, p.paths.items);
    return .{ .p = p, .indexed = indexed, .candidates = candidates, .anchor = anchor };
}

/// Gate-only proof that the admitted oracle can actually elide a real indexed
/// file with live metadata. This runs only under `GIST_TEST_REQUIRE_ELISION`;
/// production queries pay no probe or counter overhead.
fn testHasElidableFile(io: std.Io, el: *const Elide) bool {
    for (el.p.paths.items, 0..) |path, doc| {
        if (el.candidates.isSet(doc)) continue;
        const st = Dir.cwd().statFile(io, path, .{}) catch continue;
        if (el.skip(path, st.mtime.nanoseconds, st.ctime.nanoseconds)) return true;
    }
    return false;
}

// ─────────────────────────── task queue ───────────────────────────

/// One directory awaiting a worker. `rel` is the display/ignore path (prefix-
/// joined, may be absolute); `scope` is its CWD-relative glob/index spelling;
/// `disk` is CWD-openable; `depth` counts components under the walk root
/// (root = 0); `root_depth` is the explicit positional root's own component
/// depth (see `Ignore.scopeToRoot`).
const DirTask = struct {
    disk: []const u8,
    rel: []const u8,
    scope: []const u8,
    depth: usize,
    root_depth: usize,
    chain: ?*const IgNode,
    /// This directory's record in the phantom `tree.map` snapshot
    /// (`treemap.not_walked` when it has none — new dir, never-descended dir,
    /// or no snapshot loaded). A recorded dir whose lstat proves it predates
    /// the snapshot anchor serves its listing from the mapping with ONE
    /// syscall instead of openat+getattrlistbulk+close.
    snap_ix: u32 = treemap.not_walked,
};

/// The shared side of the work-stealing walk. Workers keep discovered
/// directories on a private LIFO stack (depth-first — parent listing still
/// cache-warm, zero synchronization) and touch this queue only to account
/// (`noteDiscovered`/`done` — bare atomics), to DONATE surplus when
/// `starving` says a peer is hunting, and to `pop` when their own stack runs
/// dry. A dry worker spins briefly (donations arrive within microseconds
/// mid-walk), then PARKS on the condvar; donors wake exactly as many parked
/// peers as they have tasks, so there is no per-push thundering herd and no
/// yield-storm at the walk's tail. `live == 0` ⇔ walk complete; `aborted` is
/// the other way a walk ends — a downstream reader hanging up (`| head`)
/// mid-stream, detected as a failed write in `Sink.emit` — and is checked
/// everywhere `live == 0` is, so every worker (spinning, parked, or mid local
/// backlog) unwinds within microseconds instead of finishing the whole tree.
const Queue = struct {
    mu: std.Io.Mutex = .init,
    cv: std.Io.Condition = .init,
    items: std.ArrayList(DirTask) = .empty,
    head: usize = 0,
    waiting: usize = 0, // workers parked on `cv` (guarded by `mu`)
    live: std.atomic.Value(usize) = .init(0), // undone tasks anywhere (local stacks included)
    avail: std.atomic.Value(usize) = .init(0), // tasks sitting in `items` (maintained under `mu`)
    starving: std.atomic.Value(u32) = .init(0), // workers inside `pop` (spinning or parked)
    aborted: std.atomic.Value(bool) = .init(false), // set once; a broken output pipe cancels the walk
    // A directory the walk discovered but could not open/descend (unreadable /
    // EACCES) — set from any worker thread; `run` folds it into the exit code
    // (rg parity: an unsignaled walk gap must never present as a silent
    // "no match", see `reportWalkError`/`run.zig`'s identical `walk_error`).
    walk_error: std.atomic.Value(bool) = .init(false),
    // Any file the walk ADMITTED past the ignore/type/glob/hidden filters
    // (pre index-elision — rg would still have opened it). Stays false ⇒ the
    // filters excluded everything, which on an implicit-path run triggers
    // rg's "No files were searched" stderr note + exit 2 (`run`, rg parity).
    files_seen: std.atomic.Value(bool) = .init(false),
    gpa: std.mem.Allocator,
    io: std.Io,

    /// Wake every parked worker. The predicate is read under `mu` (where the
    /// pop loop parks), so the no-missed-wakeup shape holds; both terminal
    /// transitions — broken pipe (`abort`) and last task done (`done`) — funnel
    /// through here.
    fn wakeParked(q: *Queue) void {
        q.mu.lockUncancelable(q.io);
        const any = q.waiting > 0;
        q.mu.unlock(q.io);
        if (any) q.cv.broadcast(q.io);
    }

    /// Cancel the walk: a `Sink.emit` write came back closed-pipe. Idempotent
    /// (the CAS-style swap only wakes parked peers on the transition), so
    /// concurrent workers hitting EPIPE at once never double-broadcast.
    fn abort(q: *Queue) void {
        if (!q.aborted.swap(true, .acq_rel)) q.wakeParked();
    }

    /// Account for `n` newly discovered tasks (wherever they live). Must
    /// precede the discovering task's own `done`, else `live` could graze 0
    /// mid-walk and every popper would quit early.
    fn noteDiscovered(q: *Queue, n: usize) void {
        if (n != 0) _ = q.live.fetchAdd(n, .acq_rel);
    }

    /// Move already-accounted tasks into the shared queue; spinners observe
    /// `avail` lock-free, parked peers get exactly-enough wakeups.
    fn donate(q: *Queue, tasks: []const DirTask) void {
        if (tasks.len == 0) return;
        q.mu.lockUncancelable(q.io);
        q.items.appendSlice(q.gpa, tasks) catch oom();
        q.avail.store(q.items.items.len - q.head, .release);
        const wake = @min(tasks.len, q.waiting);
        q.mu.unlock(q.io);
        if (wake == 1) q.cv.signal(q.io) else if (wake > 1) q.cv.broadcast(q.io);
    }

    /// Seed the queue with the root tasks (accounts + enqueues + wakes).
    fn push(q: *Queue, tasks: []const DirTask) void {
        q.noteDiscovered(tasks.len);
        q.donate(tasks);
    }

    fn pop(q: *Queue) ?DirTask {
        _ = q.starving.fetchAdd(1, .acq_rel);
        defer _ = q.starving.fetchSub(1, .acq_rel);
        var spins: u32 = 0;
        while (true) {
            if (q.aborted.load(.acquire)) return null;
            if (q.avail.load(.acquire) != 0) {
                q.mu.lockUncancelable(q.io);
                if (q.head < q.items.items.len) {
                    const t = q.items.items[q.head];
                    q.head += 1;
                    q.avail.store(q.items.items.len - q.head, .release);
                    q.mu.unlock(q.io);
                    return t;
                }
                q.mu.unlock(q.io);
            }
            if (q.live.load(.acquire) == 0) return null;
            spins += 1;
            // A generous budget (~1ms of pause loops): mid-walk droughts last
            // microseconds, and every premature park costs two context
            // switches — measured at ~2.2k voluntary switches per run with a
            // 2k budget (ripgrep's spin-stealing workers log ~7).
            if (spins < 1 << 18) {
                std.atomic.spinLoopHint();
                continue;
            }
            // Park. The predicate is re-checked under `mu`, and both wakers
            // (`donate`, `done`, `abort`) publish under/after the same lock —
            // the classic no-missed-wakeup shape.
            q.mu.lockUncancelable(q.io);
            while (q.head >= q.items.items.len and q.live.load(.acquire) != 0 and !q.aborted.load(.acquire)) {
                q.waiting += 1;
                q.cv.waitUncancelable(q.io, &q.mu);
                q.waiting -= 1;
            }
            q.mu.unlock(q.io);
            spins = 0;
        }
    }

    fn done(q: *Queue) void {
        // Walk complete — release every parked worker so it can retire.
        if (q.live.fetchSub(1, .acq_rel) == 1) q.wakeParked();
    }
};

// ─────────────────────────── streaming sink ───────────────────────────

/// What kind of fragment a worker just rendered — decides what inter-file
/// glue (if any) `Sink.emit` prepends before writing it.
const FragKind = enum { text_hit, text_plain, bin_hit, json };

/// The one shared stdout writer every worker streams through, the instant
/// each file's fragment is ready — replacing the old collect-everything →
/// sort-by-path → k-way-merge → single-write stitch. That buffered design
/// meant NOTHING reached a downstream reader until the entire corpus had
/// been walked, matched, and assembled: a piped `head -1` got zero benefit
/// from exiting early (measured: same wall-clock as capturing the full,
/// untruncated result — `rg | head -1` finishes in single-digit ms on the
/// same query by contrast, because ripgrep streams and cancels on the first
/// EPIPE). `emit` is the fix: write under a lock (so concurrent workers'
/// output never interleaves) the moment a match is found, and the moment a
/// write comes back closed-pipe, cancel the walk via `q.abort()` — the same
/// cooperative-cancellation shape ripgrep's own printer uses.
///
/// The trade: output now arrives in worker-discovery order, not the old
/// global path-sort — gist's own rgsuite harness already classifies an
/// order-only diff as a soft pass (`sort_lines(gist) == sort_lines(rg)`),
/// since a parallel walker's file order was never a byte-parity promise to
/// begin with. Every other framing (heading blank lines, `--` context-group
/// separators, per-file line order, the match/no-match exit code) is
/// unchanged — `first`/`matched_files` just move from a single-threaded
/// post-pass into this lock-guarded running state.
const Sink = struct {
    q: *Queue,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    heading: bool,
    join_groups: bool,
    first: bool = true, // guarded by `mu`
    matched_files: usize = 0, // guarded by `mu`
    // Bytes actually written to stdout (match stream + separators). `--stats`
    // reads this after the walk for `bytes printed` (quiet ⇒ forced to 0).
    bytes_printed: usize = 0, // guarded by `mu`

    fn noteWrite(self: *Sink, n: usize) void {
        self.bytes_printed += n;
    }

    fn emit(self: *Sink, kind: FragKind, buf: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.q.aborted.load(.monotonic)) return; // pipe already gone — nothing left to do
        var ok = true;
        // `--json` fragments are a whole file's `begin`/records/`end`, already a
        // self-framed record block — write it verbatim (order-insensitive per the
        // parity harness's `sort -u` set compare). A non-empty buffer ⟺ the file
        // matched (`json.emitOne` emits nothing otherwise), so it also drives the
        // matched-files exit code; the `summary` record is written once by `run`.
        if (kind == .json) {
            self.matched_files += 1;
            if (!corpus_mod.writeStdout(buf)) self.q.abort() else self.noteWrite(buf.len);
            return;
        }
        switch (kind) {
            .text_hit => {
                if (self.heading and !self.first) {
                    ok = corpus_mod.writeStdout("\n");
                    if (ok) self.noteWrite(1);
                }
                if (ok and self.join_groups and !self.first and buf.len > 0) {
                    ok = corpus_mod.writeStdout("--\n");
                    if (ok) self.noteWrite(3);
                }
                self.first = false;
                self.matched_files += 1;
            },
            .bin_hit => self.matched_files += 1,
            .text_plain => {},
            .json => unreachable, // handled above (self-framed record block)
        }
        if (ok) {
            ok = corpus_mod.writeStdout(buf);
            if (ok) self.noteWrite(buf.len);
        }
        if (!ok) self.q.abort();
    }

    /// Write ONE coalesced path-list chunk (`-l`/`--files`/`--files-without-match`):
    /// many `path+term` records a worker batched, plus their file count, in a
    /// single locked `write(2)`. This is the path-list twin of `emit` — the
    /// mutex + syscall is a per-chunk cost, not per file, so a high-hit scan
    /// stops serializing every worker behind the sink lock. Order-free (each
    /// chunk is a contiguous slice of one worker's matches).
    fn emitFilesChunk(self: *Sink, buf: []const u8, files: usize) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.q.aborted.load(.monotonic)) return;
        self.matched_files += files;
        if (!corpus_mod.writeStdout(buf)) self.q.abort() else self.noteWrite(buf.len);
    }
};

// ─────────────────────────── worker ───────────────────────────

/// Run-wide immutable configuration every worker shares.
const Cfg = struct {
    o: Opts,
    re: ?*const Matcher, // null only in --files mode
    ig: *const ignore.Ignore,
    compiled: ?*const ignore.Compiled, // rank-based base tier (null → decideAt)
    lazy: ?*LazyElide, // concurrent elide loader (null → no elision this run)
    file_needle: ?simd.Gate, // whole-file SIMD gate; null for passthru / invert modes
    // Multi-literal whole-file SIMD gate for pure alternations (`panic|0x`):
    // the union of these literals covers every match, so a body containing none
    // of them is dropped without a regex run. Non-empty only when `file_needle`
    // is null (a single required literal is the stronger gate) and the mode may
    // drop whole files. Because the set is a match EQUIVALENCE (see
    // `Regex.lits`), the `-l` fast path may also EMIT on a gate hit alone.
    file_alts: []const []const u8,
    // The whole-file literal gate that ran (`file_needle` or `file_alts`) is a
    // match EQUIVALENCE (`Regex.lits`): a gate hit PROVES some line matches, so
    // the `-l` fast path may emit without any engine run at all.
    lits_equiv: bool,
    // Longest gate literal (`file_needle`/`file_alts`), or 0 when no gate runs.
    // Sizes the straddle window when a stage-1-cleared prefix lets the gate
    // rescan only the tail: a literal crossing the prefix/tail seam can start
    // at most `gate_len-1` bytes before the seam.
    gate_len: usize,
    line_needle: ?simd.Gate, // required literal before each regex engine run
    // `-l` fused fast path is sound for this invocation: no flag reshapes the
    // per-line match decision away from "does any line match?" — so one fused
    // whole-buffer `docMatch` (early-exit, no line split, no per-line dispatch)
    // answers the file.
    fast_l: bool,
    use_color: bool,
    show_name: bool,
    heading: bool,
    join_groups: bool,
    binary_detect: bool,
    files_mode: bool,
    // Non-null ⇒ a `-z`/`-E` run: each worker rewrites a file's bytes
    // (decompress/transcode) before matching. Immutable + shared; every
    // `ingest.apply` call is thread-confined to the calling worker's arena.
    ingest: ?*const ingest.Config,
    // The phantom `tree.map` snapshot (rootless whole-CWD walks only; null
    // otherwise). Membership-only: admission (ignore/hidden/glob) is always
    // decided live, and a never-descended or clock-stale directory falls back
    // to the ordinary live listing — see `corpus/index/phantom/treemap.zig`.
    snap: ?*const treemap.View,
    // The content shard (`content.shard`): concatenated corpus bodies mmap'd
    // once, so a file the walk would open is instead served from the mapping
    // when the T3 clock rule proves it unchanged. Null when disabled, absent,
    // or not worth loading (narrow scope, `--files`, a transform run). Membership
    // + freshness only — a miss or a changed file reads live, byte-identically.
    shard: ?*const shard_mod.View,
    sink: *Sink,
    // `--sort`/`--sortr path`: hold each rendered fragment in the worker's arena
    // keyed by path (`Worker.recs`) rather than streaming it, so `run` can order
    // the whole result once (`emitSorted`). False ⇒ the streaming sink path.
    collect_sorted: bool = false,
    // `collectFileSet` only: force the clock-bearing `listOneLevel` listing and
    // carry each admitted file's walk-time mtime/ctime into its `recs` entry, so
    // the resident daemon's `reconcileOne` reads freshness straight off the walk
    // instead of re-`statFile`ing every path from CWD. Inert for search runs.
    freshness_meta: bool = false,
};

/// One rendered file fragment held for the ordered `--sort`/`--sortr` emit. The
/// fused walk renders every file in parallel exactly as the streaming path does;
/// the only difference is the bytes stay in this worker's arena (which outlives
/// the walk) keyed by `path`, so `run` orders the whole result once. `buf` is the
/// rendered block for a content mode; in `-l`/`--files` mode `buf` is unused (the
/// path IS the output) and `kind` is immaterial — `emitSorted` writes path+term.
// `mtime_ns`/`ctime_ns` are populated only on the `collectFileSet` freshness
// path (`Cfg.freshness_meta`); every other producer leaves them null.
const SortedRec = struct { path: []const u8, kind: FragKind, buf: []const u8, mtime_ns: ?i128 = null, ctime_ns: ?i128 = null };

/// A file discovered before the elide oracle finished loading — held back so
/// it can still be elided (or searched) once `LazyElide.ready` flips.
const Deferred = struct {
    disk: []const u8,
    rel: []const u8,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
};

const Worker = struct {
    q: *Queue,
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: *const Cfg,
    arena: std.heap.ArenaAllocator,
    pending: std.ArrayList(Deferred) = .empty,
    // Coalesced path-list output (`-l`/`--files`): a per-file lock+`write(2)`
    // under the shared sink mutex serialized every worker on a high-hit scan
    // (`\w{3,8} -l` matches ~every file — 20k locked syscalls), which capped
    // parallel scaling at ~1.4x. Batching each worker's paths into ~64 KiB
    // chunks (order-free by the files-list contract) makes the lock+syscall a
    // per-chunk cost. `out` is gpa-owned so it outlives per-file arena churn.
    out: std.ArrayList(u8) = .empty,
    out_files: usize = 0, // paths buffered in `out` since the last flush
    // `--sort`/`--sortr path` only (`Cfg.collect_sorted`): the worker's rendered
    // fragments held for the ordered final emit, keyed by path. Each `buf`/`path`
    // already lives in this worker's arena (no copy) — this list just references
    // them; `gpa`-owned so it survives per-file arena churn and `run` reads it
    // after join. Empty in the streaming (non-sorted) path.
    recs: std.ArrayList(SortedRec) = .empty,
    // Reusable boolean-match scratch (`Matcher.Sim` is per-thread by design):
    // lazily built once on first use, then reused for every file this worker
    // searches — the Pike generation counter self-invalidates between calls,
    // so no reset is needed and no per-file alloc/free is paid.
    sim: ?Matcher.Sim = null,
    // `--json` per-worker span scratch + running tally (both null/zero until the
    // first JSON file this worker renders). `run` sums every worker's `jstats`
    // for the single trailing `summary` record.
    jss: ?Matcher.SpanSim = null,
    jstats: json.Stats = .{},
    // `--stats` per-worker tally (`files_with_match` is filled once in `run`
    // from `sink.matched_files`; `bytes_printed` from `sink.bytes_printed`).
    // Summed across workers into the trailing stats block after the walk.
    stats: grepfile.Stats = .{},
};

/// Flush a worker's coalesced path-list buffer once it reaches this size — big
/// enough that the lock+`write(2)` amortizes over hundreds of paths, small
/// enough to stream (and to keep the soft output budget's cut at a whole-line
/// chunk boundary).
const files_flush_cap: usize = 64 * 1024;

/// Append one path-list record (`path` + its terminator) to the worker's
/// private buffer, flushing in a single locked write once it fills. Replaces a
/// per-file `Sink.emit` (lock + raw syscall) on the `-l`/`--files` hot paths.
fn bufferPath(w: *Worker, path: []const u8, term: []const u8) void {
    if (w.cfg.collect_sorted) {
        // `--sort`/`--sortr`: hold the path for the ordered emit (`emitSorted`
        // rewrites the terminator in sorted order); `path` lives in the arena.
        w.recs.append(w.gpa, .{ .path = path, .kind = .text_hit, .buf = "" }) catch oom();
        return;
    }
    w.out.appendSlice(w.gpa, path) catch oom();
    w.out.appendSlice(w.gpa, term) catch oom();
    w.out_files += 1;
    if (w.out.items.len >= files_flush_cap) flushFiles(w);
}

/// Stream one rendered fragment to the sink, or — under `--sort`/`--sortr` —
/// hold it in this worker's arena keyed by `dpath` for the ordered final emit.
/// The rendered bytes already live in the worker arena (which outlives the
/// walk), so holding a reference costs one record, never a copy.
fn deliver(w: *Worker, kind: FragKind, dpath: []const u8, buf: []const u8) void {
    if (w.cfg.collect_sorted) {
        w.recs.append(w.gpa, .{ .path = dpath, .kind = kind, .buf = buf }) catch oom();
        return;
    }
    w.cfg.sink.emit(kind, buf);
}

/// Drain the worker's buffered path list into the sink as one chunk.
fn flushFiles(w: *Worker) void {
    if (w.out_files == 0) return;
    w.cfg.sink.emitFilesChunk(w.out.items, w.out_files);
    w.out.clearRetainingCapacity();
    w.out_files = 0;
}

/// The worker's lazily-built reusable match scratch (null only on OOM, where
/// the caller degrades to "no match proven" — never an invented match).
fn workerSim(w: *Worker) ?*Matcher.Sim {
    if (w.sim == null) w.sim = Matcher.Sim.init(w.arena.allocator(), w.cfg.re.?) catch return null;
    return &w.sim.?;
}

/// The worker's lazily-built reusable span scratch for the `--json` encoder
/// (`Matcher.SpanSim` is per-thread, mirroring `workerSim`).
fn workerSpanSim(w: *Worker) ?*Matcher.SpanSim {
    if (w.jss == null) w.jss = Matcher.SpanSim.init(w.arena.allocator(), w.cfg.re.?) catch return null;
    return &w.jss.?;
}

/// A listed directory entry, normalized across the two listing backends and
/// the phantom snapshot. Snapshot entries (`from_snap`) carry no fd to resolve
/// against and no timestamps — `handleEntry` resolves them from CWD and, when
/// index elision could use freshness, learns the clocks with one lstat.
const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
    snap_ix: u32 = treemap.not_walked,
    from_snap: bool = false,
};

fn workerMain(w: *Worker) void {
    const a = w.arena.allocator();
    const scratch = w.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
    defer w.gpa.free(scratch);
    // Private LIFO stack: depth-first over directories this worker discovered
    // (parent listing still cache-warm), zero shared-queue traffic while it
    // has work. The shared queue is touched only to account (`noteDiscovered`
    // inside `processDir`, `done` here), to donate when a peer is parked, and
    // to blocking-pop when the local stack runs dry.
    var local: std.ArrayList(DirTask) = .empty;
    while (true) {
        if (w.q.aborted.load(.monotonic)) break; // downstream pipe closed — unwind now, not at tree's end
        const task = local.pop() orelse w.q.pop() orelse break;
        processDir(w, a, scratch, task, &local);
        w.q.done();
        if (local.items.len > 1 and w.q.starving.load(.monotonic) > 0) {
            // Give away the SHALLOWEST half — the oldest entries fan out the
            // widest subtrees, which is what a starving peer wants.
            const give = local.items.len / 2;
            w.q.donate(local.items[0..give]);
            std.mem.copyForwards(DirTask, local.items[0 .. local.items.len - give], local.items[give..]);
            local.items.len -= give;
        }
        flushPending(w, a, scratch, false);
    }
    // The walk is over (or cancelled); resolve whatever is still deferred
    // (see the policy note on `flushPending`) — unless the pipe is already
    // gone, in which case there's nothing left to search FOR.
    if (!w.q.aborted.load(.monotonic)) {
        flushPending(w, a, scratch, true);
        flushFiles(w); // drain the tail of this worker's coalesced path list
    }
}

/// Elide-or-search every deferred file. In-walk (`final=false`): only runs
/// once the loader has finished, retried after every directory. End-of-walk
/// (`final=true`): NEVER idles — but re-polls the loader per file as it drains
/// (see the loop), so a loader that lands mid-drain still elides the backlog's
/// tail. This keeps the "don't block on the oracle" contract (idling measured
/// 1.5x slower on warm `libs`-sized scopes) while recovering the cold-page-
/// cache race, where the 39 MiB index faults in after the fast metadata walk
/// has already deferred everything and the drain is long enough (disk-bound
/// reads) for the oracle to catch it.
fn flushPending(w: *Worker, a: std.mem.Allocator, scratch: []u8, final: bool) void {
    if (w.pending.items.len == 0) return;
    const lz = w.cfg.lazy.?; // pending is only ever fed when a loader exists
    var ready = lz.ready.load(.acquire);
    if (!ready and !final) return;
    const o = w.cfg.o;
    for (w.pending.items) |d| {
        // The oracle may still land while we drain: re-poll per file so its late
        // arrival elides the remaining tail instead of forfeiting every leftover
        // read. A cheap acquire load guarding an open+read, and it never idles —
        // a page-cache-warm reread just reads until the flip, so warm is untouched.
        if (final and !ready) ready = lz.ready.load(.acquire);
        if (ready) if (lz.val) |*el| if (el.skip(stripDot(d.rel), d.mtime_ns, d.ctime_ns)) {
            // Index proves no match: `--files-without-match` emits the path
            // without reading (the invert of `-l`'s elide-and-skip).
            if (o.files_without) {
                const dpath = if (o.path_sep) |sep| replaceSep(a, d.rel, sep) else d.rel;
                bufferPath(w, dpath, if (o.null_sep) "\x00" else o.outTerm());
            }
            continue;
        };
        const dpath = if (o.path_sep) |sep| replaceSep(a, d.rel, sep) else d.rel;
        if (w.cfg.shard) |sh| if (sh.slice(stripDot(d.rel), d.mtime_ns, d.ctime_ns)) |bytes| {
            searchShardBody(w, a, dpath, bytes);
            continue;
        };
        searchFile(w, a, scratch, std.posix.AT.FDCWD, d.disk, dpath, d.disk);
    }
    w.pending.clearRetainingCapacity();
}

/// Display/ignore join: an explicit `.` root KEEPS its `./` prefix on every
/// emitted path (serial `relPath` / rg parity); only the implicit whole-CWD
/// walk ("" prefix) emits bare paths.
fn joinRel(a: std.mem.Allocator, prefix: []const u8, name: []const u8) []const u8 {
    return if (prefix.len == 0) name else std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name }) catch oom();
}

/// This directory's own ignore rules chained onto the parent's — unless the
/// frozen base already holds them (the CWD root, loaded by `Ignore.init`;
/// keyed by stripped rel). Shared by the live and phantom listings.
fn dirChain(cfg: *const Cfg, a: std.mem.Allocator, task: DirTask, present: IgPresent) ?*const IgNode {
    if (!cfg.o.no_ignore and (present.gitignore or present.dotignore or present.rgignore) and
        !cfg.ig.loaded.contains(task.rel) and !cfg.ig.loaded.contains(stripDot(task.rel)))
        return loadNode(cfg.ig, a, task.chain, task.disk, task.rel, present);
    return task.chain;
}

/// The same walk-error contract `run.zig`'s serial `reportWalkError` enforces
/// (rendering shared via `grepfile.printWalkError`), for the parallel engine:
/// a directory this walk discovered but could not open/descend is a POTENTIAL
/// false negative that MUST be signaled, never dropped in silence just because
/// a peer worker is mid-flight. Thread-safe (any worker may call concurrently).
fn reportWalkError(q: *Queue, rel: []const u8, e: anyerror) void {
    grepfile.printWalkError(rel, e);
    q.walk_error.store(true, .release);
}

fn processDir(w: *Worker, a: std.mem.Allocator, scratch: []u8, task: DirTask, local: *std.ArrayList(DirTask)) void {
    const cfg = w.cfg;

    // Phantom walk: a recorded directory whose lstat proves BOTH clocks
    // predate the snapshot anchor has byte-exact recorded membership (POSIX
    // bumps a directory's mtime+ctime on any direct create/delete/rename) —
    // serve its listing from the mapping for ONE syscall instead of
    // openat+getattrlistbulk+close. A stale, unstat-able, or unrecorded
    // directory falls through to the live listing below unchanged.
    if (cfg.snap) |v| if (task.snap_ix != treemap.not_walked) {
        if (grepfile.lstatPath(task.disk)) |st| if (!bulkstat.needsLiveRead(v.anchor_ns, st.mtime_ns, st.ctime_ns)) {
            servePhantomDir(w, a, scratch, task, local, v);
            return;
        };
    };

    // Raw `openat` (worker-thread safe, no std.Io indirection) — the fd feeds
    // `getattrlistbulk` directly and is wrapped in a `Dir` only for the
    // portable fallback. An unreadable/EACCES directory is a walk error, not a
    // silent prune (rg parity — see `reportWalkError`).
    const fd = std.posix.openat(std.posix.AT.FDCWD, task.disk, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |e| {
        reportWalkError(w.q, task.rel, e);
        return;
    };
    var dir: Dir = .{ .handle = fd };
    var closed = false;
    defer if (!closed) {
        _ = std.posix.system.close(dir.handle);
    };

    // List the whole directory FIRST — the names tell us which ignore files
    // exist here, so the chain build below never blind-probes the disk.
    var entries: std.ArrayList(Entry) = .empty;
    var present: IgPresent = .{};
    const bulk_ok = bulkstat.supported and blk: {
        // With index elision live, each entry's mtime+ctime ride the bulk
        // listing for free; without it, names+types via getdirentries is cheaper.
        const listing = if (freshnessWanted(cfg)) bulkstat.listOneLevel(a, dir.handle) else bulkstat.listNamesOnly(a, dir.handle);
        const listed = listing catch break :blk false;
        for (listed) |e| {
            noteIgnoreFile(&present, e.name, e.is_file);
            entries.append(a, .{ .name = e.name, .is_dir = e.is_dir, .is_file = e.is_file, .mtime_ns = e.mtime_ns, .ctime_ns = e.ctime_ns }) catch oom();
        }
        break :blk true;
    };
    if (!bulk_ok) {
        if (bulkstat.supported) {
            // Bulk listing is all-or-nothing but shares the fd offset with
            // readdir — reopen a fresh handle before the portable fallback.
            _ = std.posix.system.close(dir.handle);
            closed = true;
            const fd2 = std.posix.openat(std.posix.AT.FDCWD, task.disk, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |e| {
                reportWalkError(w.q, task.rel, e);
                return;
            };
            dir = .{ .handle = fd2 };
            closed = false;
        }
        var it = dir.iterate();
        while (true) {
            // A `next` error is this directory's iteration failing after it was
            // opened (deleted mid-walk, FS error): report it and STOP iterating
            // THIS directory (the reader's cursor never advances past a failed
            // read — see std.Io.Dir.Reader.next / SelectiveWalker.next's own
            // "all future `next` calls would likely just fail with the same
            // error" comment — so a `continue` here would spin forever on the
            // same errno). The walk still finishes every OTHER directory; rg's
            // own "keep walking past an error" behavior is preserved at the
            // per-directory grain via the queue draining other tasks.
            const maybe = it.next(w.io) catch |e| {
                reportWalkError(w.q, task.rel, e);
                break;
            };
            const e = maybe orelse break;
            if (e.kind != .file and e.kind != .directory) continue;
            var mtime: ?i128 = null;
            var ctime: ?i128 = null;
            // Change timestamps are only consulted for elision candidates;
            // stat lazily there. A failed stat leaves both unknown, forcing read.
            if (e.kind == .file and freshnessWanted(cfg)) if (dir.statFile(w.io, e.name, .{})) |st| {
                mtime = st.mtime.nanoseconds;
                ctime = st.ctime.nanoseconds;
            } else |_| {};
            // The iterator's name buffer is reused on the next `next()` —
            // fragments/tasks hold rel paths built from it, so own a copy.
            const name = a.dupe(u8, e.name) catch oom();
            noteIgnoreFile(&present, name, e.kind == .file);
            entries.append(a, .{ .name = name, .is_dir = e.kind == .directory, .is_file = e.kind == .file, .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
        }
    }

    // A live-listed directory that HAS a snapshot record (its own clocks were
    // stale) still hands each child directory ITS record, so phantom serving
    // resumes immediately below the one changed level.
    if (cfg.snap) |v| if (task.snap_ix != treemap.not_walked) {
        for (entries.items) |*e| {
            if (!e.is_dir) continue;
            for (v.children(task.snap_ix)) |ent| {
                if (ent.isDir() and std.mem.eql(u8, v.name(ent), e.name)) {
                    e.snap_ix = ent.dir_ix;
                    break;
                }
            }
        }
    };

    const chain = dirChain(cfg, a, task, present);

    // Children go on the worker's own stack; only the COUNT touches the
    // shared queue (accounting must precede this task's `done`).
    const before = local.items.len;
    for (entries.items) |e| handleEntry(w, a, scratch, dir.handle, task, chain, local, e);
    w.q.noteDiscovered(local.items.len - before);
}

/// The phantom twin of `processDir`'s listing half: children come straight
/// from the snapshot mapping (names + kinds — the lstat in `processDir`
/// just proved them current), the ignore chain builds from the recorded
/// ignore-file NAMES with rule CONTENT read live from disk, and every child
/// then flows through the same `handleEntry` the live listing feeds. Snapshot
/// entries resolve from CWD (`from_snap`) since no directory fd is open.
fn servePhantomDir(w: *Worker, a: std.mem.Allocator, scratch: []u8, task: DirTask, local: *std.ArrayList(DirTask), v: *const treemap.View) void {
    const cfg = w.cfg;
    const kids = v.children(task.snap_ix);
    var present: IgPresent = .{};
    for (kids) |ent| noteIgnoreFile(&present, v.name(ent), !ent.isDir());
    const chain = dirChain(cfg, a, task, present);
    const before = local.items.len;
    for (kids) |ent| handleEntry(w, a, scratch, std.posix.AT.FDCWD, task, chain, local, .{
        .name = v.name(ent),
        .is_dir = ent.isDir(),
        .is_file = !ent.isDir(),
        .mtime_ns = null,
        .ctime_ns = null,
        .snap_ix = ent.dir_ix,
        .from_snap = true,
    });
    w.q.noteDiscovered(local.items.len - before);
}

/// Before the loader decides, both timestamps are needed for deferred elision.
/// Once it declines a dense/small index, switch later directories back to the
/// cheaper names-only listing immediately.
fn needsElisionMetadata(cfg: *const Cfg) bool {
    const lazy = cfg.lazy orelse return false;
    if (!lazy.ready.load(.acquire)) return true;
    return lazy.val != null;
}

/// Whether the walk should learn each file's mtime+ctime — for index elision
/// (above) OR to let the content shard prove a file unchanged before serving
/// its bytes from the mapping. The shard turns a full-scan query (no elision)
/// from names-only listing back to the clock-bearing `listOneLevel`, trading a
/// per-directory bulk-attr call for ~20k avoided file opens.
fn freshnessWanted(cfg: *const Cfg) bool {
    return needsElisionMetadata(cfg) or cfg.shard != null or cfg.freshness_meta;
}

fn handleEntry(w: *Worker, a: std.mem.Allocator, scratch: []u8, dirfd: std.posix.fd_t, task: DirTask, chain: ?*const IgNode, children: *std.ArrayList(DirTask), e: Entry) void {
    const cfg = w.cfg;
    const o = cfg.o;
    if (!e.is_dir and !e.is_file) return; // symlinks & specials — never followed here
    const depth = task.depth + 1;
    const rel = joinRel(a, task.rel, e.name);
    const scope_rel = joinRel(a, task.scope, e.name);
    if (shouldSkip(cfg, chain, a, task, rel, scope_rel, e.is_dir, e.name)) return;
    if (e.is_dir) {
        if (o.max_depth != 0 and depth >= o.max_depth) return;
        children.append(a, .{ .disk = joinPath(a, task.disk, e.name), .rel = rel, .scope = scope_rel, .depth = depth, .root_depth = task.root_depth, .chain = chain, .snap_ix = e.snap_ix }) catch oom();
        return;
    }
    if (o.max_depth != 0 and depth > o.max_depth) return;
    if (o.filter.active() and !o.filter.admits(a, scope_rel)) return;
    // Admitted: every filter that decides "would rg have searched this file"
    // has passed. Flag BEFORE index elision — an elided file still counts as
    // walked for the implicit-path nothing-searched heuristic (see `Queue`).
    if (!w.q.files_seen.load(.monotonic)) w.q.files_seen.store(true, .monotonic);
    // A snapshot-served file carries no clocks; when elision could use them,
    // one lstat learns the SAME conservative freshness pair the bulk listing
    // returns — and only for files every earlier filter already admitted
    // (a glob-rejected file never pays it; the bulk path pays for all).
    var mtime = e.mtime_ns;
    var ctime = e.ctime_ns;
    if (e.from_snap and freshnessWanted(cfg)) if (grepfile.lstatPath(joinPath(a, task.disk, e.name))) |st| {
        mtime = st.mtime_ns;
        ctime = st.ctime_ns;
    };
    if (cfg.lazy) |lz| {
        if (lz.ready.load(.acquire)) {
            if (lz.val) |*el| if (el.skip(stripDot(scope_rel), mtime, ctime)) {
                // Index proves no match: `--files-without-match` emits without
                // reading (invert of `-l`'s elide-and-skip). `--stats` never
                // arms the oracle (see `want_elision`), so it can't land here.
                if (o.files_without) {
                    const dpath = if (o.path_sep) |sep| replaceSep(a, rel, sep) else rel;
                    bufferPath(w, dpath, if (o.null_sep) "\x00" else o.outTerm());
                }
                return;
            };
        } else {
            // Oracle still loading — hold the file back so it can still be
            // elided (the walk races ahead; deferring costs three slices + metadata).
            w.pending.append(a, .{ .disk = joinPath(a, task.disk, e.name), .rel = rel, .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
            return;
        }
    }

    const dpath = if (o.path_sep) |sep| replaceSep(a, rel, sep) else rel;
    if (cfg.files_mode) {
        // `collectFileSet`: carry the walk-time clocks with the path so the
        // daemon's reconcile reads freshness off the walk (no per-file stat).
        if (cfg.freshness_meta) {
            w.recs.append(w.gpa, .{ .path = dpath, .kind = .text_hit, .buf = "", .mtime_ns = mtime, .ctime_ns = ctime }) catch oom();
            return;
        }
        // Coalesced into the worker's path-list buffer — one locked write per
        // ~64 KiB chunk instead of a lock+syscall per listed file.
        bufferPath(w, dpath, if (o.null_sep) "\x00" else "\n");
        return;
    }
    // Content shard: an unchanged corpus file's bytes are already mmap'd, so
    // serve them straight into the match/emit tail instead of opening the file
    // (the whole point on a full-scan query). A miss (changed, new, binary,
    // oversize, out-of-scope) falls through to the live open below.
    if (cfg.shard) |sh| if (sh.slice(stripDot(rel), mtime, ctime)) |bytes| {
        searchShardBody(w, a, dpath, bytes);
        return;
    };
    // The parent directory is still open in `processDir` — resolve one
    // component (`e.name`) against its fd instead of the full path from CWD.
    // A snapshot-served entry has no open parent; it resolves from CWD like a
    // deferred read. `rel` is the CWD-openable path a `-z` external-codec
    // subprocess re-opens.
    if (e.from_snap)
        searchFile(w, a, scratch, std.posix.AT.FDCWD, joinPath(a, task.disk, e.name), dpath, rel)
    else
        searchFile(w, a, scratch, dirfd, e.name, dpath, rel);
}

/// Match+render a file whose bytes came from the content-shard mapping rather
/// than a live read. The mmap'd slice is the file's raw bytes (shard membership
/// is `corpus.readMember` — non-binary, so no NUL triage is owed and no UTF-16
/// transcode can fire; a bare UTF-8 BOM still strips via `decodeBom`). Nothing
/// was pre-scanned, so `emitBody` runs the gate + match over the whole body
/// (covered = gate_from = 0) — byte-identical to the staged read path's result.
fn searchShardBody(w: *Worker, a: std.mem.Allocator, dpath: []const u8, bytes: []const u8) void {
    const body = grepfile.decodeBom(a, bytes);
    if (w.cfg.o.json) return emitJson(w, a, dpath, body);
    if (body.len == 0) return noteEmpty(w, dpath);
    emitBody(w, a, dpath, body, 0, 0);
}

/// Empty-body bookkeeping shared by the live and shard read paths. An empty
/// file has no match: `--files-without-match` emits its path; `--stats` skips
/// it unless `--include-zero` (mirrors serial `renderFile`'s `count_zero` gate,
/// which parallel never arms for `--stats` alone).
fn noteEmpty(w: *Worker, dpath: []const u8) void {
    const o = w.cfg.o;
    if (o.files_without) bufferPath(w, dpath, if (o.null_sep) "\x00" else o.outTerm());
}

/// The `--json` per-file render on the parallel walk: emit ripgrep's
/// `begin`/`match`/`end` records for ONE file through the shared `json.emitOne`
/// (the identical encoder the serial/shard `--json` path uses), tallying this
/// worker's running `jstats`, then stream the self-framed record block through
/// the sink. `run` sums every worker's `jstats` into the single trailing
/// `summary`. Byte-identical to the serial collect-then-shard path by
/// construction: the SAME `file_needle` whole-file gate decides which admitted
/// files are searched (mirroring `readOneCandidate` — a body missing the required
/// literal provably can't match, so it is neither searched nor counted, keeping
/// the `searches` tally in lockstep), and `line_needle` accelerates the per-line
/// span scan inside `emitOne`. `file_alts` is deliberately NOT applied — the
/// serial collect path gates `--json` on the single `file_needle` only.
fn emitJson(w: *Worker, a: std.mem.Allocator, dpath: []const u8, decoded: []const u8) void {
    const cfg = w.cfg;
    const body = grepfile.stripBom(decoded);
    if (cfg.file_needle) |gate| if (!verify.gateWide(a, body, gate)) return;
    const ss = workerSpanSim(w) orelse return;
    var buf: std.ArrayList(u8) = .empty;
    json.emitOne(a, &buf, cfg.re.?, ss, null, cfg.o, .{ .path = dpath, .body = body }, &w.jstats, cfg.line_needle);
    if (buf.items.len > 0) cfg.sink.emit(.json, buf.items);
}

/// Read + match + render ONE file straight into the sink — the parallel
/// twin of the serial engine's per-file loop body (`run.zig`), built from the
/// same `grepfile` primitives so the two cannot drift. `disk` is resolved
/// relative to `dirfd` (the walk passes the still-open parent directory so the
/// kernel resolves one component; deferred/elision reads pass `AT.FDCWD` with
/// the full path).
fn searchFile(w: *Worker, a: std.mem.Allocator, scratch: []u8, dirfd: std.posix.fd_t, disk: []const u8, dpath: []const u8, openable: []const u8) void {
    const cfg = w.cfg;
    const o = cfg.o;
    const re = cfg.re.?;

    // `--json` reads the WHOLE body (rg emits every match line's record) and
    // renders it through `emitJson`, bypassing the text prefix-triage/`-l`
    // fast paths below — `--json` declines `-z`/`-E` (see `eligible`), so no
    // transform is owed here. Every admitted file reaches `emitJson` exactly
    // once, so its `searches` tally stays byte-identical to the serial path.
    if (o.json) {
        const sf = grepfile.StagedFile.open(scratch, dirfd, disk) orelse return;
        defer sf.close();
        const raw = if (sf.more) (sf.readRest(a, scratch) orelse return) else sf.prefix;
        return emitJson(w, a, dpath, grepfile.decodeBom(a, raw));
    }

    // Transform run (`-z`/`-E`): the on-disk bytes are compressed/encoded, so the
    // staged prefix triage below (a NUL sniff, an `-l` prefix proof) would read
    // garbage — read the WHOLE file, rewrite it via `ingest`, then match the
    // decoded body from offset 0 (covered/gate_from = 0). `openable` is the
    // CWD-relative path the external-codec subprocess (bz2/lz4/br) re-opens;
    // native decoders (gz/zst/xz) and `-E` reuse the bytes we just read. A null
    // return is a dropped file (never reached here: `--pre`, the only dropping
    // transform, stays on the serial engine).
    if (cfg.ingest) |icfg| {
        const sf = grepfile.StagedFile.open(scratch, dirfd, disk) orelse return;
        defer sf.close();
        const raw = sf.readRest(a, scratch) orelse return;
        const body = ingest.apply(a, icfg, openable, dpath, raw) orelse return;
        if (body.len == 0) return noteEmpty(w, dpath);
        return emitBody(w, a, dpath, body, 0, 0);
    }

    const sf = grepfile.StagedFile.open(scratch, dirfd, disk) orelse return;
    defer sf.close();

    // Stage 1 — decide what the first BUFCAP bytes (rg's buffer 0) already
    // settle, before paying for the tail (86% of this corpus's bytes live in
    // the tails of >64 KiB files). A UTF-16 BOM opts out: the transcode needs
    // the whole file and dissolves its NULs, so no prefix triage is sound.
    const utf16 = std.mem.startsWith(u8, sf.prefix, "\xFF\xFE") or std.mem.startsWith(u8, sf.prefix, "\xFE\xFF");
    if (!utf16) {
        // NUL in buffer 0: rg's emission cutoff is the start of the buffer that
        // holds the first NUL — the very first — so an implicit walked file
        // contributes NOTHING in content modes (`-l`, default, `-c`, context,
        // `-o`, `--files-without-match`). `--stats` still needs the committed-
        // prefix tally (serial `renderFile`'s binary arm), so it falls through
        // to the full read + `emitBody` binary path. `--binary`-style explicit
        // files never reach this engine.
        if (cfg.binary_detect and std.mem.indexOfScalar(u8, sf.prefix, 0) != null and !o.stats) return;
        // `-l` / `--files-without-match` + a >64 KiB file: a match PROVEN
        // inside the NUL-free prefix settles the file — `-l` emits and skips
        // the tail; `--files-without-match` skips WITHOUT emitting (the file
        // HAS a match). Absence proves nothing; fall through to the full read.
        if (cfg.fast_l and sf.more and prefixProvesMatch(w, re, grepfile.stripBom(sf.prefix))) {
            if (!o.files_without) bufferPath(w, dpath, if (o.null_sep) "\x00" else o.outTerm());
            return;
        }
    }
    const raw = if (sf.more) (sf.readRest(a, scratch) orelse return) else sf.prefix;
    const body = grepfile.decodeBom(a, raw);
    if (body.len == 0) return noteEmpty(w, dpath);
    // Bytes of `body` already covered by the stage-1 prefix scans, in body
    // space: `body` aliases `raw` at offset 0 or 3 (UTF-8 BOM strip), so the
    // scanned raw prefix maps to `body[0..covered]`. A UTF-16 transcode built a
    // fresh buffer with different bytes — nothing carries over (covered = 0).
    const covered: usize = if (utf16) 0 else sf.prefix.len -| (@intFromPtr(body.ptr) - @intFromPtr(raw.ptr));
    // Literal gate. When stage 1 already proved the equivalence gate absent
    // from the prefix (fast_l + tail present + no early emit above), rescan
    // only the unseen tail plus a `gate_len-1` straddle window for a literal
    // crossing the seam — not the whole body again.
    const gate_from: usize = if (cfg.fast_l and cfg.lits_equiv and !utf16 and sf.more) covered -| (cfg.gate_len - 1) else 0;
    emitBody(w, a, dpath, body, covered, gate_from);
}

/// The shared match+render tail: literal gate, binary handling, the `-l` fused
/// fast path, and the per-line emit — streamed into the sink. Both callers reach
/// it with a fully-decoded `body`: the staged read path (raw on-disk bytes,
/// `covered`/`gate_from` reflecting its stage-1 prefix scan) and the transform
/// path (`ingest`-rewritten bytes, both 0 — nothing was pre-scanned).
fn emitBody(w: *Worker, a: std.mem.Allocator, dpath: []const u8, body: []const u8, covered: usize, gate_from: usize) void {
    const cfg = w.cfg;
    const o = cfg.o;
    const re = cfg.re.?;
    // The `Wide` gates are the plain SIMD kernels until a body crosses
    // `verify.wide_threshold` (16 MiB) — then the presence test itself fans
    // out across cores. One worker owning an mmap'd multi-GiB blob (which the
    // rg-parity walk legitimately admits via explicit-root scoping) stops
    // serializing the whole walk behind a single-thread scan.
    // Whole-file gate miss: the body can't match. `-l` drops it; `--files-
    // without-match` emits the path (the invert); `--stats` tallies a searched
    // zero-hit file (rg counts non-matching bytes as searched) and drops the
    // content stream. Content modes return silently.
    if (cfg.file_needle) |n| if (!verify.gateWide(a, body[gate_from..], n)) {
        gateMiss(w, dpath, body);
        return;
    };
    if (cfg.file_alts.len > 0 and !verify.containsAnyWide(a, body[gate_from..], cfg.file_alts)) {
        gateMiss(w, dpath, body);
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    var em: Emitter = .{
        .a = a,
        .re = re,
        .o = o,
        // The serial engine keys this off the RAW --heading flag (not the
        // count/files-only-adjusted `cfg.heading`) — match it exactly.
        .show_name = if (o.heading) false else cfg.show_name,
        .out = &buf,
        .base = @intFromPtr(body.ptr),
        .body_end = @intFromPtr(body.ptr) + body.len,
        .use_color = cfg.use_color,
        .needle = cfg.line_needle,
        // The worker's reusable scratch (null only on OOM ⇒ Emitter builds a
        // local) — one Sim per worker instead of three allocs per file.
        .sim = workerSim(w),
    };

    // Stage 1 already proved `body[0..covered]` NUL-free (or we'd have
    // returned there), so the first NUL — the binary cutoff — can only sit in
    // the unseen tail. Sub-cap files are fully covered: zero bytes rescanned.
    if (cfg.binary_detect) if (std.mem.indexOfScalarPos(u8, body, covered, 0)) |nul| {
        // rg's -U slice model runs only when the pattern can actually match
        // `\n`; slice model + NUL beyond the 64K sniff means the searcher never
        // notices it — ordinary text, fall through to the normal path.
        if (!(o.multiline and re.canMatchNewline() and !grepfile.multilineBinary(body.len, nul))) {
            // `--files-without-match` skips binary files entirely (serial
            // `fileWithoutMatch` returns before any emit) — no path, no tally.
            if (o.files_without) return;
            if (o.stats) {
                // Walked (implicit) file: only the committed prefix was
                // searched — mirror serial `renderFile`'s binary stats arm.
                const searched = body[0..grepfile.committedPrefix(body, nul)];
                var blines: std.ArrayList([]const u8) = .empty;
                if (!o.multiline) grepfile.collectLines(a, searched, o.term(), &blines);
                const fs = grepfile.fileMatchStats(re, a, o, searched, blines.items, cfg.line_needle);
                w.stats.add(.{ .files_searched = 1, .matches = fs.matches, .matched_lines = fs.lines, .bytes_searched = fs.bytes });
            }
            const matched = grepfile.handleBinary(a, re, o, &buf, &em, dpath, false, body, nul, cfg.show_name);
            if (matched or buf.items.len > 0)
                deliver(w, if (matched) .bin_hit else .text_plain, dpath, buf.items);
            return;
        }
    };

    // `-l` / `--files-without-match` fused fast path: one early-exit whole-
    // buffer pass answers the file — no line split, no per-line engine
    // dispatch. When the pattern is a pure literal (alternation), the whole-
    // file gate above already PROVED the match (equivalence, not containment),
    // so not even `docMatch` runs. A containment-only gate still drives the
    // scan: jump gate hit to gate hit at SIMD speed and run the engine on just
    // each hit's line (`gatedDocMatch`). `--files-without-match` emits on a
    // MISS (the invert of `-l`).
    if (cfg.fast_l) {
        const hit = cfg.lits_equiv or blk: {
            const sim = workerSim(w) orelse break :blk false;
            // `-U`: the whole-buffer boolean — `run` admits `fast_l` here only
            // when `bufBoolExact` proved it equals the emit model's verdict.
            if (o.multiline) break :blk re.bufMatch(sim, body);
            // Caseless only: the case-sensitive whole-body `docMatch` is
            // already DFA-fast, while the caseless engine pays per byte —
            // that is the run the hit-jump rescues.
            if (cfg.file_needle) |n| if (n.ci) break :blk gatedDocMatch(re, sim, n, body);
            break :blk re.docMatch(sim, body);
        };
        if (hit != o.files_without) bufferPath(w, dpath, if (o.null_sep) "\x00" else o.outTerm());
        return;
    }

    // `-U` renders through the whole-buffer emitter (no line split — a match
    // may cross `\n`); the per-line model splits into rg lines. The line-free
    // literal fast path (`Emitter.fileLit`) — rg's candidate-jump searcher —
    // reads `body` directly, so skip `collectLines` when it is eligible. This is
    // exactly the count/`-o`/`-n`/plain literal regime `fast_l` above does not
    // cover; without it every worker paid a full line split + per-line engine
    // dispatch on a ubiquitous literal the index can't prune. Mirrors the serial
    // engine's per-file dispatch exactly. `--stats` disables the fused class-run
    // shortcut (it needs the line array for `fileMatchStats`, like serial).
    const fast = !o.multiline and em.litFastEligible();
    const fused = !o.multiline and !fast and !o.stats and em.fusedFileEligible();
    var lines: std.ArrayList([]const u8) = .empty;
    if (!o.multiline and !fast and !fused) grepfile.collectLines(a, body, o.term(), &lines);
    if (o.stats) {
        const fs = grepfile.fileMatchStats(re, a, o, body, lines.items, cfg.line_needle);
        w.stats.add(.{ .files_searched = 1, .matches = fs.matches, .matched_lines = fs.lines, .bytes_searched = fs.bytes });
    }
    if (cfg.heading) buf.print(a, "{s}{s}", .{ dpath, o.outTerm() }) catch oom();
    const before_body = buf.items.len;
    const hits = if (o.multiline) em.buffer(dpath, body) else if (fast) em.fileLit(dpath, body, 0, body.len, 0, true) else em.file(dpath, lines.items);
    if (hits > 0) return deliver(w, .text_hit, dpath, buf.items);
    // No heading header to keep, and (except --passthru) no body either.
    if (!cfg.heading and buf.items.len > before_body) deliver(w, .text_plain, dpath, buf.items);
}

/// Whole-file gate / alts miss: settle `--files-without-match` (emit) and
/// `--stats` (tally a zero-hit searched file); every other mode is a silent drop.
/// `--stats` bytes follow the binary cutoff: a walked file with a NUL only
/// contributes its committed prefix (serial `renderFile`'s binary arm).
fn gateMiss(w: *Worker, dpath: []const u8, body: []const u8) void {
    const o = w.cfg.o;
    if (o.files_without) {
        bufferPath(w, dpath, if (o.null_sep) "\x00" else o.outTerm());
    } else if (o.stats) {
        var bytes = body.len;
        if (w.cfg.binary_detect) if (std.mem.indexOfScalar(u8, body, 0)) |nul| {
            bytes = grepfile.committedPrefix(body, nul);
        };
        w.stats.add(.{ .files_searched = 1, .bytes_searched = bytes });
    }
}

/// The gate-driven `-l` boolean: every matching line must contain the gate
/// literal (the gate is a per-match necessary condition), so instead of
/// running the engine over every admitted byte, jump from gate hit to gate
/// hit with the SIMD kernel and run the engine only on each hit's enclosing
/// line. Exact: a matching line holds a gate hit inside it, so it is visited;
/// a rejected line's remaining hits are skipped by resuming past its end.
/// This is what keeps a caseless run at SIMD throughput — the fold-heavy
/// engine (whose caseless DFA pays per byte) touches only gate-hit lines.
fn gatedDocMatch(re: *const Matcher, sim: *Matcher.Sim, gate: simd.Gate, body: []const u8) bool {
    var from: usize = 0;
    while (gate.find(body, from)) |pos| {
        const ls = if (std.mem.lastIndexOfScalar(u8, body[0..pos], '\n')) |k| k + 1 else 0;
        const le = std.mem.indexOfScalarPos(u8, body, pos, '\n') orelse body.len;
        if (re.lineMatch(sim, body[ls..le])) return true;
        if (le >= body.len) break;
        from = le + 1;
    }
    return false;
}

/// Positive-only match proof over a buffer prefix: true ⇒ the file matches
/// (emit and skip its tail); false ⇒ undecided (the caller reads the rest).
/// The pure-literal equivalence answers from SIMD `contains` alone — sound even
/// inside the truncated final line, since a literal carries no `\n` and so sits
/// inside the real (longer) line too. The regex path instead sees only COMPLETE
/// lines: a truncated line's cut IS an end-of-line to `docMatch`, so `$`/`^$`
/// could fire where the real line continues — a false positive the trim removes.
fn prefixProvesMatch(w: *Worker, re: *const Matcher, prefix: []const u8) bool {
    const cfg = w.cfg;
    if (cfg.lits_equiv) {
        if (cfg.file_needle) |n| return n.in(prefix);
        return simd.containsAny(prefix, cfg.file_alts);
    }
    if (cfg.o.multiline) {
        // `-U`: sound only for an assertion-free pattern (substring-closed —
        // nothing zero-width can assert against the cut), and then the RAW
        // prefix serves: any match inside it is a match of the file.
        if (!re.bufPrefixClosed()) return false;
        const sim = workerSim(w) orelse return false;
        return re.bufMatch(sim, prefix);
    }
    const nl = std.mem.lastIndexOfScalar(u8, prefix, '\n') orelse return false;
    const sim = workerSim(w) orelse return false;
    return re.docMatch(sim, prefix[0 .. nl + 1]);
}

// ─────────────────────────── sorted emit ───────────────────────────

/// `--sort`/`--sortr path` order over the collected fragments. Ascending is
/// `serial.pathLess` (rg's `Path::cmp`, `/` ranked below every byte); this
/// engine only takes ascending path for a single/implicit root, where rg's
/// per-argv-root walker order (`lessAscPathWalk`) collapses to exactly that.
/// Descending is the global mirror (`--sortr`'s `ordering.reverse()`), valid for
/// any root count — swapping the operands flips the tiebreak too.
fn recLess(reverse: bool, x: SortedRec, y: SortedRec) bool {
    return if (reverse) serial.pathLess(y.path, x.path) else serial.pathLess(x.path, y.path);
}

/// Gather every worker's held fragments, order them once, and replay them
/// through the SAME `Sink` the streaming path uses — so heading/context
/// separators (`emit`'s `first`/`join_groups` logic, now driven in sorted
/// order) and the `matched_files` exit-code tally stay byte-identical to the
/// serial sort oracle. `-l`/`--files` records carry only a path: rewrite the
/// terminator here and emit them as one coalesced chunk.
fn emitSorted(gpa: std.mem.Allocator, sink: *Sink, workers: []Worker, o: Opts) void {
    var total: usize = 0;
    for (workers) |*w| total += w.recs.items.len;
    if (total == 0) return;
    const recs = gpa.alloc(SortedRec, total) catch oom();
    defer gpa.free(recs);
    var k: usize = 0;
    for (workers) |*w| for (w.recs.items) |r| {
        recs[k] = r;
        k += 1;
    };
    std.mem.sort(SortedRec, recs, o.sort_reverse, recLess);
    if (o.files_list or o.files_only) {
        const term: []const u8 = if (o.null_sep) "\x00" else o.outTerm();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (recs) |r| {
            out.appendSlice(gpa, r.path) catch oom();
            out.appendSlice(gpa, term) catch oom();
        }
        sink.emitFilesChunk(out.items, recs.len);
    } else for (recs) |r| sink.emit(r.kind, r.buf);
}

// ─────────────────────────── run ───────────────────────────

/// Fan out, walk, search, stream, exit. `filters` powers inline index elision;
/// `file_needle` may reject a whole body, while `line_needle` only avoids regex
/// execution and remains valid for passthru. Never returns.
pub fn run(gpa: std.mem.Allocator, io: std.Io, parsed: args.Parsed, o: Opts, re: ?*const Matcher, use_color: bool, filters: []const []const u8, sieve: crest.Vector, file_needle: ?simd.Gate, line_needle: ?simd.Gate, icfg: *const ingest.Config) noreturn {
    // Heading needs a printable path: `--no-filename` suppresses the header
    // like rg (the walk is recursive, so `.auto` filenames are always on here).
    const heading = o.heading and o.filename != .never and !o.count_only and !o.count_matches and !o.files_only and !o.files_without and !o.vimgrep;
    // `--stats` must visit every admitted file for `files searched` /
    // `bytes searched`, so the index oracle (which drops proven non-matches)
    // stays off — the fused walk still beats serial's collect-then-shard.
    // `--files-without-match` KEEPS elision: a proven non-match IS the emit.
    const want_elision = !o.stats and indexElisionWanted(io, parsed, filters, sieve);
    // Internal gate-only contract: load synchronously and fail closed unless
    // the real elision oracle is admitted. This makes freshness_fs.sh prove the
    // accelerated path instead of accidentally passing via an async/full-read
    // fallback. It is intentionally not a CLI flag.
    const require_elision = args.envSpan("GIST_TEST_REQUIRE_ELISION") != null;
    if (require_elision and !want_elision) die("gist: test-required index elision was not eligible\n", .{});
    // The elide oracle loads on its own thread while the walk runs, keeping
    // mmap validation, sparse posting decode, and path-table setup off the
    // serial query prefix.
    var lazy: LazyElide = .{};
    if (want_elision) {
        if (require_elision) {
            lazy.val = buildElide(gpa, io, o, filters, sieve);
            if (lazy.val == null) die("gist: test-required index elision was declined\n", .{});
            if (!testHasElidableFile(io, &lazy.val.?)) die("gist: test-required index elision found no elidable live file\n", .{});
            lazy.ready.store(true, .release);
        } else {
            // Detached: if every worker out-walks the load and gives up on
            // elision, nobody waits on this thread — `run` exits the process and
            // the OS reclaims it. (`lazy`/`o`/`filters` outlive it either way:
            // this frame never returns.)
            if (std.Thread.spawn(.{}, LazyElide.loaderMain, .{ &lazy, gpa, io, o, filters, sieve })) |t| t.detach() else |_| {
                lazy.val = buildElide(gpa, io, o, filters, sieve);
                lazy.ready.store(true, .release);
            }
        }
    } else lazy.ready.store(true, .release);

    // Phantom tree.map. The snapshot carries MEMBERSHIP only (names + kinds),
    // so every admission axis stays sound by construction: ignore/hidden/glob
    // verdicts are decided live per entry, admission-widening flags (`-uu`,
    // `--hidden`, `-g` whitelists, `--ignore-file`) at worst re-admit a
    // subtree the build never descended — which walks live via `not_walked` —
    // and explicit roots resolve to their snapshot record by name (a root the
    // snapshot can't place just walks live). `GIST_NO_PHANTOM` (internal,
    // undocumented — the `GIST_NO_PARALLEL` idiom) forces the live walk for
    // parity gates.
    var snap_view: ?treemap.View = if (args.envSpan("GIST_NO_PHANTOM") == null) treemap.load(io) else null;

    // Content shard. Loaded for a body-reading walk broad enough to amortize the
    // one-time map + doc-table build (`broadIndexedRoots`, same rung the elide
    // loader uses): every unchanged corpus file the walk would open is served
    // from the mapping instead — the across-the-board full-scan win. Skipped for
    // `--files` (no bytes read) and transform runs (`-z`/`-E` need live bytes,
    // and the shard never holds compressed inputs anyway). `GIST_NO_SHARD`
    // (internal, undocumented — the `GIST_NO_PHANTOM` idiom) forces live reads
    // for the parity gate. Membership + freshness only, so it is fail-open.
    const want_shard = args.envSpan("GIST_NO_SHARD") == null and !o.no_index and !o.files_list and !icfg.active() and broadIndexedRoots(parsed.roots);
    var shard_view: ?shard_mod.View = if (want_shard) shard_mod.load(gpa, io) else null;

    var ig = ignore.Ignore.init(gpa, io, ignore.Options.from(o), parsed.roots);
    const compiled = ignore.Compiled.build(gpa, &ig);
    var q: Queue = .{ .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);
    var sink: Sink = .{ .q = &q, .io = io, .heading = heading, .join_groups = o.wantsContext() and !o.files_only and !o.files_without and !o.count_only and !o.count_matches and !heading };
    // Pure-literal alternation gate/equivalence (see `Cfg.file_alts`): only when
    // no single required literal already gates, and never for modes that must
    // read every body (`-v` needs zero-hit files; passthru emits them).
    // `--stats` keeps the gate: a miss still tallies via `gateMiss` (zero hits +
    // full bytes) without a regex run — faster than serial's ungated collect.
    const lits: []const []const u8 = if (re) |m| m.lits() else &.{};
    const file_alts: []const []const u8 = if (lits.len > 0 and file_needle == null and !o.invert and !o.passthru) lits else &.{};
    // Equivalence proof: the whole-file gate that will run (`file_needle`, a
    // single pure literal, or `file_alts`, a pure alternation) IS the pattern.
    // A caseless gate carries its own producer-proven equivalence (`.equiv`,
    // mined from the raw unfolded twin in `run.zig::caselessGate`).
    const lits_equiv = (file_needle != null and (file_needle.?.equiv or (lits.len == 1 and std.mem.eql(u8, lits[0], file_needle.?.bytes)))) or file_alts.len > 0;
    // Under `-U` the fused boolean is `bufMatch`; admit it only when that
    // boolean provably equals the whole-buffer emit model's `-l` /
    // `--files-without-match` verdict (`bufBoolExact` — a nullable `\z`-style
    // pattern falls to `Emitter.buffer`).
    const fast_l = (o.files_only or o.files_without) and !o.invert and !o.word and !o.crlf and !o.null_data and o.max_per_file == 0 and !o.only_matching and
        !o.count_only and !o.count_matches and !o.passthru and !o.vimgrep and !o.stop_on_nonmatch and o.replace == null and !o.stats and
        (!o.multiline or (re != null and re.?.bufBoolExact()));
    var gate_len: usize = if (file_needle) |n| n.bytes.len else 0;
    for (file_alts) |n| gate_len = @max(gate_len, n.len);
    const cfg: Cfg = .{
        .o = o,
        .re = re,
        .ig = &ig,
        .compiled = if (compiled) |*c| c else null,
        .lazy = if (want_elision) &lazy else null,
        .file_needle = file_needle,
        .file_alts = file_alts,
        .lits_equiv = lits_equiv,
        .gate_len = gate_len,
        .line_needle = line_needle,
        .fast_l = fast_l,
        .use_color = use_color,
        // `.auto` shows names too: the walk is recursive by construction.
        .show_name = o.filename != .never,
        .heading = heading,
        .join_groups = sink.join_groups,
        .binary_detect = !o.text and !o.null_data,
        .files_mode = o.files_list,
        .ingest = if (icfg.active()) icfg else null,
        .snap = if (snap_view) |*v| v else null,
        .shard = if (shard_view) |*v| v else null,
        .sink = &sink,
        .collect_sorted = o.sort_key != .none,
    };
    const roots: []const []const u8 = if (parsed.roots.len > 0) parsed.roots else &.{"."};
    {
        var seed: std.ArrayList(DirTask) = .empty;
        defer seed.deinit(gpa);
        for (roots) |r| {
            const prefix = if (std.mem.eql(u8, r, ".") and parsed.roots.len == 0) "" else std.mem.trimEnd(u8, r, "/");
            const scope_prefix = paths_mod.cwdRelative(gpa, io, prefix);
            // Each root resolves to its snapshot record by name (dir 0 = the
            // CWD root); an unplaceable root simply walks live.
            const six = if (snap_view) |*v| treemap.resolve(v, scope_prefix) orelse treemap.not_walked else treemap.not_walked;
            seed.append(gpa, .{ .disk = r, .rel = prefix, .scope = scope_prefix, .depth = 0, .root_depth = rootDepth(prefix), .chain = null, .snap_ix = six }) catch oom();
        }
        q.push(seed.items);
    }

    // Worker topology is OS-aware (see `defaultWorkerCount`): macOS keeps the
    // measured six-worker ceiling (kernel-serialized walk) and halves it for
    // traversal-only / narrow / selective runs; every other OS scales to all
    // logical CPUs like ripgrep. `GIST_WORKERS` remains absolute.
    const ncpu = std.Thread.getCpuCount() catch 6;
    const narrow_scope = parsed.roots.len > 0 and !broadIndexedRoots(parsed.roots);
    // A transforming run (-z/--pre/-E) does CPU-bound per-file work — inflate
    // (gzip/xz/zstd) or transcode — that scales to every core, exactly like the
    // serial engine's parallel read-shards (`run.zig` `readCandidates` fans out
    // to `min(candidates, ncpu)`). The 6-worker ceiling is tuned for the
    // syscall/namei-bound plaintext walk, where more threads only add fd + namei
    // contention; it throttles decode-heavy codecs (xz/zstd) below the serial
    // path, so a transforming pipeline lifts the cap to all logical CPUs.
    var nworkers = if (icfg.active()) @max(1, ncpu) else defaultWorkerCount(ncpu, o.files_list or want_elision or narrow_scope);
    // -j/--threads caps the pool explicitly (rg's `--threads`); 0 keeps gist's
    // adaptive topology. `GIST_WORKERS` still overrides everything (parity gates).
    if (o.threads != 0) nworkers = @max(1, o.threads);
    if (args.envSpan("GIST_WORKERS")) |s| if (std.fmt.parseInt(usize, s, 10)) |n| {
        nworkers = @max(1, n);
    } else |_| {};
    const workers = gpa.alloc(Worker, nworkers) catch oom();
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .q = &q, .io = io, .gpa = gpa, .cfg = &cfg, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| {
        w.arena.deinit();
        w.out.deinit(gpa);
        w.recs.deinit(gpa);
    };

    const threads = gpa.alloc(std.Thread, nworkers) catch oom();
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{w}) catch break;
        spawned += 1;
    }
    workerMain(&workers[0]); // the main thread is a worker too
    for (threads[0..spawned]) |t| t.join();

    // `--sort`/`--sortr path`: the fused walk held every worker's rendered output
    // in its arena keyed by path (`deliver`/`bufferPath`) instead of racing it to
    // stdout. Order the whole result once now and replay it through the SAME
    // `Sink` — a single global sort over a parallel walk+read+match, so separators
    // and the matched-files exit code stay byte-identical to the serial oracle,
    // just sorted. Falls through to the shared exit tail below.
    if (cfg.collect_sorted) emitSorted(gpa, &sink, workers, o);

    // Every byte is already on stdout — each worker streamed its fragments
    // through `sink.emit` the instant it rendered them (see `Sink`). Nothing
    // left to stitch or write; a walk error (unreadable dir) trumps match/
    // no-match (rg parity — see `reportWalkError`), otherwise `sink.matched_files`
    // alone decides the exit code.
    // Announce a soft/hard output-budget cut (the streaming `Sink` aborted the
    // walk when `writeStdout` refused past the ceiling — corpus.zig). One-time,
    // stderr-only, a no-op when nothing was truncated; runs before either exit.
    corpus_mod.finishOutput();
    // A `-P` worker that tripped a resource limit on catastrophic input latched
    // the process-global fault — mirror ripgrep's exit 2 over the accumulated
    // (already-streamed) output, via the serial engine's own `pcreFaultExit`
    // renderer so the two engines' fault text can't drift.
    if (re) |m| serial.pcreFaultExit(m);
    // The no-match hint seam (mirrors the serial engine's): a clean exit-1
    // search run — not `--files`, not `--quiet`, no walk error — gets shape-
    // derived stderr guidance. The streamed walk has no cheap total-files
    // count, so the summary omits it rather than report a partial number.
    // rg's implicit-path heuristic (search modes only, never `--files`): a
    // GUESSED root whose walk admitted zero files means a filter excluded
    // everything — stderr note + exit 2, never a silent exit-1 "no matches".
    const nothing_searched = re != null and parsed.roots.len == 0 and !q.files_seen.load(.acquire);
    if (nothing_searched) grepfile.printNothingSearched();
    // `--json`: every worker streamed its per-file `begin`/records/`end` blocks;
    // sum their per-worker tallies and write the single trailing `summary` record
    // (rg's stream always ends with it, even on no match) as the last stdout line.
    // The stream's file order is worker-discovery order — order-insensitive, the
    // same contract as the plain walk's fragments and the parity harness's
    // `sort -u` set compare. No `noMatches` stderr hint (rg's serial `--json`
    // path emits none either — it would only pollute a machine-consumed stream).
    if (o.json) {
        var st: json.Stats = .{};
        for (workers) |*wk| st.add(wk.jstats);
        var sbuf: std.ArrayList(u8) = .empty;
        json.summary(gpa, &sbuf, st);
        _ = corpus_mod.writeStdout(sbuf.items);
        std.process.exit(if (q.walk_error.load(.acquire) or nothing_searched) 2 else if (st.with_match > 0) 0 else 1);
    }
    // `--stats`: every worker streamed its match fragments; fold their per-
    // worker tallies, stamp `files_with_match` / `bytes_printed` from the sink
    // (the serial engine does the same post-pass), and append ripgrep's trailing
    // stats block. Quiet is declined by `eligible`, so the match stream always
    // ran and `bytes_printed` is the live write count.
    if (o.stats) {
        var st: grepfile.Stats = .{};
        for (workers) |*wk| st.add(wk.stats);
        st.files_with_match = sink.matched_files;
        st.bytes_printed = sink.bytes_printed;
        var sbuf: std.ArrayList(u8) = .empty;
        grepfile.emitStats(gpa, &sbuf, st);
        _ = corpus_mod.writeStdout(sbuf.items);
        std.process.exit(if (q.walk_error.load(.acquire) or nothing_searched) 2 else if (sink.matched_files > 0) 0 else 1);
    }
    // `--files-without-match`: `matched_files` counts files that LACKED the
    // pattern (each `bufferPath` → `emitFilesChunk`), so exit 0 iff at least
    // one such file was found — ripgrep's success predicate for this mode.
    if (re != null and !o.quiet and !o.files_list and !o.files_without and sink.matched_files == 0 and !nothing_searched and !q.walk_error.load(.acquire))
        hints.noMatches(hints.shape(parsed.patterns, o, parsed.roots, parsed.roots.len > 0), null);
    std.process.exit(if (q.walk_error.load(.acquire) or nothing_searched) 2 else if (sink.matched_files > 0) 0 else 1);
}

// ─────────────────────── callable file-set walk ───────────────────────

/// One admitted file plus its walk-time freshness clocks (from the same
/// `getattrlistbulk` listing that enumerated it — never a separate stat). Null
/// clocks mean the listing couldn't supply them (a `getattrlistbulk`-unsupported
/// fallback); the caller then re-stats that one path.
pub const FileEntry = struct { path: []const u8, mtime_ns: ?i128, ctime_ns: ?i128 };

/// The admitted rg-default file set under `roots`, plus whether the walk hit an
/// unreadable directory. The `-t`/`-g` un-hide/un-ignore extras a serial
/// `defaultFileSetExtras` walk gathers are deliberately NOT collected: a
/// files-only parallel walk drops every rejected entry silently. The one caller
/// (the resident daemon's `reconcileFull`) defers them — it marks its extras
/// stale so the next `-t`/`-g` query refreshes on demand, the identical contract
/// the scoped reconcile path already uses.
pub const FileSet = struct { entries: []const FileEntry, walk_error: bool };

/// The fused work-stealing walk as a CALLABLE — everything `run` does up to the
/// fan-out/join, WITHOUT the per-file search, the streaming sink, or the
/// `noreturn` exit tail. It runs the identical ignore-certified directory walk
/// `run` runs in `--files` mode (same `Ignore`/`Cfg`/`Worker`/`Queue`/
/// `processDir`/`handleEntry`, so admission is parity-identical to the serial
/// `defaultFileSet` by construction), but COLLECTS each admitted path into `a`
/// and RETURNS the set instead of racing it to stdout and exiting. Membership is
/// live ground truth: the phantom snapshot and content shard are never consulted
/// (a file created since the last index build must still appear), which is
/// exactly what the daemon's freshness reconcile needs. `roots` empty ⇒ the CWD
/// walked with rootless corpus keys. Caller owns `a`; every internal scratch
/// allocation is released before return.
pub fn collectFileSet(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, a: std.mem.Allocator) FileSet {
    // `files_list` gates only `files_mode`/worker topology; `ignore.Options.from`
    // reads none of it, so the admission layer is byte-identical to serial
    // `defaultFileSet`'s default `Opts{}`.
    const o: Opts = .{ .files_list = true };
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var ig = ignore.Ignore.init(sa, io, ignore.Options.from(o), roots);
    const compiled = ignore.Compiled.build(sa, &ig);
    var q: Queue = .{ .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);
    // Never streamed to: files+`collect_sorted` route every path into the
    // worker's `recs` (see `bufferPath`), so the sink exists only to satisfy
    // `Cfg`. Its `heading`/`join_groups` are inert in files mode.
    var sink: Sink = .{ .q = &q, .io = io, .heading = false, .join_groups = false };
    const cfg: Cfg = .{
        .o = o,
        .re = null,
        .ig = &ig,
        .compiled = if (compiled) |*c| c else null,
        .lazy = null,
        .file_needle = null,
        .file_alts = &.{},
        .lits_equiv = false,
        .gate_len = 0,
        .line_needle = null,
        .fast_l = false,
        .use_color = false,
        .show_name = true,
        .heading = false,
        .join_groups = false,
        .binary_detect = false,
        .files_mode = true,
        .ingest = null,
        .snap = null, // live ground truth — no phantom membership
        .shard = null, // no bytes read in files mode
        .sink = &sink,
        .collect_sorted = true, // route `bufferPath` into each worker's `recs`
        .freshness_meta = true, // clock-bearing listing; carry mtime/ctime in `recs`
    };
    {
        const eff_roots: []const []const u8 = if (roots.len > 0) roots else &.{"."};
        var seed: std.ArrayList(DirTask) = .empty;
        defer seed.deinit(gpa);
        for (eff_roots) |r| {
            const prefix = if (std.mem.eql(u8, r, ".") and roots.len == 0) "" else std.mem.trimEnd(u8, r, "/");
            seed.append(gpa, .{
                .disk = r,
                .rel = prefix,
                .scope = paths_mod.cwdRelative(sa, io, prefix),
                .depth = 0,
                .root_depth = rootDepth(prefix),
                .chain = null,
                .snap_ix = treemap.not_walked,
            }) catch oom();
        }
        q.push(seed.items);
    }
    const ncpu = std.Thread.getCpuCount() catch 6;
    var nworkers = defaultWorkerCount(ncpu, true);
    if (args.envSpan("GIST_WORKERS")) |s| if (std.fmt.parseInt(usize, s, 10)) |n| {
        nworkers = @max(1, n);
    } else |_| {};
    const workers = gpa.alloc(Worker, nworkers) catch oom();
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .q = &q, .io = io, .gpa = gpa, .cfg = &cfg, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| {
        w.arena.deinit();
        w.out.deinit(gpa);
        w.recs.deinit(gpa);
    };
    const threads = gpa.alloc(std.Thread, nworkers) catch oom();
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{w}) catch break;
        spawned += 1;
    }
    workerMain(&workers[0]); // the main thread is a worker too
    for (threads[0..spawned]) |t| t.join();

    // Each worker held its admitted paths in its own arena (torn down by the
    // defer above); dupe them into the caller's allocator before that fires.
    var total: usize = 0;
    for (workers) |*w| total += w.recs.items.len;
    const entries = a.alloc(FileEntry, total) catch oom();
    var k: usize = 0;
    for (workers) |*w| for (w.recs.items) |r| {
        entries[k] = .{ .path = a.dupe(u8, r.path) catch oom(), .mtime_ns = r.mtime_ns, .ctime_ns = r.ctime_ns };
        k += 1;
    };
    return .{ .entries = entries, .walk_error = q.walk_error.load(.acquire) };
}

/// Worker pool size for a plaintext walk. macOS serializes the walk in the
/// kernel — the `vm_map` fault lock on the mmap'd content shard and syspolicyd/
/// vnode locks on open+namei — so past a small pool more threads only add
/// contention (measured flat 6→16 on the shard path, and slower on the open
/// path); the tuned six-worker ceiling stays, halved further for traversal-only
/// / narrow / index-selective runs that do less work per file. Every other OS
/// has a scalable fault + open path — ripgrep saturates all logical CPUs there —
/// so the ceiling would just idle cores: scale to `ncpu`. `GIST_WORKERS` and
/// `-j` still override.
fn defaultWorkerCount(ncpu_raw: usize, selective: bool) usize {
    const ncpu = @max(1, ncpu_raw);
    if (builtin.os.tag != .macos) return ncpu;
    const full = @min(ncpu, 6);
    if (!selective or ncpu <= 4) return full;
    return @min(full, @max(4, (ncpu + 1) / 2));
}

test "IndexedPaths resolves exactly and reads unknown paths" {
    const t = std.testing;
    const paths = [_][]const u8{ "libs/a.zig", "services/b.go", "clients/c.ts" };
    var indexed = try IndexedPaths.init(t.allocator, &paths);
    defer indexed.deinit();

    try t.expectEqual(0, indexed.get(&paths, "libs/a.zig"));
    try t.expectEqual(2, indexed.get(&paths, "clients/c.ts"));
    try t.expectEqual(null, indexed.get(&paths, "libs/new.zig"));

    var buf: [32]u8 = undefined;
    var collision_checked = false;
    for (0..1024) |i| {
        const unknown = try std.fmt.bufPrint(&buf, "new/path-{d}", .{i});
        if (indexed.slot(unknown) != indexed.slot(paths[0])) continue;
        try t.expectEqual(null, indexed.get(&paths, unknown));
        collision_checked = true;
        break;
    }
    try t.expect(collision_checked);
}

test "index table policy requires a material saving" {
    const t = std.testing;
    try t.expect(!indexSavingsWorthTable(1023, 0));
    try t.expect(indexSavingsWorthTable(16_000, 12_000));
    try t.expect(!indexSavingsWorthTable(16_000, 12_001));
    try t.expect(!indexSavingsWorthTable(16_000, 16_000));
}

test "index loading stays off narrow explicit roots" {
    const t = std.testing;
    try t.expect(broadIndexedRoots(&.{ "libs", "services" }));
    try t.expect(broadIndexedRoots(&.{"."}));
    try t.expect(!broadIndexedRoots(&.{"pkg/kernels/irregex"}));
    try t.expect(!broadIndexedRoots(&.{"/tmp/corpus"}));
}

test "sorted-emit order matches the serial --sort path oracle" {
    const t = std.testing;
    const mk = struct {
        fn r(p: []const u8) SortedRec {
            return .{ .path = p, .kind = .text_hit, .buf = "" };
        }
    }.r;
    // Ascending rides `serial.pathLess` (rg's `Path::cmp`): `/` ranks below every
    // other byte, so a directory sorts before a sibling file sharing its stem —
    // a raw byte compare (`.`=0x2e < `/`=0x2f) would flip these.
    try t.expect(recLess(false, mk("warroom/service.go"), mk("warroom.go")));
    try t.expect(!recLess(false, mk("warroom.go"), mk("warroom/service.go")));
    try t.expect(recLess(false, mk("a.zig"), mk("b.zig")));
    // `--sortr` is the exact mirror (operands swapped), matching rg's `.reverse()`.
    try t.expect(recLess(true, mk("b.zig"), mk("a.zig")));
    try t.expect(recLess(true, mk("warroom.go"), mk("warroom/service.go")));
    // Equal paths compare false either way — a stable, no-adjacent-reorder sort.
    try t.expect(!recLess(false, mk("x"), mk("x")));
    try t.expect(!recLess(true, mk("x"), mk("x")));
}

test "worker topology keeps scans wide and selective walks lean" {
    const t = std.testing;
    if (builtin.os.tag == .macos) {
        // macOS keeps the kernel-serialized ceiling, halved for selective walks.
        try t.expectEqual(4, defaultWorkerCount(8, true));
        try t.expectEqual(6, defaultWorkerCount(8, false));
        try t.expectEqual(4, defaultWorkerCount(4, true));
        try t.expectEqual(6, defaultWorkerCount(12, true));
    } else {
        // Every other OS scales to all logical CPUs (ripgrep's model).
        try t.expectEqual(8, defaultWorkerCount(8, true));
        try t.expectEqual(8, defaultWorkerCount(8, false));
        try t.expectEqual(12, defaultWorkerCount(12, true));
    }
}
