//! relate — the `patterns` verb: one walk, N patterns, exact attribution.
//!
//!   relate patterns -e P [-e P…] [-f FILE] [-F] [-i] [--by pattern|file]
//!                 [--under GLOB] [--top N] [--json] [ROOT...]
//!       ONE walk, N patterns, exact per-pattern attribution — the batched
//!       shape relocator/lints re-derive today with N runs + Python. `--by`
//!       groups into counts; `--under`/`--top` shape engine-side (loom).
//!
//! The exact half of relate, and the only verb here that answers with hits
//! rather than with a compression score: the kinship verbs use the same engine
//! as a FILTER (`--matching`), while this one reports the matches themselves.
//! When N patterns are the question, N `gist -l` runs re-walk the tree N times
//! and lose which pattern found what; here the PatternSet nominates once, the
//! read is index-elided when every pattern has a sound trigram prefilter, and
//! each row keeps its pattern id.
//!
//! Corpus policy: the rg-parity file set — byte-for-byte the population `gist
//! -l` answers over, because this verb's whole contract is to replace N `gist
//! -l` runs. It walks through `quarry/walk.zig`'s `defaultFileSet`, the same
//! enumerator the single-pattern engine uses, so ignore parsing, hidden-file
//! precedence, and root scoping are not merely equivalent but literally the
//! same code.
//!
//! That is a deliberate split from the kinship verbs. `similar`/`echoes`/`pack`
//! answer over the INDEX corpus, which additionally prunes the generic
//! VCS/build/vendor basenames (`haystack.isSkipDir`) — right for them, since a
//! vendored tree should not dominate compression statistics. It is wrong here:
//! an EXACT verb that silently drops 76% of a literal's real hits (measured:
//! 145 of 615 files for `graphify`, every one of the 470 missing under
//! `scripts/vendor`) is a trap, not a policy. So the index is demoted to what
//! it is for the search engine — a read-ELISION oracle, never the population.
//! A file absent from the index therefore cannot be elided: it misses the
//! `IndexedPaths` lookup and gets a live read, which is exactly why `gist`,
//! `gist --no-index`, and `rg` already agree.
//!
//! Diagnostics (timing) go to stderr; results to stdout, rg-style.

const std = @import("std");
const portal = @import("../../../portal.zig");
const corpus_mod = @import("../../../corpus/tree/corpus.zig");
const fresh = @import("../../../corpus/fresh/fresh.zig");
const persist = @import("../../../corpus/index/trigrams/persist.zig");
const cli_args = @import("../../../exec/cold/argv/args.zig");
const assay = @import("../../../assay/assay.zig");
const scope = @import("../../../corpus/scope/filter.zig");
const patterns_mod = @import("../../../kernel/slate/patterns.zig");
const loom = @import("../../../kernel/slate/loom.zig");
const elide = @import("../../../exec/cold/quarry/elide.zig");
const walk = @import("../../../exec/cold/quarry/walk.zig");
const ignore = @import("../../../corpus/tree/ignore.zig");
const query = @import("../../../kernel/query/query.zig");
const parallel = @import("../../../kernel/math/parallel.zig");
const flags = @import("../../cli/flags.zig");
const emit = @import("../../cli/emit.zig");
const slurp = @import("../../../corpus/read/slurp.zig");

const die = @import("../../cli/outcome.zig").die;
const oom = @import("../../cli/outcome.zig").oom;

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

const readFileInto = slurp.readFileInto;

/// One worker of the index-backed candidate read+attribute pass: its own file
/// scratch, its own `PatternSet.Scratch` (Pike sim state is not shareable),
/// its own row list. An allocation failure abandons the shard's remainder
/// (same degrade-to-fewer-results posture as `rankShard`).
/// Reads `disk` (the openable path) and attributes under `rel` (the path rg
/// prints), the same pairing the single-pattern engine uses — so an explicit
/// root spells its rows exactly as `gist -l` would.
const AttrShard = struct {
    files: []const walk.Candidate,
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
            if (d >= sh.files.len) continue;
            const f = sh.files[d];
            const n = readFileInto(f.disk, scratch_buf) orelse continue;
            const body = scratch_buf[0..n];
            // The same membership rule the `-l` renderer applies (`emit/render.zig`)
            // and `corpus.readMember` shares: an empty or binary file is not a
            // corpus member, so attributing one would report a file `gist -l`
            // never lists. Caught by `bench/gates/patterns_corpus_parity.sh`,
            // which failed on `cfg` matching inside an .mp4 and a .pt.
            if (body.len == 0 or corpus_mod.isBinary(body)) continue;
            attributeDoc(sh.gpa, sh.set, &sc, body, f.rel, &hits, &sh.rows) catch return;
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
    files: []const walk.Candidate,
    ids: []const u32,
    rows: *std.ArrayList(loom.Row),
) !void {
    if (ids.len == 0) return;
    const ncpu = portal.cpuCount() catch 8;
    const nshards = if (ids.len < 64) 1 else @min(ids.len, ncpu);
    const shards = try gpa.alloc(AttrShard, nshards);
    defer gpa.free(shards);
    defer for (shards) |*sh| sh.rows.deinit(gpa);
    const threads = try gpa.alloc(std.Thread, nshards);
    defer gpa.free(threads);
    const per = (ids.len + nshards - 1) / nshards;
    for (shards, 0..) |*sh, k| {
        const lo = @min(k * per, ids.len);
        sh.* = .{ .files = files, .ids = ids[lo..@min(lo + per, ids.len)], .set = set, .gpa = gpa };
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

    // Population first, elision second — the order that keeps this verb exact.
    // The rg-parity walk decides WHICH files are in scope; a persisted index
    // then only decides which of those need their bytes read. When every
    // pattern yields a sound trigram prefilter and the index covers the roots,
    // an indexed non-candidate whose bytes provably predate the build anchor is
    // skipped; everything else — including every file the index never saw — is
    // read. Never a different answer, only fewer bytes touched.
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

    // The population, decided before any index is consulted: the rg-parity
    // walk, root-scoped by the walk itself (no post-hoc scope gate needed) and
    // costing paths only — no file bytes are read here.
    var walk_arena = std.heap.ArenaAllocator.init(gpa);
    defer walk_arena.deinit();
    const wa = walk_arena.allocator();
    const rr = try flags.rootsOf(gpa, roots.items);
    defer rr.deinit(gpa);
    // A lone "." IS the default corpus, and gist spells that walk with an empty
    // prefix (`gather`'s `roots.len == 0` branch), so its rows read `a/b.zig`
    // and not `./a/b.zig`. Hand `gather` the same empty root list, so the path
    // spelling — and therefore both the index lookup and the printed row — is
    // byte-identical to `gist -l`'s.
    const walk_roots: []const []const u8 =
        if (rr.items.len == 1 and std.mem.eql(u8, rr.items[0], ".")) &.{} else rr.items;
    var files: std.ArrayList(walk.Candidate) = .empty;
    {
        const o: cli_args.Opts = .{};
        var ig = ignore.Ignore.init(wa, io, ignore.Options.from(o), walk_roots) catch oom();
        _ = walk.gather(wa, io, walk_roots, o, &ig, &files, null) catch oom();
    }
    total_files = files.items.len;

    // Read set = every walked file, minus those an index proves both unchanged
    // since its anchor and free of some pattern's required trigrams. A file the
    // index never saw misses the lookup and is read — the property that makes
    // this exact.
    var to_read: std.ArrayList(u32) = .empty;
    defer to_read.deinit(gpa);
    var elided: usize = 0;
    var armed = false; // did the index actually decide the read set?
    elision: {
        var filters: std.ArrayList([]const u8) = .empty;
        defer filters.deinit(gpa);
        for (0..set.len()) |pi| {
            var one: [1][]const u8 = undefined;
            const lits = set.prefilter(pi, &one);
            if (lits.len == 0) break :elision; // this pattern implicates every doc
            try filters.appendSlice(gpa, lits);
        }
        persisted = (persist.loadQuiet(gpa, io) catch null) orelse break :elision;
        const p = &persisted.?;
        // Explicit roots still ride the index when they sit INSIDE the roots it
        // was built over; a root outside them has nothing to elide.
        for (roots.items) |r| {
            if (!flags.underAnyRoot(r, p.roots.items)) break :elision;
        }
        // Snapshot before freshness widens `p.paths` with NEW files: only
        // originally-indexed paths are elision-eligible (intake.zig's lesson).
        const n_indexed = p.paths.items.len;
        cand = try fresh.candidates(gpa, io, p, &p.paths, filters.items, if (roots.items.len > 0) roots.items else p.roots.items);
        // Without a trustworthy anchor no indexed non-candidate is provably
        // unchanged, so nothing may be elided.
        if (!cand.?.anchored) break :elision;
        var candidates = try std.DynamicBitSet.initEmpty(gpa, p.paths.items.len);
        defer candidates.deinit();
        for (cand.?.ids) |d| if (d < p.paths.items.len) candidates.set(d);
        const known = p.paths.items[0..n_indexed];
        var indexed = try elide.IndexedPaths.init(gpa, known);
        defer indexed.deinit();
        try to_read.ensureTotalCapacity(gpa, files.items.len);
        for (files.items, 0..) |f, k| {
            if (indexed.get(known, f.rel)) |doc| if (!candidates.isSet(doc)) {
                elided += 1;
                continue;
            };
            to_read.appendAssumeCapacity(@intCast(k));
        }
        armed = true;
        break :elision;
    }
    if (!armed) {
        try to_read.ensureTotalCapacity(gpa, files.items.len);
        for (0..files.items.len) |k| to_read.appendAssumeCapacity(@intCast(k));
    }
    read_files = to_read.items.len;
    try attributeCandidates(gpa, &set, files.items, to_read.items, &rows);

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
            emit.emitRow(&buf, gpa, json, .{ .{ "path", "s", path }, .{ "line", "d", r.line }, .{ "pattern_id", "d", r.pattern }, .{ "pattern", "s", pats.items[r.pattern] } }, "{s}\t{s}\n", .{ emit.locator(gpa, path, r.line), pats.items[r.pattern] });
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
