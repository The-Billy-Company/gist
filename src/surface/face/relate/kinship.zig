//! relate — shared kinship plumbing for the sketch-backed verbs.
//!
//! One deep seam under `similar` / `dups` / `clusters`: resolve a **view** —
//! the (paths, sketches) table for the queried roots — from the cheapest
//! sound source, then hand the verb pure arrays. Three rungs, elide-only
//! (identical answers, fewer bytes touched):
//!
//!   1. persisted atlas + freshness fold (`index/atlas/atlas.zig`) — load
//!      ~1 KiB/file, re-sketch only what changed since the anchor;
//!   2. live corpus build — read every corpus byte and sketch in parallel
//!      (the pre-atlas path), taken when the atlas is missing, corrupt,
//!      `--no-index` was passed, or a root lies outside the indexed corpus;
//!   3. either way, verbs that answer purely from sketches gate emitted
//!      rows through `gate` (a per-row stat) so a file deleted after the
//!      anchor cannot surface — O(results), never O(corpus).
//!
//! Also hosts the pair machinery `dups` and `clusters` share: bottom-16
//! seed-hash candidate buckets, exact pairwise verification against both
//! sketches, and the total (distance, path, path) order.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const atlas_mod = @import("../../../corpus/index/atlas/atlas.zig");
const trigram_persist = @import("../../../corpus/index/trigrams/persist.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const scope = @import("../../../corpus/scope/glob.zig");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const pairs = @import("../../../kernel/kinship/cluster/pairs.zig");
const parallel = @import("../../../kernel/primitives/parallel.zig");

const oom = cli_args.oom;
const die = cli_args.die;
pub const Sketch = sketch.Sketch;
pub const Silhouette = silhouette_mod.Silhouette;

// ── root + path plumbing (shared by every relate verb) ──

/// The value slot after a flag, or `die(msg)` when argv ends first.
pub fn need(argv: []const []const u8, i: *usize, comptime msg: []const u8) []const u8 {
    i.* += 1;
    if (i.* >= argv.len) die(msg, .{});
    return argv[i.*];
}

/// Parse the value of an integer flag (`--top 5`), dying with a uniform
/// bad-number message keyed on `flag` — the shared int-flag parse every
/// relate/irregex verb consumes instead of re-spelling `parseInt … catch die`.
pub fn count(argv: []const []const u8, i: *usize, comptime flag: []const u8) usize {
    return std.fmt.parseInt(usize, need(argv, i, flag ++ " needs a number\n"), 10) catch
        die(flag ++ ": bad number: {s}\n", .{argv[i.*]});
}

/// Parse `--min-size`: an integer ≥ 2, since a family needs at least two
/// members. Shared by `relate concepts` and the composed `irregex family`.
pub fn minSize(argv: []const []const u8, i: *usize) usize {
    const n = count(argv, i, "--min-size");
    if (n < 2) die("--min-size: a family needs at least 2 members\n", .{});
    return n;
}

/// Parse a finite distance/echo threshold. NaN and infinities must not enter
/// ordering predicates: they make every comparison false and silently empty
/// otherwise-valid result sets.
pub fn unitFloat(raw: []const u8, flag: []const u8) f64 {
    const value = std.fmt.parseFloat(f64, raw) catch die("{s}: bad number: {s}\n", .{ flag, raw });
    if (!std.math.isFinite(value) or value < 0.0 or value > 1.0)
        die("{s}: expected a finite number in [0,1], got {s}\n", .{ flag, raw });
    return value;
}

/// Which distance a kinship verb ranks by: the raw-byte LZJD sketch, the
/// normalized-structure silhouette, or their minimum ("close in EITHER
/// channel counts" — the best renamed-twin retriever on the graduation eval).
pub const Lens = enum { bytes, structure, fused };

/// The option surface the relate query verbs share; each verb seeds its own
/// `top` default and reads only the fields its `parseOpts` config admits.
pub const Opts = struct {
    top: usize,
    json: bool = false,
    no_index: bool = false,
    max_dist: f64 = 0.25,
    min_size: usize = 2,
    lens: Lens = .bytes,
    min_echo: f64 = 0.15,
    arg: ?[]const u8 = null, // the one positional (similar's path, search/pack's text)
};

/// One flag loop for every relate query verb: `--top`/`--json` always, the
/// rest opt-in per `cfg`. A strict verb dies on an unknown `-flag`; a lax one
/// keeps the arg as positional/root (the historical shape). With
/// `cfg.positional` the first bare arg fills `opts.arg`; every other bare arg
/// is a normalized root.
pub fn parseOpts(
    gpa: std.mem.Allocator,
    argv: []const []const u8,
    opts: *Opts,
    roots: *std.ArrayList([]const u8),
    comptime cfg: struct {
        max_dist: bool = false,
        min_size: bool = false,
        no_index: bool = false,
        lens: bool = false,
        min_echo: bool = false,
        positional: bool = false,
        strict: ?[]const u8 = null,
    },
) !void {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (cfg.max_dist and std.mem.eql(u8, arg, "--max-distance")) {
            opts.max_dist = unitFloat(need(argv, &i, "--max-distance needs a number in [0,1]\n"), "--max-distance");
        } else if (cfg.min_size and std.mem.eql(u8, arg, "--min-size")) {
            opts.min_size = std.fmt.parseInt(usize, need(argv, &i, "--min-size needs a number ≥ 2\n"), 10) catch die("--min-size: bad number: {s}\n", .{argv[i]});
            if (opts.min_size < 2) die("--min-size: a family needs at least 2 members\n", .{});
        } else if (cfg.lens and std.mem.eql(u8, arg, "--lens")) {
            opts.lens = std.meta.stringToEnum(Lens, need(argv, &i, "--lens needs bytes|structure|fused\n")) orelse die("--lens: bytes, structure, or fused, not {s}\n", .{argv[i]});
        } else if (cfg.min_echo and std.mem.eql(u8, arg, "--min-echo")) {
            opts.min_echo = unitFloat(need(argv, &i, "--min-echo needs a number in [0,1]\n"), "--min-echo");
        } else if (std.mem.eql(u8, arg, "--top")) {
            opts.top = std.fmt.parseInt(usize, need(argv, &i, "--top needs a number\n"), 10) catch die("--top: bad number: {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (cfg.no_index and std.mem.eql(u8, arg, "--no-index")) {
            opts.no_index = true;
        } else if (cfg.strict != null and std.mem.startsWith(u8, arg, "-")) {
            die("relate " ++ (comptime cfg.strict.?) ++ ": unknown flag {s}\n", .{arg});
        } else if (cfg.positional and opts.arg == null) {
            opts.arg = arg;
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
}

/// Positional args → corpus roots (already normalized); empty → the corpus
/// for this working directory (`corpus.resolveRoots`). `deinit` releases only
/// what resolution allocated — a borrow of the positionals frees nothing.
pub const Roots = struct {
    items: []const []const u8,
    owned: bool = false,

    pub fn deinit(self: Roots, gpa: std.mem.Allocator) void {
        if (self.owned) corpus_mod.freeRoots(gpa, self.items);
    }
};

pub fn rootsOf(gpa: std.mem.Allocator, positional: []const []const u8) !Roots {
    if (positional.len > 0) return .{ .items = positional };
    return .{ .items = try corpus_mod.resolveRoots(gpa), .owned = true };
}

/// Strip one exact leading `./` — the canonical shape for comparing a user
/// arg against a walk-produced path (never trims `..`).
pub fn stripDotSlash(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
}

/// Is `path` at, or under, any of `roots`? Empty roots = the whole corpus.
/// The shared `scope/glob.zig` boundary rule: exact file hit, or a directory
/// prefix ending at `/` (so `services` never admits `services_old`).
pub fn underAnyRoot(path: []const u8, roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    for (roots) |r| if (scope.underRoot(path, std.mem.trimEnd(u8, scope.normalizeRoot(r), "/"))) return true;
    return false;
}

/// Append `s` JSON-string-escaped (quotes included) — the NDJSON escaper the
/// relate/irregex verb drivers share, the one `emit/jsonstr` primitive so all
/// faces escape identically (arg order matches these `(buf, gpa, s)` callers).
pub const jsonStr = @import("../../exec/cold/emit/jsonstr.zig").write;

/// One NDJSON result row from a comptime field spec — the shared emitter
/// behind every relate verb's `--json` arm. Each entry is `.{ "key", kind,
/// value }` with kind `"s"` (escaped string), `"s?"` (escaped string or
/// `null`), or a `std.fmt` spec like `"d:.4"` applied verbatim.
pub fn jsonRow(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, fields: anytype) void {
    inline for (fields, 0..) |f, i| {
        buf.appendSlice(gpa, (if (i == 0) "{\"" else ",\"") ++ f[0] ++ "\":") catch oom();
        if (comptime std.mem.eql(u8, f[1], "s")) {
            jsonStr(buf, gpa, f[2]);
        } else if (comptime std.mem.eql(u8, f[1], "s?")) {
            if (f[2]) |v| jsonStr(buf, gpa, v) else buf.appendSlice(gpa, "null") catch oom();
        } else {
            buf.print(gpa, "{" ++ f[1] ++ "}", .{f[2]}) catch oom();
        }
    }
    buf.appendSlice(gpa, "}\n") catch oom();
}

/// One result row: `--json` routes through `jsonRow`, text prints `tfmt`.
pub fn emitRow(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, json: bool, jfields: anytype, comptime tfmt: []const u8, targs: anytype) void {
    if (json) jsonRow(buf, gpa, jfields) else buf.print(gpa, tfmt, targs) catch oom();
}

/// The whole argv is empty or repetitions of `flag` (returns whether it was
/// present); anything else dies with `usage_msg` — the lifecycle verbs' parse.
pub fn onlyFlag(argv: []const []const u8, comptime flag: []const u8, comptime usage_msg: []const u8) bool {
    for (argv) |arg| if (!std.mem.eql(u8, arg, flag)) die(usage_msg, .{});
    return argv.len > 0;
}

// ── parallel sketch/silhouette build (the live rung) ──

/// Sketch every doc in parallel — byte-balanced shards, one thread per
/// ~4 MiB of corpus (a sketch parse is heavier per byte than SIMD verify).
/// A doc that fails to sketch (OOM under pressure) records `Sketch.empty`,
/// which `distance` treats as maximally far — it can surface in no result,
/// only ever hide one, and the failure is counted on stderr.
pub fn buildSketches(gpa: std.mem.Allocator, docs: []const []const u8) []Sketch {
    return buildAll(Sketch, sketch.build, gpa, docs);
}

/// Silhouette every doc in parallel — the structure channel, same sharding
/// and degrade posture as `buildSketches`.
pub fn buildSilhouettes(gpa: std.mem.Allocator, docs: []const []const u8) []Silhouette {
    return buildAll(Silhouette, silhouette_mod.build, gpa, docs);
}

/// The shared parallel per-doc builder behind both channels: `T` needs an
/// `empty` decl (the maximally-far degrade value) and `buildFn(gpa, bytes) !T`.
fn buildAll(comptime T: type, comptime buildFn: anytype, gpa: std.mem.Allocator, docs: []const []const u8) []T {
    const out = gpa.alloc(T, docs.len) catch oom();
    var total: usize = 0;
    for (docs) |d| total += d.len;

    const ncpu = std.Thread.getCpuCount() catch 1;
    const nthr = @min(@max(@as(usize, 1), total / (4 << 20)), ncpu);

    const Shard = struct {
        docs: []const []const u8,
        out: []T,
        failed: usize = 0,

        fn run(sh: *@This()) void {
            // Each worker allocates its own scratch from the page allocator —
            // no cross-thread contention on the caller's gpa.
            for (sh.docs, sh.out) |d, *s| s.* = buildFn(std.heap.page_allocator, d) catch blk: {
                sh.failed += 1;
                break :blk .empty;
            };
        }
    };

    // Byte-greedy shard boundaries (the shared parallel floor).
    const bounds = gpa.alloc(usize, nthr + 1) catch oom();
    defer gpa.free(bounds);
    parallel.greedyBounds([]const u8, docs, {}, parallel.sliceLen, total, bounds);

    const shards = gpa.alloc(Shard, nthr) catch oom();
    defer gpa.free(shards);
    const threads = gpa.alloc(std.Thread, nthr) catch oom();
    defer gpa.free(threads);
    for (0..nthr) |t|
        shards[t] = .{ .docs = docs[bounds[t]..bounds[t + 1]], .out = out[bounds[t]..bounds[t + 1]] };
    // A shard whose thread never spawned still needs its slice filled.
    parallel.fanOut(Shard, shards, threads, Shard.run);
    var failed: usize = 0;
    for (shards) |sh| failed += sh.failed;
    if (failed != 0) std.debug.print("relate: {d} file(s) failed to sketch (skipped)\n", .{failed});
    return out;
}

// ── the view resolver ──

/// The (paths, sketches[, silhouettes]) table a kinship verb answers over,
/// plus the keepalive state that owns it. `from_atlas` tells the verb whether
/// emitted rows need the deletion gate. `silhouettes` is doc-parallel to
/// `sketches` when the view was resolved with `.structure`, empty otherwise.
pub const View = struct {
    paths: []const []const u8,
    sketches: []const Sketch,
    silhouettes: []const Silhouette = &.{},
    from_atlas: bool,
    refreshed: usize, // files re-sketched by the freshness fold

    // keepalive (whichever rung answered)
    atl: ?atlas_mod.Atlas = null,
    folded: ?atlas_mod.Folded = null,
    corpus: ?corpus_mod.Corpus = null,
    live_sketches: ?[]Sketch = null,
    live_silhouettes: ?[]Silhouette = null,
    scoped_paths: ?[][]const u8 = null,
    scoped_sketches: ?[]Sketch = null,
    scoped_silhouettes: ?[]Silhouette = null,
    gpa: std.mem.Allocator,
    io: std.Io,

    pub fn deinit(self: *View) void {
        if (self.scoped_paths) |p| self.gpa.free(p);
        if (self.scoped_sketches) |s| self.gpa.free(s);
        if (self.scoped_silhouettes) |s| self.gpa.free(s);
        if (self.live_sketches) |s| self.gpa.free(s);
        if (self.live_silhouettes) |s| self.gpa.free(s);
        if (self.corpus) |*c| c.deinit();
        if (self.folded) |*f| f.deinit();
        if (self.atl) |*a| a.deinit(self.gpa);
    }

    /// Emit-time deletion gate: true when `paths[idx]` may be surfaced.
    /// Live-built views are trivially current; atlas-backed rows verify the
    /// file still exists (a deleted file's sketch must not answer).
    pub fn gate(self: *const View, idx: usize) bool {
        if (!self.from_atlas) return true;
        return atlas_mod.onDisk(self.io, self.paths[idx]);
    }

    /// Which rung answered, for the verbs' shared stderr diagnostic shape.
    pub fn provenance(self: *const View) []const u8 {
        return if (self.from_atlas) "atlas, " else "live, ";
    }
};

/// Which channels a verb needs its view to carry: `bytes` = the LZJD
/// sketches only (dups/clusters); `structure` = silhouettes too (a lensed
/// similar, echoes). The atlas persists both, so warm answers carry both
/// either way; the flag only spares the LIVE rung a second per-doc pass.
pub const Wants = enum { bytes, structure };

/// Loading + validating the global atlas has a fixed whole-artifact cost. For
/// a narrow explicit scope, rebuilding a few hundred sketches from source is
/// materially cheaper. The mmap-backed trigram path table lets us estimate
/// scope cardinality without walking or reading the scoped corpus first.
fn preferScopedLive(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) bool {
    if (roots.len == 0) return false;
    var persisted = (trigram_persist.loadQuiet(gpa, io) catch return false) orelse return false;
    defer persisted.deinit();
    var scoped: usize = 0;
    for (persisted.paths.items) |path| {
        if (!underAnyRoot(path, roots)) continue;
        scoped += 1;
        if (scoped > 512) return false;
    }
    return true;
}

/// Resolve the cheapest sound view for `roots` (normalized explicit roots;
/// empty = default). The atlas rung requires every root inside the indexed
/// corpus — an out-of-corpus root has no sketches to elide and needs the
/// live read (the same admission rule `patterns` applies to the trigram
/// index).
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, no_index: bool, wants: Wants) !View {
    atlas: {
        if (no_index) break :atlas;
        if (preferScopedLive(gpa, io, roots)) break :atlas;
        var atl = atlas_mod.loadQuiet(gpa, io) orelse break :atlas;
        // Every queried root must sit inside the roots the atlas was BUILT
        // over (persisted in the blob) — an out-of-corpus root has no
        // sketches to elide and needs the live read below.
        for (roots) |r| {
            if (!underAnyRoot(r, atl.roots)) {
                atl.deinit(gpa);
                break :atlas;
            }
        }
        errdefer atl.deinit(gpa);
        // An explicitly scoped query only needs freshness inside that scope.
        // Folding every changed file in a 55k-file atlas before discarding
        // out-of-scope rows made a one-package `similar` query pay whole-tree
        // coworker churn.
        var folded = atlas_mod.fold(gpa, io, &atl, if (roots.len > 0) roots else atl.roots) catch {
            atl.deinit(gpa);
            break :atlas;
        };
        errdefer folded.deinit();

        var view = View{
            .paths = folded.paths.items,
            .sketches = folded.sketches.items,
            .silhouettes = folded.silhouettes.items,
            .from_atlas = true,
            .refreshed = folded.refreshed,
            .gpa = gpa,
            .io = io,
        };
        if (roots.len > 0) {
            // Scope the folded table to the queried roots (id-parallel copy).
            var n: usize = 0;
            for (folded.paths.items) |p| n += @intFromBool(underAnyRoot(p, roots));
            const sp = try gpa.alloc([]const u8, n);
            errdefer gpa.free(sp);
            const ss = try gpa.alloc(Sketch, n);
            errdefer gpa.free(ss);
            const sl = try gpa.alloc(Silhouette, n);
            errdefer gpa.free(sl);
            var w: usize = 0;
            for (folded.paths.items, folded.sketches.items, folded.silhouettes.items) |p, s, sil| {
                if (!underAnyRoot(p, roots)) continue;
                sp[w] = p;
                ss[w] = s;
                sl[w] = sil;
                w += 1;
            }
            view.scoped_paths = sp;
            view.scoped_sketches = ss;
            view.scoped_silhouettes = sl;
            view.paths = sp;
            view.sketches = ss;
            view.silhouettes = sl;
        }
        view.atl = atl;
        view.folded = folded;
        return view;
    }

    // Live rung: read the scoped corpus and sketch it in parallel (both
    // channels when the verb asked for structure).
    const rr = try rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items);
    errdefer corpus.deinit();
    const sketches = buildSketches(gpa, corpus.docs);
    const silhouettes: ?[]Silhouette = if (wants == .structure) buildSilhouettes(gpa, corpus.docs) else null;
    return .{
        .paths = corpus.paths,
        .sketches = sketches,
        .silhouettes = silhouettes orelse &.{},
        .from_atlas = false,
        .refreshed = 0,
        .corpus = corpus,
        .live_sketches = sketches,
        .live_silhouettes = silhouettes,
        .gpa = gpa,
        .io = io,
    };
}

// ── the pair machinery (`dups` + `clusters` + `echoes`) ──
// The pure candidate-bucket + exact-verify kernel lives in `pairs.zig`; the
// relate verbs reach it through this hub so their call sites stay stable.

pub const Pair = pairs.Pair;
pub const seed_hashes = pairs.seed_hashes;
pub const bucket_cap = pairs.bucket_cap;
pub const forEachCandidatePair = pairs.forEachCandidatePair;
pub const verifiedPairs = pairs.verifiedPairs;
