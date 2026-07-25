//! relate — the `similar`, `dups`, and `patterns` verbs over irregex primitives.
//!
//! The CLI surface over `src/kernel/{similarity,batch}/`: three native shapes no
//! rg flag can express (like `--rank`, they are irregex vocabulary, not rg's):
//!
//!   relate similar <path> [--lens bytes|structure|fused] [--top N] [--json]
//!                  [--no-index] [ROOT...]
//!       nearest files to <path> by compression kinship — "what else in this
//!       tree is LIKE this file?" The lens picks the distance: `bytes` (LZJD
//!       over raw bytes — vocabulary-true, the default), `structure` (the
//!       silhouette channel — renamed twins surface), or `fused` (min of
//!       both — "close in EITHER channel counts").
//!
//!   relate dups [--max-distance T] [--top N] [--json] [--no-index] [ROOT...]
//!       near-duplicate pairs across the corpus, closest first — copy-paste
//!       drift, forked fixtures, mirrored modules.
//!
//!   relate patterns -e P [-e P…] [-f FILE] [-F] [-i] [--by pattern|file]
//!                 [--under GLOB] [--top N] [--json] [ROOT...]
//!       ONE walk, N patterns, exact per-pattern attribution — the batched
//!       shape relocator/lints re-derive today with N runs + Python. `--by`
//!       groups into counts; `--under`/`--top` shape engine-side (loom).
//!
//! Corpus policy: these verbs answer over the shared index corpus (every
//! non-binary, non-gitignored file under the roots, plus corpus-only VCS/build
//! pruning). The ignore parser and precedence are exactly gist's.
//! The sketch-backed verbs resolve their (paths, sketches) view through
//! `kinship.resolve` — persisted atlas + freshness fold when one is ready,
//! live corpus build otherwise, identical answers either way.
//! Diagnostics (timing) go to stderr; results to stdout, rg-style.

const std = @import("std");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const fresh = @import("../../../corpus/index/trigrams/fresh.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const cli_args = @import("../../exec/cold/argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const scope = @import("../../../corpus/scope/glob.zig");
const sketch = @import("../../../kernel/kinship/metric/sketch.zig");
const silhouette_mod = @import("../../../kernel/kinship/metric/silhouette.zig");
const patterns_mod = @import("../../../kernel/batch/patterns.zig");
const loom = @import("../../../kernel/batch/loom.zig");
const query = @import("../../../kernel/match/query.zig");
const parallel = @import("../../../kernel/primitives/parallel.zig");
const kinship = @import("kinship.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");
const grepfile = @import("../../exec/cold/read/grepfile.zig");

const die = cli_args.die;
const oom = cli_args.oom;

// ── `relate similar` ──

/// One scored neighbor, for the sort.
const Scored = struct {
    dist: f64,
    idx: u32,

    fn less(paths: []const []const u8, x: Scored, y: Scored) bool {
        if (x.dist != y.dist) return x.dist < y.dist;
        return std.mem.order(u8, paths[x.idx], paths[y.idx]) == .lt;
    }
};

pub fn runSimilar(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 20 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{ .no_index = true, .lens = true, .positional = true });
    const target = o.arg orelse die("usage: relate similar <path> [--lens bytes|structure|fused] [--top N] [--json] [--no-index] [ROOT...]\n", .{});

    const run = assay.Run.open(gpa, io, o.json);
    const body = std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(corpus_mod.per_file_cap)) catch |e|
        die("cannot read {s}: {s}\n", .{ target, @errorName(e) });
    defer gpa.free(body);
    var target_sketch = sketch.build(gpa, body) catch oom();
    var target_sil: silhouette_mod.Silhouette = if (o.lens != .bytes) silhouette_mod.build(gpa, body) catch oom() else .empty;

    var view = try kinship.resolve(gpa, io, roots.items, o.no_index, if (o.lens == .bytes) .bytes else .structure);
    defer view.deinit();

    // Self-exclusion compares canonical shapes: a corpus path under an
    // explicit `.` root arrives `./`-prefixed while the arg may not (or vice
    // versa), and byte equality would leave the target ranked first at 0.0.
    const norm_target = flags.stripDotSlash(target);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (view.sketches, 0..) |*s, d| {
        if (std.mem.eql(u8, flags.stripDotSlash(view.paths[d]), norm_target)) continue; // self
        const dist = switch (o.lens) {
            .bytes => sketch.distance(&target_sketch, s),
            .structure => silhouette_mod.distance(&target_sil, &view.silhouettes[d]),
            .fused => @min(
                sketch.distance(&target_sketch, s),
                silhouette_mod.distance(&target_sil, &view.silhouettes[d]),
            ),
        };
        try scored.append(gpa, .{ .dist = dist, .idx = @intCast(d) });
    }
    std.mem.sort(Scored, scored.items, view.paths, Scored.less);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var emitted: usize = 0;
    for (scored.items) |sc| {
        if (emitted >= o.top) break;
        if (!view.gate(sc.idx)) continue; // deleted since the atlas anchor
        emitted += 1;
        emit.emitRow(&buf, gpa, o.json, .{ .{ "path", "s", view.paths[sc.idx] }, .{ "distance", "d:.4", sc.dist } }, "{d:.4}  {s}\n", .{ sc.dist, view.paths[sc.idx] });
    }
    corpus_mod.emitStdout(buf.items);
    const dur = run.elapsed().ms();
    run.emit("similar: {d} sketches ({s}{d} refreshed) · lens {s} · {d:.0} ms\n", .{ view.sketches.len, view.provenance(), view.refreshed, @tagName(o.lens), dur }, .{
        .{ "verb", "s", "similar" },
        .{ "sketches", "d", view.sketches.len },
        .{ "source", "s", view.source() },
        .{ "refreshed", "d", view.refreshed },
        .{ "lens", "s", @tagName(o.lens) },
        .{ "ms", "d:.0", dur },
    });
}

// ── `relate dups` ──

pub fn runDups(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var o: kinship.Opts = .{ .top = 100 };
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    try kinship.parseOpts(gpa, argv, &o, &roots, .{ .max_dist = true, .no_index = true });

    const run = assay.Run.open(gpa, io, o.json);
    var view = try kinship.resolve(gpa, io, roots.items, o.no_index, .bytes);
    defer view.deinit();
    const pairs = try kinship.verifiedPairs(gpa, view.paths, view.sketches, o.max_dist);
    defer gpa.free(pairs);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var emitted: usize = 0;
    for (pairs) |p| {
        if (emitted >= o.top) break;
        if (!view.gate(p.i) or !view.gate(p.j)) continue; // deleted since the anchor
        emitted += 1;
        emit.emitRow(&buf, gpa, o.json, .{ .{ "a", "s", view.paths[p.i] }, .{ "b", "s", view.paths[p.j] }, .{ "distance", "d:.4", p.dist } }, "{d:.4}  {s}  {s}\n", .{ p.dist, view.paths[p.i], view.paths[p.j] });
    }
    corpus_mod.emitStdout(buf.items);
    const dur = run.elapsed().ms();
    run.emit("dups: {d} files ({s}{d} refreshed) · {d} pair(s) ≤ {d:.2} · {d:.0} ms\n", .{ view.paths.len, view.provenance(), view.refreshed, pairs.len, o.max_dist, dur }, .{
        .{ "verb", "s", "dups" },
        .{ "files", "d", view.paths.len },
        .{ "source", "s", view.source() },
        .{ "refreshed", "d", view.refreshed },
        .{ "pairs", "d", pairs.len },
        .{ "max_distance", "d:.2", o.max_dist },
        .{ "ms", "d:.0", dur },
    });
}

// ── `relate patterns` attribution ──

/// Attribute one document's bytes: the gate rejects all-miss docs in a single
/// pass; survivors get exact per-pattern, per-line attribution as loom rows.
/// `path` must outlive the rows (they borrow it).
fn attributeDoc(
    gpa: std.mem.Allocator,
    set: *const patterns_mod.PatternSet,
    sc: *patterns_mod.PatternSet.Scratch,
    doc: []const u8,
    path: []const u8,
    hits: *std.ArrayList(u32),
    rows: *std.ArrayList(loom.Row),
) error{OutOfMemory}!void {
    if (!set.anyMatch(doc, sc)) return;
    var line_no: u32 = 0;
    var rest = doc;
    while (rest.len > 0) {
        const nl = std.mem.findScalar(u8, rest, '\n');
        const end = nl orelse rest.len;
        line_no += 1;
        hits.clearRetainingCapacity();
        try set.lineHits(rest[0..end], sc, gpa, hits);
        for (hits.items) |p| try rows.append(gpa, .{ .pattern = p, .path = path, .line = line_no });
        if (nl == null) break;
        rest = rest[end + 1 ..];
    }
}

const readFileInto = grepfile.readFileInto;

/// One worker of the index-backed candidate read+attribute pass: its own file
/// scratch, its own `PatternSet.Scratch` (Pike sim state is not shareable),
/// its own row list. An allocation failure abandons the shard's remainder
/// (same degrade-to-fewer-results posture as `rankShard`).
const AttrShard = struct {
    paths: []const []const u8,
    ids: []const u32,
    set: *const patterns_mod.PatternSet,
    gpa: std.mem.Allocator,
    rows: std.ArrayList(loom.Row) = .empty,

    fn run(sh: *@This()) void {
        const scratch_buf = sh.gpa.alloc(u8, corpus_mod.per_file_cap) catch return;
        defer sh.gpa.free(scratch_buf);
        var sc = sh.set.scratch(sh.gpa) catch return;
        defer sc.deinit(sh.gpa);
        var hits: std.ArrayList(u32) = .empty;
        defer hits.deinit(sh.gpa);
        for (sh.ids) |d| {
            if (d >= sh.paths.len) continue;
            const n = readFileInto(sh.paths[d], scratch_buf) orelse continue;
            attributeDoc(sh.gpa, sh.set, &sc, scratch_buf[0..n], sh.paths[d], &hits, &sh.rows) catch return;
        }
    }
};

/// Read + attribute candidate `ids` in parallel — one shard per core, blocking
/// posix reads (rank.zig's proven `parallelRank` shape). Shard row lists merge
/// in shard order; loom's total sort downstream makes the output independent
/// of the merge, so parallelism never leaks into results.
fn attributeCandidates(
    gpa: std.mem.Allocator,
    set: *const patterns_mod.PatternSet,
    paths: []const []const u8,
    ids: []const u32,
    rows: *std.ArrayList(loom.Row),
) !void {
    const ncpu = std.Thread.getCpuCount() catch 8;
    const nshards = if (ids.len < 64) 1 else @min(ids.len, ncpu);
    const shards = try gpa.alloc(AttrShard, nshards);
    defer gpa.free(shards);
    defer for (shards) |*sh| sh.rows.deinit(gpa);
    const threads = try gpa.alloc(std.Thread, nshards);
    defer gpa.free(threads);
    const per = (ids.len + nshards - 1) / nshards;
    for (shards, 0..) |*sh, k| {
        const lo = @min(k * per, ids.len);
        sh.* = .{ .paths = paths, .ids = ids[lo..@min(lo + per, ids.len)], .set = set, .gpa = gpa };
    }
    parallel.fanOut(AttrShard, shards, threads, AttrShard.run);
    for (shards) |sh| try rows.appendSlice(gpa, sh.rows.items);
}

pub fn runPatterns(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var pats: std.ArrayList([]const u8) = .empty;
    defer pats.deinit(gpa);
    var fixed = false;
    var icase = false;
    var by: ?loom.Key = null;
    var under: ?[]const u8 = null;
    var top: usize = 0;
    var json = false;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);
    var raw_roots: std.ArrayList([]const u8) = .empty; // argv shape, for emit parity
    defer raw_roots.deinit(gpa);
    var owned_bufs: std.ArrayList([]u8) = .empty; // -f file bodies (pattern lifetime)
    defer {
        for (owned_bufs.items) |o| gpa.free(o);
        owned_bufs.deinit(gpa);
    }

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
            try pats.append(gpa, flags.need(argv, &i, "-e needs a pattern\n"));
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            const buf = std.Io.Dir.cwd().readFileAlloc(io, flags.need(argv, &i, "-f needs a file\n"), gpa, .limited(corpus_mod.per_file_cap)) catch |e|
                die("cannot read pattern file {s}: {s}\n", .{ argv[i], @errorName(e) });
            try owned_bufs.append(gpa, buf);
            var it = std.mem.splitScalar(u8, buf, '\n');
            while (it.next()) |ln| {
                if (it.index == null and ln.len == 0) break; // phantom after trailing \n
                try pats.append(gpa, std.mem.trimEnd(u8, ln, "\r"));
            }
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--fixed-strings")) {
            fixed = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignore-case")) {
            icase = true;
        } else if (std.mem.eql(u8, arg, "--by")) {
            by = std.meta.stringToEnum(loom.Key, flags.need(argv, &i, "--by needs pattern|file\n")) orelse die("--by: pattern or file, not {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--under")) {
            under = flags.need(argv, &i, "--under needs a glob\n");
        } else if (std.mem.eql(u8, arg, "--top")) {
            top = flags.count(argv, &i, "--top");
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            die("relate patterns: unknown flag {s}\n", .{arg});
        } else {
            try raw_roots.append(gpa, arg);
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    if (pats.items.len == 0)
        die("usage: relate patterns -e P [-e P…] [-f FILE] [-F] [-i] [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]\n", .{});

    const run = assay.Run.open(gpa, io, json);
    const specs = gpa.alloc(query.Spec, pats.items.len) catch oom();
    defer gpa.free(specs);
    for (pats.items, specs) |p, *s| s.* = .{ .pattern = p, .fixed = fixed, .ignore_case = icase };
    var set = patterns_mod.PatternSet.compile(gpa, specs) catch |e| switch (e) {
        error.Unsupported => die("a pattern is outside irregex's linear-time syntax (try -F, or simplify)\n", .{}),
        error.OutOfMemory => oom(),
    };
    defer set.deinit(gpa);

    // Candidate source. When every pattern yields a sound trigram prefilter,
    // the search covers the default roots, and a persisted index is loadable,
    // read ONLY the union of per-pattern candidates (the same index-elision
    // the single-pattern engine rides); anything else falls back to the full
    // corpus read — never a different answer, only more bytes touched.
    var rows: std.ArrayList(loom.Row) = .empty;
    defer rows.deinit(gpa);
    var read_files: usize = 0;
    var total_files: usize = 0;
    var persisted: ?persist.Persisted = null;
    defer if (persisted) |*p| p.deinit();
    // Kept alive to the end of the verb: widen() can append arena-owned
    // NEW-file paths to `persisted.paths`, and rows borrow those slices.
    var cand: ?fresh.Candidates = null;
    defer if (cand) |*c| c.deinit();
    var corpus: ?corpus_mod.Corpus = null;
    defer if (corpus) |*c| c.deinit();

    indexed: {
        var filters: std.ArrayList([]const u8) = .empty;
        defer filters.deinit(gpa);
        for (0..set.len()) |pi| {
            var one: [1][]const u8 = undefined;
            const lits = set.prefilter(pi, &one);
            if (lits.len == 0) break :indexed; // this pattern implicates every doc
            try filters.appendSlice(gpa, lits);
        }
        persisted = (persist.loadQuiet(gpa, io) catch null) orelse break :indexed;
        const p = &persisted.?;
        // Explicit roots still ride the index when they sit INSIDE the roots
        // it was built over (persisted beside it); a root outside them has no
        // candidates to elide and needs the live read.
        for (roots.items) |r| {
            if (!flags.underAnyRoot(r, p.roots.items)) break :indexed;
        }
        cand = try fresh.candidates(gpa, io, p, &p.paths, filters.items, if (roots.items.len > 0) roots.items else p.roots.items);
        total_files = p.paths.items.len;

        // Root-scope gate before the read (rank.zig's lesson): without it a
        // `relate patterns … services/ai` would read + attribute the whole
        // indexed corpus and answer out of scope.
        var scoped: std.ArrayList(u32) = .empty;
        defer scoped.deinit(gpa);
        if (roots.items.len == 0) {
            try scoped.appendSlice(gpa, cand.?.ids);
        } else {
            try scoped.ensureTotalCapacity(gpa, cand.?.ids.len);
            for (cand.?.ids) |d| {
                if (d >= p.paths.items.len) continue;
                if (flags.underAnyRoot(p.paths.items[d], roots.items)) scoped.appendAssumeCapacity(d);
            }
        }
        read_files = scoped.items.len;
        try attributeCandidates(gpa, &set, p.paths.items, scoped.items, &rows);
        break :indexed;
    }
    if (persisted == null) {
        const rr = try flags.rootsOf(gpa, roots.items);
        defer rr.deinit(gpa);
        corpus = try corpus_mod.load(gpa, io, rr.items);
        const c = &corpus.?;
        total_files = c.docs.len;
        read_files = c.docs.len;
        var sc = set.scratch(gpa) catch oom();
        defer sc.deinit(gpa);
        var hits: std.ArrayList(u32) = .empty;
        defer hits.deinit(gpa);
        for (c.docs, c.paths) |doc, path|
            try attributeDoc(gpa, &set, &sc, doc, path, &hits, &rows);
    }

    var result = try loom.execute(gpa, .{
        .filter_glob = under,
        .group = by,
        .sort = if (by != null) .count_desc else .path,
        .limit = top,
    }, rows.items, pats.items);
    defer result.deinit(gpa);

    // rg (and the single-pattern gist engine) print each path as the root
    // ARGUMENT verbatim + `/` + relative path — `gist <pat> .` says `./a.py`.
    // The corpus/index layers normalize dot-shaped roots to bare corpus-
    // relative paths (artifacts must be root-shape agnostic), so re-derive
    // the argv shape at emit time; this keeps `relate patterns … ROOT` rows
    // byte-parity with N single-pattern searches over the same ROOT args.
    const emitDot = struct {
        fn f(raw: []const []const u8, norm: []const []const u8, path: []const u8) bool {
            for (raw, norm) |rw, nm| {
                const dotted = std.mem.eql(u8, rw, ".") or std.mem.startsWith(u8, rw, "./");
                if (dotted and flags.underAnyRoot(path, &.{nm})) return true;
            }
            return false;
        }
    }.f;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var shaped: std.ArrayList(u8) = .empty; // scratch for the `./`-prefixed shape
    defer shaped.deinit(gpa);
    switch (result) {
        .rows => |rs| for (rs) |r| {
            const path = blk: {
                if (!emitDot(raw_roots.items, roots.items, r.path)) break :blk r.path;
                shaped.clearRetainingCapacity();
                shaped.print(gpa, "./{s}", .{r.path}) catch oom();
                break :blk shaped.items;
            };
            emit.emitRow(&buf, gpa, json, .{ .{ "path", "s", path }, .{ "line", "d", r.line }, .{ "pattern_id", "d", r.pattern }, .{ "pattern", "s", pats.items[r.pattern] } }, "{s}:{d}\t{s}\n", .{ path, r.line, pats.items[r.pattern] });
        },
        .groups => |gs| for (gs) |g| {
            emit.emitRow(&buf, gpa, json, .{ .{ "label", "s", g.label }, .{ "count", "d", g.count } }, "{d}\t{s}\n", .{ g.count, g.label });
        },
    }
    corpus_mod.emitStdout(buf.items);
    const dur = run.elapsed().ms();
    run.emit("patterns: {d} pattern(s) · {d}/{d} files · {d} row(s) · {d:.0} ms\n", .{ pats.items.len, read_files, total_files, rows.items.len, dur }, .{
        .{ "verb", "s", "patterns" },
        .{ "patterns", "d", pats.items.len },
        .{ "read_files", "d", read_files },
        .{ "total_files", "d", total_files },
        .{ "rows", "d", rows.items.len },
        .{ "ms", "d:.0", dur },
    });
}
