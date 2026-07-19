//! relate — the `similar`, `dups`, and `patterns` verbs over irregex primitives.
//!
//! The CLI surface over `src/search/{similarity,batch}/`: three native shapes no
//! rg flag can express (like `--rank`, they are irregex vocabulary, not rg's):
//!
//!   relate similar <path> [--top N] [--json] [--no-index] [ROOT...]
//!       nearest files to <path> by compression kinship (LZ dictionary
//!       distance) — "what else in this tree is LIKE this file?"
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
//! Corpus policy: these verbs answer over the INDEX corpus (every non-binary
//! file under the roots, minus VCS/build subtrees — `corpus.load`), the same
//! wider-than-gitignore policy `gist index` uses. They are corpus analytics,
//! not per-file greps; the rg-parity walk stays with the search engine.
//! The sketch-backed verbs resolve their (paths, sketches) view through
//! `kinship.resolve` — persisted atlas + freshness fold when one is ready,
//! live corpus build otherwise, identical answers either way.
//! Diagnostics (timing) go to stderr; results to stdout, rg-style.

const std = @import("std");
const corpus_mod = @import("../../corpus/tree/corpus.zig");
const fresh = @import("../../index/trigrams/fresh.zig");
const persist = @import("../../index/trigrams/persist.zig");
const cli_args = @import("../../runtime/cold/argv/args.zig");
const scope = @import("../../corpus/scope/glob.zig");
const sketch = @import("../../search/similarity/sketch.zig");
const patterns_mod = @import("../../search/batch/patterns.zig");
const loom = @import("../../search/batch/loom.zig");
const query = @import("../../search/match/query.zig");
const kinship = @import("kinship.zig");
const grepfile = @import("../../runtime/cold/read/grepfile.zig");

const die = cli_args.die;
const oom = cli_args.oom;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;
const jsonStr = kinship.jsonStr;

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
    var target_path: ?[]const u8 = null;
    var top: usize = 20;
    var json = false;
    var no_index = false;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) die("--top needs a number\n", .{});
            top = std.fmt.parseInt(usize, argv[i], 10) catch die("--top: bad number: {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--no-index")) {
            no_index = true;
        } else if (target_path == null) {
            target_path = arg;
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    const target = target_path orelse die("usage: relate similar <path> [--top N] [--json] [--no-index] [ROOT...]\n", .{});

    const t0 = nowNs(io);
    const body = std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(corpus_mod.per_file_cap)) catch |e|
        die("cannot read {s}: {s}\n", .{ target, @errorName(e) });
    defer gpa.free(body);
    var target_sketch = sketch.build(gpa, body) catch oom();

    var view = try kinship.resolve(gpa, io, roots.items, no_index);
    defer view.deinit();

    // Self-exclusion compares canonical shapes: a corpus path under an
    // explicit `.` root arrives `./`-prefixed while the arg may not (or vice
    // versa), and byte equality would leave the target ranked first at 0.0.
    const norm_target = kinship.stripDotSlash(target);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (view.sketches, 0..) |*s, d| {
        if (std.mem.eql(u8, kinship.stripDotSlash(view.paths[d]), norm_target)) continue; // self
        const dist = sketch.distance(&target_sketch, s);
        try scored.append(gpa, .{ .dist = dist, .idx = @intCast(d) });
    }
    std.mem.sort(Scored, scored.items, view.paths, Scored.less);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var emitted: usize = 0;
    for (scored.items) |sc| {
        if (emitted >= top) break;
        if (!view.gate(sc.idx)) continue; // deleted since the atlas anchor
        emitted += 1;
        if (json) {
            buf.appendSlice(gpa, "{\"path\":") catch oom();
            jsonStr(&buf, gpa, view.paths[sc.idx]);
            buf.print(gpa, ",\"distance\":{d:.4}}}\n", .{sc.dist}) catch oom();
        } else {
            buf.print(gpa, "{d:.4}  {s}\n", .{ sc.dist, view.paths[sc.idx] }) catch oom();
        }
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("similar: {d} sketches ({s}{d} refreshed) · {d:.0} ms\n", .{
        view.sketches.len,
        if (view.from_atlas) "atlas, " else "live, ",
        view.refreshed,
        ms(nowNs(io) - t0),
    });
}

// ── `relate dups` ──

pub fn runDups(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var max_dist: f64 = 0.25;
    var top: usize = 100;
    var json = false;
    var no_index = false;
    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(gpa);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--max-distance")) {
            i += 1;
            if (i >= argv.len) die("--max-distance needs a number in [0,1]\n", .{});
            max_dist = std.fmt.parseFloat(f64, argv[i]) catch die("--max-distance: bad number: {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) die("--top needs a number\n", .{});
            top = std.fmt.parseInt(usize, argv[i], 10) catch die("--top: bad number: {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, arg, "--no-index")) {
            no_index = true;
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }

    const t0 = nowNs(io);
    var view = try kinship.resolve(gpa, io, roots.items, no_index);
    defer view.deinit();
    const pairs = try kinship.verifiedPairs(gpa, view.paths, view.sketches, max_dist);
    defer gpa.free(pairs);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var emitted: usize = 0;
    for (pairs) |p| {
        if (emitted >= top) break;
        if (!view.gate(p.i) or !view.gate(p.j)) continue; // deleted since the anchor
        emitted += 1;
        if (json) {
            buf.appendSlice(gpa, "{\"a\":") catch oom();
            jsonStr(&buf, gpa, view.paths[p.i]);
            buf.appendSlice(gpa, ",\"b\":") catch oom();
            jsonStr(&buf, gpa, view.paths[p.j]);
            buf.print(gpa, ",\"distance\":{d:.4}}}\n", .{p.dist}) catch oom();
        } else {
            buf.print(gpa, "{d:.4}  {s}  {s}\n", .{ p.dist, view.paths[p.i], view.paths[p.j] }) catch oom();
        }
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("dups: {d} files ({s}{d} refreshed) · {d} pair(s) ≤ {d:.2} · {d:.0} ms\n", .{
        view.paths.len,
        if (view.from_atlas) "atlas, " else "live, ",
        view.refreshed,
        pairs.len,
        max_dist,
        ms(nowNs(io) - t0),
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
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
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
    const per = (ids.len + nshards - 1) / nshards;
    var off: usize = 0;
    for (shards) |*sh| {
        const lo = off;
        const hi = @min(off + per, ids.len);
        off = hi;
        sh.* = .{ .paths = paths, .ids = ids[lo..hi], .set = set, .gpa = gpa };
    }
    if (nshards == 1) {
        AttrShard.run(&shards[0]);
    } else {
        const threads = try gpa.alloc(std.Thread, nshards);
        defer gpa.free(threads);
        for (shards, 0..) |*sh, k| threads[k] = try std.Thread.spawn(.{}, AttrShard.run, .{sh});
        for (threads) |t| t.join();
    }
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
    var owned_bufs: std.ArrayList([]u8) = .empty; // -f file bodies (pattern lifetime)
    defer {
        for (owned_bufs.items) |o| gpa.free(o);
        owned_bufs.deinit(gpa);
    }

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--regexp")) {
            i += 1;
            if (i >= argv.len) die("-e needs a pattern\n", .{});
            try pats.append(gpa, argv[i]);
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= argv.len) die("-f needs a file\n", .{});
            const buf = std.Io.Dir.cwd().readFileAlloc(io, argv[i], gpa, .limited(corpus_mod.per_file_cap)) catch |e|
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
            i += 1;
            if (i >= argv.len) die("--by needs pattern|file\n", .{});
            by = std.meta.stringToEnum(loom.Key, argv[i]) orelse die("--by: pattern or file, not {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--under")) {
            i += 1;
            if (i >= argv.len) die("--under needs a glob\n", .{});
            under = argv[i];
        } else if (std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) die("--top needs a number\n", .{});
            top = std.fmt.parseInt(usize, argv[i], 10) catch die("--top: bad number: {s}\n", .{argv[i]});
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            die("relate patterns: unknown flag {s}\n", .{arg});
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    if (pats.items.len == 0)
        die("usage: relate patterns -e P [-e P…] [-f FILE] [-F] [-i] [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]\n", .{});

    const t0 = nowNs(io);
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
        // Explicit roots still ride the index when they sit INSIDE the indexed
        // corpus (`services/ai`, or the default roots verbatim); a root outside
        // it (`docs/`, `.`) has no candidates to elide and needs the live read.
        for (roots.items) |r| {
            if (!kinship.underAnyRoot(r, &corpus_mod.default_roots)) break :indexed;
        }
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
        cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, filters.items, kinship.rootsOf(roots.items));
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
                if (kinship.underAnyRoot(p.paths.items[d], roots.items)) scoped.appendAssumeCapacity(d);
            }
        }
        read_files = scoped.items.len;
        try attributeCandidates(gpa, &set, p.paths.items, scoped.items, &rows);
        break :indexed;
    }
    if (persisted == null) {
        corpus = try corpus_mod.load(gpa, io, kinship.rootsOf(roots.items));
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    switch (result) {
        .rows => |rs| for (rs) |r| {
            if (json) {
                buf.appendSlice(gpa, "{\"path\":") catch oom();
                jsonStr(&buf, gpa, r.path);
                buf.print(gpa, ",\"line\":{d},\"pattern_id\":{d},\"pattern\":", .{ r.line, r.pattern }) catch oom();
                jsonStr(&buf, gpa, pats.items[r.pattern]);
                buf.appendSlice(gpa, "}\n") catch oom();
            } else {
                buf.print(gpa, "{s}:{d}\t{s}\n", .{ r.path, r.line, pats.items[r.pattern] }) catch oom();
            }
        },
        .groups => |gs| for (gs) |g| {
            if (json) {
                buf.appendSlice(gpa, "{\"label\":") catch oom();
                jsonStr(&buf, gpa, g.label);
                buf.print(gpa, ",\"count\":{d}}}\n", .{g.count}) catch oom();
            } else {
                buf.print(gpa, "{d}\t{s}\n", .{ g.count, g.label }) catch oom();
            }
        },
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("patterns: {d} pattern(s) · {d}/{d} files · {d} row(s) · {d:.0} ms\n", .{ pats.items.len, read_files, total_files, rows.items.len, ms(nowNs(io) - t0) });
}
