//! relate — fingerprinting a corpus, and the file-level view over it.
//!
//! The floor every kinship answer stands on, in two halves:
//!
//!   • **Fingerprints in parallel.** Byte-balanced shards, one thread per ~4 MiB
//!     of corpus, for both channels (LZJD sketch, structure silhouette). A doc
//!     that fails to fingerprint degrades to the maximally-far empty record —
//!     it can hide a result, never invent one — and the failure is counted on
//!     stderr rather than swallowed.
//!
//!   • **The file view.** Resolve the (paths, sketches, silhouettes) table for
//!     the queried roots from the cheapest sound source: the persisted kinship
//!     atlas plus a freshness fold, or a live read. Elide-only — identical
//!     answers, fewer bytes touched — and rows emitted from the atlas pass a
//!     deletion gate, so a file deleted since the anchor cannot answer.
//!
//! `units.zig` wraps this into the unit view every verb actually queries (files,
//! functions, or exact-matched regions); the pair machinery `pairs.zig` owns is
//! re-exported here so the face's call sites stay stable.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const atlas_mod = @import("../../../corpus/index/atlas/atlas.zig");
const trigram_persist = @import("../../../corpus/index/trigrams/persist.zig");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const fingerprint = @import("../../../kernel/kinship/metric/fingerprint.zig");
const pairs = @import("../../../kernel/kinship/cluster/pairs.zig");
const flags = @import("../../cli/flags.zig");
const grade = @import("../../cli/grade.zig");
const assay = @import("../../../assay/assay.zig");

const oom = @import("../../cli/outcome.zig").oom;
pub const Sketch = sketch.Sketch;
pub const Silhouette = silhouette_mod.Silhouette;

/// The one channel vocabulary, shared with every other face.
pub const Channel = grade.Channel;

// ── parallel fingerprint build (the live rung) ──

/// Sketch every doc in parallel — the byte channel.
pub fn buildSketches(gpa: std.mem.Allocator, docs: []const []const u8) []Sketch {
    return buildAll(Sketch, sketch.build, gpa, docs);
}

/// Silhouette every doc in parallel — the structure channel, same sharding and
/// degrade posture as `buildSketches`.
pub fn buildSilhouettes(gpa: std.mem.Allocator, docs: []const []const u8) []Silhouette {
    return buildAll(Silhouette, silhouette_mod.build, gpa, docs);
}

/// The shared parallel per-doc builder behind both channels. The pass itself
/// lives beside the records in `kernel/kinship/metric/fingerprint.zig` — the
/// atlas freshness fold needs the same one — so this rung supplies only the
/// allocation and the operator-facing degrade report.
fn buildAll(comptime T: type, comptime buildFn: anytype, gpa: std.mem.Allocator, docs: []const []const u8) []T {
    const out = gpa.alloc(T, docs.len) catch oom();
    const failed = fingerprint.fill(T, buildFn, gpa, docs, out) catch oom();
    if (failed != 0) std.debug.print("relate: {d} file(s) failed to fingerprint (skipped)\n", .{failed});
    return out;
}

// ── the file view ──

/// The (paths, sketches[, silhouettes]) table for the queried roots, plus the
/// keepalive state that owns it. `silhouettes` is doc-parallel to `sketches`
/// when resolved with `.structure`, empty otherwise.
pub const View = struct {
    paths: []const []const u8,
    sketches: []const Sketch,
    silhouettes: []const Silhouette = &.{},
    from_atlas: bool,
    refreshed: usize, // files re-fingerprinted by the freshness fold

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
};

/// Which channels a view must carry: `bytes` = the LZJD sketches only;
/// `structure` = silhouettes too. The atlas persists both, so warm answers
/// carry both either way; the flag only spares the LIVE rung a second pass.
pub const Wants = enum { bytes, structure };

/// Which channels `channel` needs resolved. Only `copies` can answer from the
/// byte sketches alone; every other channel reads the silhouette too.
pub fn wantsOf(channel: Channel) Wants {
    return if (channel == .copies) .bytes else .structure;
}

/// Loading + validating the global atlas has a fixed whole-artifact cost. For
/// a narrow explicit scope, rebuilding a few hundred fingerprints from source is
/// materially cheaper. The mmap-backed trigram path table lets us estimate
/// scope cardinality without walking or reading the scoped corpus first.
fn preferScopedLive(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) bool {
    if (roots.len == 0) return false;
    var persisted = (trigram_persist.loadQuiet(gpa, io) catch return false) orelse return false;
    defer persisted.deinit();
    var scoped: usize = 0;
    for (persisted.paths.items) |path| {
        if (!flags.underAnyRoot(path, roots)) continue;
        scoped += 1;
        if (scoped > 512) return false;
    }
    return true;
}

/// Resolve the cheapest sound file view for `roots` (normalized explicit roots;
/// empty = default). The atlas rung requires every root inside the indexed
/// corpus — an out-of-corpus root has no fingerprints to elide and needs the
/// live read (the same admission rule `patterns` applies to the trigram index).
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, no_index: bool, wants: Wants) !View {
    atlas: {
        if (no_index) break :atlas;
        // Prologue split under the `query` lens. `resolve` is the same work for
        // every kinship question over one tree, so whether its cost sits in the
        // artifact load or in the freshness fold decides what a resident tier
        // could actually elide — a load is paid once and held, a fold is paid
        // per changed file and must be driven by a watcher.
        var phase = assay.Span.open(io);
        if (preferScopedLive(gpa, io, roots)) break :atlas;
        assay.trace(.query, "resolve phase: scope-probe {d:.1} ms\n", .{phase.lap(io).ms()});
        var atl = atlas_mod.loadQuiet(gpa, io) orelse break :atlas;
        assay.trace(.query, "resolve phase: atlas-load {d:.1} ms\n", .{phase.lap(io).ms()});
        // Every queried root must sit inside the roots the atlas was BUILT
        // over (persisted in the blob) — an out-of-corpus root has no
        // fingerprints to elide and needs the live read below.
        for (roots) |r| {
            if (!flags.underAnyRoot(r, atl.roots)) {
                atl.deinit(gpa);
                break :atlas;
            }
        }
        errdefer atl.deinit(gpa);
        // An explicitly scoped query only needs freshness inside that scope.
        // Folding every changed file in a 55k-file atlas before discarding
        // out-of-scope rows made a one-package query pay whole-tree coworker
        // churn.
        var folded = atlas_mod.fold(gpa, io, &atl, if (roots.len > 0) roots else atl.roots) catch {
            atl.deinit(gpa);
            break :atlas;
        };
        errdefer folded.deinit();
        assay.trace(.query, "resolve phase: fold {d:.1} ms ({d} refreshed)\n", .{ phase.lap(io).ms(), folded.refreshed });

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
            for (folded.paths.items) |p| n += @intFromBool(flags.underAnyRoot(p, roots));
            const sp = try gpa.alloc([]const u8, n);
            errdefer gpa.free(sp);
            const ss = try gpa.alloc(Sketch, n);
            errdefer gpa.free(ss);
            const sl = try gpa.alloc(Silhouette, n);
            errdefer gpa.free(sl);
            var w: usize = 0;
            for (folded.paths.items, folded.sketches.items, folded.silhouettes.items) |p, s, sil| {
                if (!flags.underAnyRoot(p, roots)) continue;
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

    // Live rung: read the scoped corpus and fingerprint it in parallel (both
    // channels when the caller asked for structure).
    const rr = try flags.rootsOf(gpa, roots);
    defer rr.deinit(gpa);
    var corpus = try corpus_mod.load(gpa, io, rr.items, .contiguous);
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

// ── the pair machinery ──
// The pure candidate-bucket + exact-verify kernel lives in `pairs.zig`; the
// relate verbs reach it through this hub so their call sites stay stable.

pub const Pair = pairs.Pair;
pub const seed_hashes = pairs.seed_hashes;
pub const bucket_cap = pairs.bucket_cap;
pub const forEachCandidatePair = pairs.forEachCandidatePair;
pub const verifiedPairs = pairs.verifiedPairs;

// ── tests ────────────────────────────────────────────────────────────────

const t = std.testing;

test "only the byte channel can answer from sketches alone" {
    try t.expectEqual(Wants.bytes, wantsOf(.copies));
    try t.expectEqual(Wants.structure, wantsOf(.shapes));
    try t.expectEqual(Wants.structure, wantsOf(.twins));
    try t.expectEqual(Wants.structure, wantsOf(.any));
}

test "an empty record is maximally far from real content — and why the mass floor exists" {
    const gpa = t.allocator;
    var real = try sketch.build(gpa, "fn alpha(items: []Item) usize {\n  return items.len;\n}\n");
    // Against real content the empty record is 1.0: a fingerprint failure can
    // hide a result under a `--max-distance`, never invent one.
    try t.expectEqual(@as(f64, 1.0), sketch.distance(&Sketch.empty, &real));
    // But two empty records share every (absent) fingerprint, which reads as
    // 0.0 — identical. That is exactly why the mass floors withhold sub-mass
    // units from the population instead of trusting the distance.
    try t.expectEqual(@as(f64, 0.0), sketch.distance(&Sketch.empty, &Sketch.empty));
    try t.expectEqual(@as(f64, 0.0), silhouette_mod.distance(&Silhouette.empty, &Silhouette.empty));
    try t.expectEqual(@as(u16, 0), Sketch.empty.len);
}
