//! hydra — the `similar`, `dups`, and `patterns` verbs over irregex primitives.
//!
//! The CLI surface over `src/primitives/`: three native shapes no
//! rg flag can express (like `--rank`, they are irregex vocabulary, not rg's):
//!
//!   hydra similar <path> [--top N] [--json] [ROOT...]
//!       nearest files to <path> by compression kinship (LZ dictionary
//!       distance) — "what else in this tree is LIKE this file?"
//!
//!   hydra dups [--max-distance T] [--top N] [--json] [ROOT...]
//!       near-duplicate pairs across the corpus, closest first — copy-paste
//!       drift, forked fixtures, mirrored modules.
//!
//!   hydra patterns -e P [-e P…] [-f FILE] [-F] [-i] [--by pattern|file]
//!                 [--under GLOB] [--top N] [--json] [ROOT...]
//!       ONE walk, N patterns, exact per-pattern attribution — the batched
//!       shape relocator/lints re-derive today with N runs + Python. `--by`
//!       groups into counts; `--under`/`--top` shape engine-side (loom).
//!
//! Corpus policy: these verbs load the INDEX corpus (every non-binary file
//! under the roots, minus VCS/build subtrees — `corpus.load`), the same
//! wider-than-gitignore policy `gist index` uses. They are corpus analytics,
//! not per-file greps; the rg-parity walk stays with the search engine.
//! Diagnostics (timing) go to stderr; results to stdout, rg-style.

const std = @import("std");
const corpus_mod = @import("../../corpus/corpus.zig");
const fresh = @import("../../gist/kernel/index/fresh.zig");
const persist = @import("../../gist/kernel/index/persist.zig");
const cli_args = @import("../../gist/faces/cli/search/argv/args.zig");
const scope = @import("../../scope/glob.zig");
const sketch = @import("../../primitives/sketch.zig");
const patterns_mod = @import("../../primitives/patterns.zig");
const loom = @import("../../primitives/loom.zig");
const query = @import("../../gist/kernel/engine/query.zig");

const die = cli_args.die;
const oom = cli_args.oom;
const nowNs = cli_args.nowNs;
const ms = cli_args.ms;
const Sketch = sketch.Sketch;

// ── shared plumbing ──

/// Positional args → corpus roots (normalized `./x/` → `x`); empty → the
/// index's default roots.
fn rootsOf(positional: []const []const u8) []const []const u8 {
    if (positional.len == 0) return &corpus_mod.default_roots;
    return positional;
}

/// Strip one exact leading `./` — the canonical shape for comparing a user
/// arg against a walk-produced path (never trims `..`).
fn stripDotSlash(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
}

/// Is `path` at, or under, any of `roots`? Empty roots = the whole corpus.
/// The shared `scope/glob.zig` boundary rule: exact file hit, or a directory
/// prefix ending at `/` (so `services` never admits `services_old`).
fn underAnyRoot(path: []const u8, roots: []const []const u8) bool {
    if (roots.len == 0) return true;
    for (roots) |r| if (scope.underRoot(path, std.mem.trimEnd(u8, scope.normalizeRoot(r), "/"))) return true;
    return false;
}

/// Sketch every doc in parallel — byte-balanced shards, one thread per
/// ~4 MiB of corpus (a sketch parse is heavier per byte than SIMD verify).
/// A doc that fails to sketch (OOM under pressure) records `Sketch.empty`,
/// which `distance` treats as maximally far — it can surface in no result,
/// only ever hide one, and the failure is counted on stderr.
fn buildSketches(gpa: std.mem.Allocator, docs: []const []const u8) []Sketch {
    const out = gpa.alloc(Sketch, docs.len) catch oom();
    var total: usize = 0;
    for (docs) |d| total += d.len;

    const ncpu = std.Thread.getCpuCount() catch 1;
    const nthr = @min(@max(@as(usize, 1), total / (4 << 20)), ncpu);
    if (nthr <= 1) {
        var failed: usize = 0;
        for (docs, out) |d, *s| s.* = sketch.build(gpa, d) catch blk: {
            failed += 1;
            break :blk .empty;
        };
        if (failed != 0) std.debug.print("hydra: {d} file(s) failed to sketch (skipped)\n", .{failed});
        return out;
    }

    const Shard = struct {
        docs: []const []const u8,
        out: []Sketch,
        failed: usize = 0,

        fn run(sh: *@This()) void {
            // Each worker allocates its own scratch from the page allocator —
            // no cross-thread contention on the caller's gpa.
            for (sh.docs, sh.out) |d, *s| s.* = sketch.build(std.heap.page_allocator, d) catch blk: {
                sh.failed += 1;
                break :blk .empty;
            };
        }
    };

    // Byte-greedy shard boundaries (same shape as scan/verify.zig).
    const bounds = gpa.alloc(usize, nthr + 1) catch oom();
    defer gpa.free(bounds);
    const target = total / nthr;
    bounds[0] = 0;
    var b: usize = 1;
    var acc: usize = 0;
    for (docs, 0..) |d, i| {
        acc += d.len;
        if (b < nthr and acc >= target * b) {
            bounds[b] = i + 1;
            b += 1;
        }
    }
    while (b <= nthr) : (b += 1) bounds[b] = docs.len;

    const shards = gpa.alloc(Shard, nthr) catch oom();
    defer gpa.free(shards);
    const threads = gpa.alloc(std.Thread, nthr) catch oom();
    defer gpa.free(threads);
    var spawned: usize = 0;
    for (0..nthr) |t| {
        shards[t] = .{ .docs = docs[bounds[t]..bounds[t + 1]], .out = out[bounds[t]..bounds[t + 1]] };
        threads[t] = std.Thread.spawn(.{}, Shard.run, .{&shards[t]}) catch break;
        spawned += 1;
    }
    // A shard whose thread never spawned still needs its slice filled.
    for (spawned..nthr) |t| shards[t].run();
    for (threads[0..spawned]) |t| t.join();
    var failed: usize = 0;
    for (shards) |sh| failed += sh.failed;
    if (failed != 0) std.debug.print("hydra: {d} file(s) failed to sketch (skipped)\n", .{failed});
    return out;
}

/// Append `s` JSON-string-escaped (quotes included).
fn jsonStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) void {
    buf.append(a, '"') catch oom();
    for (s) |c| switch (c) {
        '"' => buf.appendSlice(a, "\\\"") catch oom(),
        '\\' => buf.appendSlice(a, "\\\\") catch oom(),
        '\n' => buf.appendSlice(a, "\\n") catch oom(),
        '\r' => buf.appendSlice(a, "\\r") catch oom(),
        '\t' => buf.appendSlice(a, "\\t") catch oom(),
        else => if (c < 0x20)
            buf.print(a, "\\u{x:0>4}", .{c}) catch oom()
        else
            buf.append(a, c) catch oom(),
    };
    buf.append(a, '"') catch oom();
}

// ── `hydra similar` ──

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
        } else if (target_path == null) {
            target_path = arg;
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    const target = target_path orelse die("usage: hydra similar <path> [--top N] [--json] [ROOT...]\n", .{});

    const t0 = nowNs(io);
    const body = std.Io.Dir.cwd().readFileAlloc(io, target, gpa, .limited(corpus_mod.per_file_cap)) catch |e|
        die("cannot read {s}: {s}\n", .{ target, @errorName(e) });
    defer gpa.free(body);
    var target_sketch = sketch.build(gpa, body) catch oom();

    var corpus = try corpus_mod.load(gpa, io, rootsOf(roots.items));
    defer corpus.deinit();
    const sketches = buildSketches(gpa, corpus.docs);
    defer gpa.free(sketches);

    // Self-exclusion compares canonical shapes: a corpus path under an
    // explicit `.` root arrives `./`-prefixed while the arg may not (or vice
    // versa), and byte equality would leave the target ranked first at 0.0.
    const norm_target = stripDotSlash(target);
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (sketches, 0..) |*s, d| {
        if (std.mem.eql(u8, stripDotSlash(corpus.paths[d]), norm_target)) continue; // self
        const dist = sketch.distance(&target_sketch, s);
        try scored.append(gpa, .{ .dist = dist, .idx = @intCast(d) });
    }
    std.mem.sort(Scored, scored.items, corpus.paths, Scored.less);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n = @min(top, scored.items.len);
    for (scored.items[0..n]) |sc| {
        if (json) {
            buf.appendSlice(gpa, "{\"path\":") catch oom();
            jsonStr(&buf, gpa, corpus.paths[sc.idx]);
            buf.print(gpa, ",\"distance\":{d:.4}}}\n", .{sc.dist}) catch oom();
        } else {
            buf.print(gpa, "{d:.4}  {s}\n", .{ sc.dist, corpus.paths[sc.idx] }) catch oom();
        }
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("similar: {d} files sketched · {d:.0} ms\n", .{ corpus.docs.len, ms(nowNs(io) - t0) });
}

// ── `hydra dups` ──

/// A verified near-duplicate pair (i < j), for the sort.
const Pair = struct {
    dist: f64,
    i: u32,
    j: u32,

    fn less(paths: []const []const u8, x: Pair, y: Pair) bool {
        if (x.dist != y.dist) return x.dist < y.dist;
        const c = std.mem.order(u8, paths[x.i], paths[y.i]);
        if (c != .eq) return c == .lt;
        return std.mem.order(u8, paths[x.j], paths[y.j]) == .lt;
    }
};

/// How many of each sketch's smallest hashes seed the candidate index. Two
/// files at Jaccard ≥ 0.75 share ≥1 of their bottom-16 with probability
/// ~1−0.25¹⁶ ≈ 1; the pairwise verify then rejects false candidates exactly.
const seed_hashes = 16;
/// A hash bucket bigger than this is a degenerate attractor (e.g. thousands
/// of same-boilerplate files); pairing inside it would go quadratic. Its
/// members almost surely share OTHER seed hashes pairwise, so capping costs
/// recall only in adversarial corpora — and never precision.
const bucket_cap = 64;

pub fn runDups(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    var max_dist: f64 = 0.25;
    var top: usize = 100;
    var json = false;
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
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }

    const t0 = nowNs(io);
    var corpus = try corpus_mod.load(gpa, io, rootsOf(roots.items));
    defer corpus.deinit();
    const sketches = buildSketches(gpa, corpus.docs);
    defer gpa.free(sketches);

    // Candidate generation: (seed hash, doc) tuples, sorted; docs sharing a
    // seed hash form a bucket; every in-bucket pair gets an exact verify.
    const Tuple = struct {
        h: u64,
        doc: u32,
        fn less(_: void, x: @This(), y: @This()) bool {
            if (x.h != y.h) return x.h < y.h;
            return x.doc < y.doc;
        }
    };
    var tuples: std.ArrayList(Tuple) = .empty;
    defer tuples.deinit(gpa);
    for (sketches, 0..) |*s, d| {
        const seeds = s.slots()[0..@min(seed_hashes, s.len)];
        for (seeds) |h| try tuples.append(gpa, .{ .h = h, .doc = @intCast(d) });
    }
    std.mem.sort(Tuple, tuples.items, {}, Tuple.less);

    // Verified pairs, deduped via a seen-set keyed on (i,j).
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(gpa);
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(gpa);

    var lo: usize = 0;
    while (lo < tuples.items.len) {
        var hi = lo + 1;
        while (hi < tuples.items.len and tuples.items[hi].h == tuples.items[lo].h) hi += 1;
        const bucket = tuples.items[lo..hi];
        const limit = @min(bucket.len, bucket_cap);
        for (bucket[0..limit], 0..) |x, bi| {
            for (bucket[bi + 1 .. limit]) |y| {
                const a = @min(x.doc, y.doc);
                const z = @max(x.doc, y.doc);
                const key = (@as(u64, a) << 32) | z;
                const entry = try seen.getOrPut(gpa, key);
                if (entry.found_existing) continue;
                const d = sketch.distance(&sketches[a], &sketches[z]);
                if (d <= max_dist) try pairs.append(gpa, .{ .dist = d, .i = a, .j = z });
            }
        }
        lo = hi;
    }
    std.mem.sort(Pair, pairs.items, corpus.paths, Pair.less);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const n = @min(top, pairs.items.len);
    for (pairs.items[0..n]) |p| {
        if (json) {
            buf.appendSlice(gpa, "{\"a\":") catch oom();
            jsonStr(&buf, gpa, corpus.paths[p.i]);
            buf.appendSlice(gpa, ",\"b\":") catch oom();
            jsonStr(&buf, gpa, corpus.paths[p.j]);
            buf.print(gpa, ",\"distance\":{d:.4}}}\n", .{p.dist}) catch oom();
        } else {
            buf.print(gpa, "{d:.4}  {s}  {s}\n", .{ p.dist, corpus.paths[p.i], corpus.paths[p.j] }) catch oom();
        }
    }
    corpus_mod.emitStdout(buf.items);
    std.debug.print("dups: {d} files · {d} pair(s) ≤ {d:.2} · {d:.0} ms\n", .{ corpus.docs.len, pairs.items.len, max_dist, ms(nowNs(io) - t0) });
}

// ── `hydra patterns` attribution ──

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

/// Read one file fully into `scratch` (capped); returns bytes read or null.
fn readFileInto(path: []const u8, scratch: []u8) ?usize {
    const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0) catch return null;
    defer {
        _ = std.posix.system.close(fd);
    }
    var n: usize = 0;
    while (n < scratch.len) {
        const r = std.posix.read(fd, scratch[n..]) catch break;
        if (r == 0) break;
        n += r;
    }
    return n;
}

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
            die("hydra patterns: unknown flag {s}\n", .{arg});
        } else {
            try roots.append(gpa, scope.normalizeRoot(arg));
        }
    }
    if (pats.items.len == 0)
        die("usage: hydra patterns -e P [-e P…] [-f FILE] [-F] [-i] [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]\n", .{});

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
            if (!underAnyRoot(r, &corpus_mod.default_roots)) break :indexed;
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
        cand = try fresh.candidates(gpa, io, &p.idx, &p.paths, filters.items, rootsOf(roots.items));
        total_files = p.paths.items.len;

        // Root-scope gate before the read (rank.zig's lesson): without it a
        // `hydra patterns … services/ai` would read + attribute the whole
        // indexed corpus and answer out of scope.
        var scoped: std.ArrayList(u32) = .empty;
        defer scoped.deinit(gpa);
        if (roots.items.len == 0) {
            try scoped.appendSlice(gpa, cand.?.ids);
        } else {
            try scoped.ensureTotalCapacity(gpa, cand.?.ids.len);
            for (cand.?.ids) |d| {
                if (d >= p.paths.items.len) continue;
                if (underAnyRoot(p.paths.items[d], roots.items)) scoped.appendAssumeCapacity(d);
            }
        }
        read_files = scoped.items.len;
        try attributeCandidates(gpa, &set, p.paths.items, scoped.items, &rows);
        break :indexed;
    }
    if (persisted == null) {
        corpus = try corpus_mod.load(gpa, io, rootsOf(roots.items));
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
