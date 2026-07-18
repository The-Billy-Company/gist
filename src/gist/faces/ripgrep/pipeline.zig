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
//! concurrent workers' output never interleaves) — never buffered and
//! reordered after the fact. This is also what lets gist cancel early: a
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
//! `-F`/`-x`, `-t`/`-g` scoping, `--files` — run here. The long tail that
//! carries cross-file or stateful semantics (`-L` symlink cycles, `--json`,
//! `--stats`, `-q`, `--files-without-match`, `-r` captures, `--max-filesize`,
//! explicit FILE args, stdin) stays on the proven serial engine.

const std = @import("std");
const corpus_mod = @import("../../../corpus/corpus.zig");
const args = @import("args.zig");
const output = @import("output.zig");
const ignore = @import("ignore.zig");
const grepfile = @import("grepfile.zig");
const ingest = @import("ingest.zig");
const simd = @import("../../kernel/scan/simd.zig");
const verify = @import("../../kernel/scan/verify.zig");
const persist = @import("../../kernel/index/persist.zig");
const fresh = @import("../../kernel/index/fresh.zig");
const bulkstat = @import("../../../corpus/bulkstat.zig");
const paths_mod = @import("paths.zig");
const stripDot = paths_mod.stripDot;
const replaceSep = paths_mod.replaceSep;
const joinPath = paths_mod.join;
const rootDepth = paths_mod.rootDepth;
const Opts = args.Opts;
const Emitter = output.Emitter;
const die = args.die;
const oom = args.oom;
const Regex = @import("../../kernel/regex/core.zig").Regex;
const Matcher = @import("../../kernel/regex/matcher.zig").Matcher;
const pcre2 = @import("../../kernel/regex/pcre2.zig");
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
    if (o.follow or o.json or o.quiet or o.stats or o.files_without or
        o.replace != null or o.max_filesize != 0 or o.multiline) return false;
    // A globally ordered result (`--sort`/`--sortr`) and a device-bounded walk
    // (`--one-file-system`) both need cross-file state the streaming sink can't
    // give, so they run on the serial engine — which still reads in parallel,
    // then orders once, beating ripgrep's fully single-threaded sort walk.
    if (o.sort_key != .none or o.one_file_system) return false;
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

/// One directory's own ignore rules (.gitignore + .ignore/.rgignore, in the
/// serial engine's load order), chained to the parent directory's node.
/// Immutable after construction; `rules` and the chain links live in the
/// building worker's arena, which outlives the whole run.
const IgNode = struct {
    parent: ?*const IgNode,
    rules: []const ignore.Rule,
};

/// Fold the chain's rules into `verdict`, parent-first (shallow→deep, so the
/// deepest matching rule wins — git precedence, same as `Ignore.decideAt`).
fn applyChain(node: ?*const IgNode, a: std.mem.Allocator, ci: bool, root_depth: usize, reanchor_root: bool, rel: []const u8, is_dir: bool, verdict: *?bool) void {
    const n = node orelse return;
    applyChain(n.parent, a, ci, root_depth, reanchor_root, rel, is_dir, verdict);
    for (n.rules) |r| if (ignore.ruleMatch(a, ci, root_depth, reanchor_root, r, rel, is_dir)) {
        verdict.* = !r.negated;
    };
}

/// The full skip decision for one walked entry: frozen-base verdict —
/// `Compiled.matchRank` (hash-probing fast tier) when available, else
/// `decideAt` — overridden by the per-directory chain, then the shared
/// `.git`/hidden folding (`skipFromVerdict`). Threads the same ripgrep
/// whitelist-override pair (`Filter.whitelists`/`whitelistsHidden`) the serial
/// engine's `walkDirLinked` computes per entry — see `Ignore.shouldSkip`'s doc
/// comment for the asymmetry (`-g`/`--iglob` bypasses `.git`+ignore, a `-t`
/// type match only un-hides) this engine must reproduce byte-for-byte.
fn shouldSkip(cfg: *const Cfg, chain: ?*const IgNode, a: std.mem.Allocator, task: DirTask, rel: []const u8, is_dir: bool, basename: []const u8) bool {
    const ig = cfg.ig;
    var v: ?bool = null;
    if (cfg.compiled) |c| {
        if (c.matchRank(stripDot(rel), is_dir, task.root_depth, ig.reanchor_root_rules)) |r| v = !c.rules[r].negated;
    } else {
        v = ig.decideAt(rel, is_dir, task.root_depth);
    }
    applyChain(chain, a, ig.o.ignore_case_insensitive, task.root_depth, ig.reanchor_root_rules, rel, is_dir, &v);
    const wl_ig = cfg.o.filter.whitelists(a, rel);
    const wl_hid = cfg.o.filter.whitelistsHidden(a, rel);
    return ig.skipFromVerdict(v, is_dir, basename, wl_ig, wl_hid);
}

/// Read one ignore file (raw POSIX, worker-thread safe) into `a`. Null when
/// absent/unreadable — same silent degrade as `Ignore.readFile`.
fn readIgnoreFile(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    var tmp: [16 * 1024]u8 = undefined;
    while (buf.items.len < (1 << 20)) {
        const r = std.posix.read(fd, &tmp) catch break;
        if (r == 0) break;
        buf.appendSlice(a, tmp[0..r]) catch return null;
    }
    return buf.toOwnedSlice(a) catch null;
}

fn appendRules(a: std.mem.Allocator, list: *std.ArrayList(ignore.Rule), path: []const u8, base: []const u8) void {
    const buf = readIgnoreFile(a, path) orelse return;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (ignore.parseRuleLine(line, base, "")) |r| list.append(a, r) catch oom();
    }
}

/// Which ignore files a directory's LISTING says are present — the walk
/// already read every sibling name, so `loadNode` only `openat`s files that
/// exist instead of blind-probing all three in every directory (the biggest
/// syscall sink in the whole walk: ~3 failed opens × every dir).
const IgPresent = struct { gitignore: bool = false, dotignore: bool = false, rgignore: bool = false };

/// Build the `IgNode` for a directory the walk just entered (its `.gitignore`
/// then `.ignore`/`.rgignore`, mirroring `Ignore.loadDir`'s order so
/// last-match-wins precedence is identical). Null when the directory
/// contributes no rules — the chain link is skipped, not empty.
fn loadNode(ig: *const ignore.Ignore, a: std.mem.Allocator, parent: ?*const IgNode, disk: []const u8, rel: []const u8, present: IgPresent) ?*const IgNode {
    var rules: std.ArrayList(ignore.Rule) = .empty;
    if (ig.use_git and present.gitignore) appendRules(a, &rules, joinPath(a, disk, ".gitignore"), rel);
    if (ig.use_dot) {
        if (present.dotignore) appendRules(a, &rules, joinPath(a, disk, ".ignore"), rel);
        if (present.rgignore) appendRules(a, &rules, joinPath(a, disk, ".rgignore"), rel);
    }
    if (rules.items.len == 0) return parent;
    const node = a.create(IgNode) catch oom();
    node.* = .{ .parent = parent, .rules = rules.toOwnedSlice(a) catch oom() };
    return node;
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
        const capacity = std.math.ceilPowerOfTwo(usize, @max(@as(usize, 8), paths.len * 2)) catch return error.OutOfMemory;
        const slots = try gpa.alloc(u32, capacity);
        @memset(slots, empty);
        const table = IndexedPaths{ .slots = slots, .mask = capacity - 1, .gpa = gpa };
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
/// trigram candidate, AND both timestamps prove it predates the anchor.
/// Equality or unavailable metadata forces a live read.
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

    fn loaderMain(le: *LazyElide, gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8) void {
        le.val = buildElide(gpa, io, o, filters);
        le.ready.store(true, .release);
    }
};

/// Explicit nested roots usually finish their scoped walk before a fresh index
/// process can load. Rootless searches, `.`, and direct indexed corpus roots are
/// broad enough to plausibly amortize it; narrower scopes stay on the live path.
fn broadIndexedRoots(roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    for (roots) |raw| {
        var root = raw;
        while (std.mem.startsWith(u8, root, "./")) root = root[2..];
        root = std.mem.trimEnd(u8, root, "/");
        if (root.len == 0 or std.mem.eql(u8, root, ".")) return true;
        for (corpus_mod.default_roots) |indexed| {
            if (std.mem.eql(u8, root, indexed)) return true;
        }
    }
    return false;
}

/// Cheap pre-checks before spawning the loader. Short literals cannot query the
/// trigram index, and narrow explicit roots are cheaper to walk directly.
pub fn indexElisionWanted(parsed: args.Parsed, filters: []const []const u8) bool {
    const o = parsed.opts;
    if (o.files_list or o.no_index or filters.len == 0) return false;
    for (filters) |f| if (f.len < 3) return false;
    return broadIndexedRoots(parsed.roots);
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

fn buildElide(gpa: std.mem.Allocator, io: std.Io, o: Opts, filters: []const []const u8) ?Elide {
    if (o.no_index or filters.len == 0) return null;
    for (filters) |f| if (f.len < 3) return null;
    return assembleElide(gpa, io, filters) catch null;
}

/// Fallible half of `buildElide`: every early exit (a missing anchor, an
/// unloadable/unworthwhile index, an OOM) is an error, so `errdefer` sheds the
/// half-built state instead of hand-threading `deinit` down each return path.
fn assembleElide(gpa: std.mem.Allocator, io: std.Io, filters: []const []const u8) !Elide {
    const anchor = fresh.readAnchor(gpa, io) orelse return error.NoAnchor;
    var p = (persist.loadQuiet(gpa, io) catch return error.NoIndex) orelse return error.NoIndex;
    errdefer p.deinit();
    const cand = try p.idx.queryAny(gpa, filters);
    defer gpa.free(cand);
    if (!indexSavingsWorthTable(p.paths.items.len, cand.len)) return error.NotWorthwhile;
    var candidates = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
    errdefer candidates.deinit();
    for (cand) |d| candidates.set(d);
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
/// joined, may carry a root's `./`); `disk` is CWD-openable; `depth` counts
/// components under the walk root (root = 0); `root_depth` is the explicit
/// positional root's own component depth (see `Ignore.scopeToRoot`).
const DirTask = struct {
    disk: []const u8,
    rel: []const u8,
    depth: usize,
    root_depth: usize,
    chain: ?*const IgNode,
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
const FragKind = enum { text_hit, text_plain, bin_hit };

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
    files_mode: bool,
    null_sep: bool,
    first: bool = true, // guarded by `mu`
    matched_files: usize = 0, // guarded by `mu`

    fn emit(self: *Sink, kind: FragKind, buf: []const u8) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (self.q.aborted.load(.monotonic)) return; // pipe already gone — nothing left to do
        var ok = true;
        if (self.files_mode) {
            self.matched_files += 1;
            ok = corpus_mod.writeStdout(buf) and
                corpus_mod.writeStdout(if (self.null_sep) "\x00" else "\n");
        } else {
            switch (kind) {
                .text_hit => {
                    if (self.heading and !self.first) ok = corpus_mod.writeStdout("\n");
                    if (ok and self.join_groups and !self.first and buf.len > 0) ok = corpus_mod.writeStdout("--\n");
                    self.first = false;
                    self.matched_files += 1;
                },
                .bin_hit => self.matched_files += 1,
                .text_plain => {},
            }
            if (ok) ok = corpus_mod.writeStdout(buf);
        }
        if (!ok) self.q.abort();
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
    file_needle: ?[]const u8, // whole-file SIMD gate; null for passthru/stats-like modes
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
    line_needle: ?[]const u8, // required literal before each regex engine run
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
    sink: *Sink,
};

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
    // Reusable boolean-match scratch (`Matcher.Sim` is per-thread by design):
    // lazily built once on first use, then reused for every file this worker
    // searches — the Pike generation counter self-invalidates between calls,
    // so no reset is needed and no per-file alloc/free is paid.
    sim: ?Matcher.Sim = null,
};

/// The worker's lazily-built reusable match scratch (null only on OOM, where
/// the caller degrades to "no match proven" — never an invented match).
fn workerSim(w: *Worker) ?*Matcher.Sim {
    if (w.sim == null) w.sim = Matcher.Sim.init(w.arena.allocator(), w.cfg.re.?) catch return null;
    return &w.sim.?;
}

/// A listed directory entry, normalized across the two listing backends.
const Entry = struct {
    name: []const u8,
    is_dir: bool,
    is_file: bool,
    mtime_ns: ?i128,
    ctime_ns: ?i128,
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
    if (!w.q.aborted.load(.monotonic)) flushPending(w, a, scratch, true);
}

/// Elide-or-search every deferred file. In-walk (`final=false`): only runs
/// once the loader has finished, retried after every directory. End-of-walk
/// (`final=true`): NEVER blocks on the loader — on a warm tree, re-reading
/// the backlog beats idling for the oracle (~20ms load; waiting measured
/// 1.5x slower on `libs`-sized scopes). Walks that outlive the load still
/// get full elision via the in-walk flushes.
fn flushPending(w: *Worker, a: std.mem.Allocator, scratch: []u8, final: bool) void {
    if (w.pending.items.len == 0) return;
    const lz = w.cfg.lazy.?; // pending is only ever fed when a loader exists
    const ready = lz.ready.load(.acquire);
    if (!ready and !final) return;
    const o = w.cfg.o;
    for (w.pending.items) |d| {
        if (ready) if (lz.val) |*el| if (el.skip(stripDot(d.rel), d.mtime_ns, d.ctime_ns)) continue;
        const dpath = if (o.path_sep) |sep| replaceSep(a, d.rel, sep) else d.rel;
        searchFile(w, a, scratch, std.posix.AT.FDCWD, d.disk, dpath, d.disk);
    }
    w.pending.clearRetainingCapacity();
}

/// Display/ignore join: an explicit `.` root KEEPS its `./` prefix on every
/// emitted path (serial `relPath` / rg parity); only the implicit whole-CWD
/// walk ("" prefix) emits bare paths.
fn joinRel(a: std.mem.Allocator, prefix: []const u8, name: []const u8) []const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name }) catch oom();
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
    const o = cfg.o;

    // Raw `openat` (worker-thread safe, no std.Io indirection) — the fd feeds
    // `getattrlistbulk` directly and is wrapped in a `Dir` only for the
    // portable fallback. An unreadable/EACCES directory is a walk error, not a
    // silent prune (rg parity — see `reportWalkError`).
    const fd = std.posix.openat(std.posix.AT.FDCWD, task.disk, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0) catch |e| {
        reportWalkError(w.q, task.rel, e);
        return;
    };
    var dir = Dir{ .handle = fd };
    var closed = false;
    defer if (!closed) {
        _ = std.posix.system.close(dir.handle);
    };

    // List the whole directory FIRST — the names tell us which ignore files
    // exist here, so the chain build below never blind-probes the disk.
    var entries: std.ArrayList(Entry) = .empty;
    var present = IgPresent{};
    var bulk_ok = false;
    if (bulkstat.supported) {
        // With index elision live, each entry's mtime+ctime ride the bulk
        // listing for free; without it, names+types via getdirentries is cheaper.
        const listing = if (needsElisionMetadata(cfg)) bulkstat.listOneLevel(a, dir.handle) else bulkstat.listNamesOnly(a, dir.handle);
        if (listing) |listed| {
            for (listed) |e| {
                noteIgnoreFile(&present, e.name, e.is_file);
                entries.append(a, .{
                    .name = e.name,
                    .is_dir = e.is_dir,
                    .is_file = e.is_file,
                    .mtime_ns = e.mtime_ns,
                    .ctime_ns = e.ctime_ns,
                }) catch oom();
            }
            bulk_ok = true;
        } else |_| {}
    }
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
            dir = Dir{ .handle = fd2 };
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
            if (e.kind == .file and needsElisionMetadata(cfg)) {
                if (dir.statFile(w.io, e.name, .{})) |st| {
                    mtime = st.mtime.nanoseconds;
                    ctime = st.ctime.nanoseconds;
                } else |_| {}
            }
            // The iterator's name buffer is reused on the next `next()` —
            // fragments/tasks hold rel paths built from it, so own a copy.
            const name = a.dupe(u8, e.name) catch oom();
            noteIgnoreFile(&present, name, e.kind == .file);
            entries.append(a, .{
                .name = name,
                .is_dir = e.kind == .directory,
                .is_file = e.kind == .file,
                .mtime_ns = mtime,
                .ctime_ns = ctime,
            }) catch oom();
        }
    }

    // This directory's own ignore rules — unless the frozen base already holds
    // them (the CWD root, loaded by `Ignore.init`; keyed by stripped rel).
    var chain = task.chain;
    if (!o.no_ignore and (present.gitignore or present.dotignore or present.rgignore) and
        !cfg.ig.loaded.contains(task.rel) and !cfg.ig.loaded.contains(stripDot(task.rel)))
        chain = loadNode(cfg.ig, a, task.chain, task.disk, task.rel, present);

    // Children go on the worker's own stack; only the COUNT touches the
    // shared queue (accounting must precede this task's `done`).
    const before = local.items.len;
    for (entries.items) |e| handleEntry(w, a, scratch, dir.handle, task, chain, local, e);
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

fn noteIgnoreFile(present: *IgPresent, name: []const u8, is_file: bool) void {
    if (!is_file or name.len < 7 or name[0] != '.') return;
    if (std.mem.eql(u8, name, ".gitignore")) {
        present.gitignore = true;
    } else if (std.mem.eql(u8, name, ".ignore")) {
        present.dotignore = true;
    } else if (std.mem.eql(u8, name, ".rgignore")) {
        present.rgignore = true;
    }
}

fn handleEntry(w: *Worker, a: std.mem.Allocator, scratch: []u8, dirfd: std.posix.fd_t, task: DirTask, chain: ?*const IgNode, children: *std.ArrayList(DirTask), e: Entry) void {
    const cfg = w.cfg;
    const o = cfg.o;
    if (!e.is_dir and !e.is_file) return; // symlinks & specials — never followed here
    const depth = task.depth + 1;
    const rel = joinRel(a, task.rel, e.name);
    if (shouldSkip(cfg, chain, a, task, rel, e.is_dir, e.name)) return;
    if (e.is_dir) {
        if (o.max_depth != 0 and depth >= o.max_depth) return;
        children.append(a, .{
            .disk = joinPath(a, task.disk, e.name),
            .rel = rel,
            .depth = depth,
            .root_depth = task.root_depth,
            .chain = chain,
        }) catch oom();
        return;
    }
    if (o.max_depth != 0 and depth > o.max_depth) return;
    if (o.filter.active() and !o.filter.admits(a, rel)) return;
    if (cfg.lazy) |lz| {
        if (lz.ready.load(.acquire)) {
            if (lz.val) |*el| if (el.skip(stripDot(rel), e.mtime_ns, e.ctime_ns)) return;
        } else {
            // Oracle still loading — hold the file back so it can still be
            // elided (the walk races ahead; deferring costs three slices + metadata).
            w.pending.append(a, .{
                .disk = joinPath(a, task.disk, e.name),
                .rel = rel,
                .mtime_ns = e.mtime_ns,
                .ctime_ns = e.ctime_ns,
            }) catch oom();
            return;
        }
    }

    const dpath = if (o.path_sep) |sep| replaceSep(a, rel, sep) else rel;
    if (cfg.files_mode) {
        // Streamed straight through — `Sink.emit` appends the one-byte
        // separator, so listing a file allocates nothing beyond `dpath` itself.
        cfg.sink.emit(.text_hit, dpath);
        return;
    }
    // The parent directory is still open in `processDir` — resolve one
    // component (`e.name`) against its fd instead of the full path from CWD.
    // `rel` is the CWD-openable path a `-z` external-codec subprocess re-opens.
    searchFile(w, a, scratch, dirfd, e.name, dpath, rel);
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
        if (body.len == 0) return;
        emitBody(w, a, dpath, body, 0, 0);
        return;
    }

    const sf = grepfile.StagedFile.open(scratch, dirfd, disk) orelse return;
    defer sf.close();

    // Stage 1 — decide what the first BUFCAP bytes (rg's buffer 0) already
    // settle, before paying for the tail (86% of this corpus's bytes live in
    // the tails of >64 KiB files). A UTF-16 BOM opts out: the transcode needs
    // the whole file and dissolves its NULs, so no prefix triage is sound.
    const utf16 = sf.prefix.len >= 2 and
        ((sf.prefix[0] == 0xFF and sf.prefix[1] == 0xFE) or (sf.prefix[0] == 0xFE and sf.prefix[1] == 0xFF));
    if (!utf16) {
        // NUL in buffer 0: rg's emission cutoff is the start of the buffer that
        // holds the first NUL — the very first — so an implicit walked file
        // contributes NOTHING in any parallel-engine mode (`-l`, default, `-c`,
        // context, `-o` all key off lines before the cutoff; `--binary`-style
        // explicit files never reach this engine). Skip without the tail read.
        if (cfg.binary_detect and std.mem.indexOfScalar(u8, sf.prefix, 0) != null) return;
        // `-l` + a >64 KiB file: a match PROVEN inside the NUL-free prefix is a
        // match of the file (a partial trailing line only truncates a real
        // line, and the literal gates never over-claim) — emit and skip the
        // tail. Absence proves nothing; fall through to the full read.
        if (cfg.fast_l and sf.more and prefixProvesMatch(w, re, grepfile.stripBom(sf.prefix))) {
            var buf: std.ArrayList(u8) = .empty;
            buf.print(a, "{s}{c}", .{ dpath, @as(u8, if (o.null_sep) 0 else '\n') }) catch oom();
            cfg.sink.emit(.text_hit, buf.items);
            return;
        }
    }
    const raw = if (sf.more) (sf.readRest(a, scratch) orelse return) else sf.prefix;
    const body = grepfile.decodeBom(a, raw);
    if (body.len == 0) return;
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
    // rg-parity walk legitimately admits via explicit-root re-anchoring) stops
    // serializing the whole walk behind a single-thread scan.
    if (cfg.file_needle) |n| if (!verify.containsWide(a, body[gate_from..], n)) return;
    if (cfg.file_alts.len > 0 and !verify.containsAnyWide(a, body[gate_from..], cfg.file_alts)) return;

    var buf: std.ArrayList(u8) = .empty;
    var em = Emitter{
        .a = a,
        .re = re,
        .o = o,
        // The serial engine keys this off the RAW --heading flag (not the
        // count/files-only-adjusted `cfg.heading`) — match it exactly.
        .show_name = if (o.heading) false else cfg.show_name,
        .out = &buf,
        .base = @intFromPtr(body.ptr),
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
        const matched = grepfile.handleBinary(a, re, o, &buf, &em, dpath, false, body, nul, cfg.show_name);
        if (matched or buf.items.len > 0)
            cfg.sink.emit(if (matched) .bin_hit else .text_plain, buf.items);
        return;
    };

    // `-l` fused fast path: one early-exit whole-buffer pass answers the file —
    // no line split, no per-line engine dispatch. When the pattern is a pure
    // literal (alternation), the whole-file gate above already PROVED the match
    // (equivalence, not containment), so not even `docMatch` runs.
    if (cfg.fast_l) {
        const hit = cfg.lits_equiv or blk: {
            const sim = workerSim(w) orelse break :blk false;
            break :blk re.docMatch(sim, body);
        };
        if (hit) {
            buf.print(a, "{s}{c}", .{ dpath, @as(u8, if (o.null_sep) 0 else '\n') }) catch oom();
            cfg.sink.emit(.text_hit, buf.items);
        }
        return;
    }

    var lines: std.ArrayList([]const u8) = .empty;
    grepfile.collectLines(a, body, o.term(), &lines);
    if (cfg.heading) buf.print(a, "{s}\n", .{dpath}) catch oom();
    const before_body = buf.items.len;
    const hits = em.file(dpath, lines.items);
    if (hits == 0) {
        // No heading header to keep, and (except --passthru) no body either.
        if (cfg.heading or buf.items.len == before_body) return;
        cfg.sink.emit(.text_plain, buf.items);
        return;
    }
    cfg.sink.emit(.text_hit, buf.items);
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
        if (cfg.file_needle) |n| return simd.contains(prefix, n);
        return simd.containsAny(prefix, cfg.file_alts);
    }
    const nl = std.mem.lastIndexOfScalar(u8, prefix, '\n') orelse return false;
    const sim = workerSim(w) orelse return false;
    return re.docMatch(sim, prefix[0 .. nl + 1]);
}

// ─────────────────────────── run ───────────────────────────

/// Fan out, walk, search, stream, exit. `filters` powers inline index elision;
/// `file_needle` may reject a whole body, while `line_needle` only avoids regex
/// execution and remains valid for passthru. Never returns.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    parsed: args.Parsed,
    o: Opts,
    re: ?*const Matcher,
    use_color: bool,
    filters: []const []const u8,
    file_needle: ?[]const u8,
    line_needle: ?[]const u8,
    icfg: *const ingest.Config,
) noreturn {
    const heading = o.heading and !o.count_only and !o.count_matches and !o.files_only and !o.vimgrep;
    const want_elision = indexElisionWanted(parsed, filters);
    // Internal gate-only contract: load synchronously and fail closed unless
    // the real elision oracle is admitted. This makes freshness_fs.sh prove the
    // accelerated path instead of accidentally passing via an async/full-read
    // fallback. It is intentionally not a CLI flag.
    const require_elision = args.envSpan("GIST_TEST_REQUIRE_ELISION") != null;
    if (require_elision and !want_elision) die("gist: test-required index elision was not eligible\n", .{});
    // The elide oracle loads on its own thread while the walk runs, keeping
    // mmap validation, sparse posting decode, and path-table setup off the
    // serial query prefix.
    var lazy = LazyElide{};
    if (want_elision) {
        if (require_elision) {
            lazy.val = buildElide(gpa, io, o, filters);
            if (lazy.val == null) die("gist: test-required index elision was declined\n", .{});
            if (!testHasElidableFile(io, &lazy.val.?)) die("gist: test-required index elision found no elidable live file\n", .{});
            lazy.ready.store(true, .release);
        } else {
            // Detached: if every worker out-walks the load and gives up on
            // elision, nobody waits on this thread — `run` exits the process and
            // the OS reclaims it. (`lazy`/`o`/`filters` outlive it either way:
            // this frame never returns.)
            if (std.Thread.spawn(.{}, LazyElide.loaderMain, .{ &lazy, gpa, io, o, filters })) |t| {
                t.detach();
            } else |_| {
                lazy.val = buildElide(gpa, io, o, filters);
                lazy.ready.store(true, .release);
            }
        }
    } else {
        lazy.ready.store(true, .release);
    }

    var ig = ignore.Ignore.init(gpa, io, o, parsed.roots);
    const compiled = ignore.Compiled.build(gpa, &ig);
    var q = Queue{ .gpa = gpa, .io = io };
    defer q.items.deinit(gpa);
    var sink = Sink{
        .q = &q,
        .io = io,
        .heading = heading,
        .join_groups = o.wantsContext() and !o.files_only and !o.count_only and !o.count_matches and !heading,
        .files_mode = o.files_list,
        .null_sep = o.null_sep,
    };
    // Pure-literal alternation gate/equivalence (see `Cfg.file_alts`): only when
    // no single required literal already gates, and never for modes that must
    // read every body (`-v` needs zero-hit files; passthru emits them).
    const lits: []const []const u8 = if (re) |m| m.lits() else &.{};
    const file_alts: []const []const u8 = if (lits.len > 0 and file_needle == null and !o.invert and !o.passthru) lits else &.{};
    // Equivalence proof: the whole-file gate that will run (`file_needle`, a
    // single pure literal, or `file_alts`, a pure alternation) IS the pattern.
    const lits_equiv = (file_needle != null and lits.len == 1 and std.mem.eql(u8, lits[0], file_needle.?)) or file_alts.len > 0;
    const fast_l = o.files_only and !o.invert and !o.word and !o.crlf and !o.null_data and
        o.max_per_file == 0 and !o.only_matching and !o.count_only and !o.count_matches and
        !o.passthru and !o.vimgrep and !o.stop_on_nonmatch and o.replace == null;
    const gate_len = blk: {
        var m: usize = if (file_needle) |n| n.len else 0;
        for (file_alts) |n| m = @max(m, n.len);
        break :blk m;
    };
    const cfg = Cfg{
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
        .show_name = switch (o.filename) {
            .always => true,
            .never => false,
            .auto => true, // the walk is recursive by construction
        },
        .heading = heading,
        .join_groups = sink.join_groups,
        .binary_detect = !o.text and !o.null_data,
        .files_mode = o.files_list,
        .ingest = if (icfg.active()) icfg else null,
        .sink = &sink,
    };
    var roots_one = [_][]const u8{"."};
    const roots: []const []const u8 = if (parsed.roots.len > 0) parsed.roots else roots_one[0..];
    {
        var seed: std.ArrayList(DirTask) = .empty;
        defer seed.deinit(gpa);
        for (roots) |r| {
            const prefix = if (std.mem.eql(u8, r, ".") and parsed.roots.len == 0) "" else std.mem.trimEnd(u8, r, "/");
            seed.append(gpa, .{ .disk = r, .rel = prefix, .depth = 0, .root_depth = rootDepth(prefix), .chain = null }) catch oom();
        }
        q.push(seed.items);
    }

    // Full-corpus scans retain the measured six-worker ceiling. Traversal-only,
    // narrow-root, and index-selective runs do less useful work per file, so on
    // wider machines they use roughly half the logical CPUs (four on an 8-core
    // M2) instead of paying extra spawn/namei/fd contention. `GIST_WORKERS`
    // remains absolute.
    const ncpu = std.Thread.getCpuCount() catch 6;
    const narrow_scope = parsed.roots.len > 0 and !broadIndexedRoots(parsed.roots);
    // A transforming run (-z/--pre/-E) does CPU-bound per-file work — inflate
    // (gzip/xz/zstd) or transcode — that scales to every core, exactly like the
    // serial engine's parallel read-shards (`run.zig` `readCandidates` fans out
    // to `min(candidates, ncpu)`). The 6-worker ceiling is tuned for the
    // syscall/namei-bound plaintext walk, where more threads only add fd + namei
    // contention; it throttles decode-heavy codecs (xz/zstd) below the serial
    // path, so a transforming pipeline lifts the cap to all logical CPUs.
    var nworkers = if (icfg.active())
        @max(@as(usize, 1), ncpu)
    else
        defaultWorkerCount(ncpu, o.files_list or want_elision or narrow_scope);
    // -j/--threads caps the pool explicitly (rg's `--threads`); 0 keeps gist's
    // adaptive topology. `GIST_WORKERS` still overrides everything (parity gates).
    if (o.threads != 0) nworkers = @max(1, o.threads);
    if (args.envSpan("GIST_WORKERS")) |s| {
        if (std.fmt.parseInt(usize, s, 10)) |n| {
            nworkers = @max(1, n);
        } else |_| {}
    }
    const workers = gpa.alloc(Worker, nworkers) catch oom();
    defer gpa.free(workers);
    for (workers) |*w| w.* = .{ .q = &q, .io = io, .gpa = gpa, .cfg = &cfg, .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    defer for (workers) |*w| w.arena.deinit();

    const threads = gpa.alloc(std.Thread, nworkers) catch oom();
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (workers[1..]) |*w| {
        threads[spawned] = std.Thread.spawn(.{}, workerMain, .{w}) catch break;
        spawned += 1;
    }
    workerMain(&workers[0]); // the main thread is a worker too
    for (threads[0..spawned]) |t| t.join();

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
    // (already-streamed) output, exactly as the serial engine's `pcreFaultExit`.
    if (re) |m| if (m.matchError() != 0) {
        var errbuf: [256]u8 = undefined;
        std.debug.print("gist: PCRE2: error matching: {s}\n", .{pcre2.matchErrorMessage(&errbuf)});
        std.process.exit(2);
    };
    std.process.exit(if (q.walk_error.load(.acquire)) 2 else if (sink.matched_files > 0) 0 else 1);
}

fn defaultWorkerCount(ncpu_raw: usize, selective: bool) usize {
    const ncpu = @max(@as(usize, 1), ncpu_raw);
    const full = @min(ncpu, 6);
    if (!selective or ncpu <= 4) return full;
    return @min(full, @max(@as(usize, 4), (ncpu + 1) / 2));
}

test "IndexedPaths resolves exactly and reads unknown paths" {
    const t = std.testing;
    const paths = [_][]const u8{ "libs/a.zig", "services/b.go", "clients/c.ts" };
    var indexed = try IndexedPaths.init(t.allocator, &paths);
    defer indexed.deinit();

    try t.expectEqual(@as(?u32, 0), indexed.get(&paths, "libs/a.zig"));
    try t.expectEqual(@as(?u32, 2), indexed.get(&paths, "clients/c.ts"));
    try t.expectEqual(@as(?u32, null), indexed.get(&paths, "libs/new.zig"));

    var buf: [32]u8 = undefined;
    var collision_checked = false;
    for (0..1024) |i| {
        const unknown = try std.fmt.bufPrint(&buf, "new/path-{d}", .{i});
        if (indexed.slot(unknown) != indexed.slot(paths[0])) continue;
        try t.expectEqual(@as(?u32, null), indexed.get(&paths, unknown));
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

test "worker topology keeps scans wide and selective walks lean" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 4), defaultWorkerCount(8, true));
    try t.expectEqual(@as(usize, 6), defaultWorkerCount(8, false));
    try t.expectEqual(@as(usize, 4), defaultWorkerCount(4, true));
    try t.expectEqual(@as(usize, 6), defaultWorkerCount(12, true));
}
