//! gist bench/verify harness.
//!
//!   zig build -Doptimize=ReleaseFast bench  [-- <dirs…>]
//!       Build the index over a real corpus and report load/build cost, index
//!       footprint, and full-pipeline (filter + verify) query latency
//!       percentiles (p50/p95/p99) for a fixed adversarial slate.
//!
//!   zig build -Doptimize=ReleaseFast verify [-- <battery_n> <seed>]
//!       Build the index, then for a fixed slate + `battery_n` random literals
//!       sampled from the corpus, write gist's verified matching-file set per
//!       needle into .local/gist-verify/ plus the EXACT indexed file list. The
//!       sibling `equality.sh` drives `rg` over that identical file set and
//!       diffs — proving the trigram filter has zero false negatives vs rg.
//!
//! The corpus is every non-binary file under the roots (rg-style: NUL byte ⇒
//! binary ⇒ skipped), minus the ignored build/VCS subtrees rg also skips. The
//! run step sets cwd to the repo root so dir + output paths resolve there.

const std = @import("std");
const gist = @import("irregex");
const Span = gist.assay.Span; // the package instrumentation floor: monotonic Span
const verify = gist.verify; // data-parallel candidate verify (scan/verify.zig)
const simd = gist.simd; // SIMD substring `contains` (scan/simd.zig)
const certify = @import("certify.zig");

test {
    // The engine tests moved under `src/` with the code they cover and are wired
    // through `src/root.zig`; the only test still local to the harness is
    // `stats.zig` (bootstrap-CI + Mann-Whitney dominance), so pull it in here.
    std.testing.refAllDecls(@This());
    _ = @import("stats.zig");
}
const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
const Dir = std.Io.Dir;
const serve = gist.commands.serve; // the resident daemon (ADR-352 rung 2.5)
const proto = gist.session.protocol; // the UDS wire codec the client speaks
const net = std.Io.net;

// Curated regex battery (ASCII / byte-oriented, == ripgrep `(?-u)`). Real
// code-search shapes; `{0}` / `{1}` are filled with identifiers sampled live
// from the corpus so each pattern actually exercises true matches.
const fixed_regex = [_][]const u8{
    "func\\s+\\w+\\(",        "return\\s+nil",           "import\\s+\\(",         "[A-Z][a-z]+Error",
    "0x[0-9a-fA-F]+",         "ctx\\s+context",          "\\w+pb\\.\\w+",         "//\\s*TODO",
    "pgxpool\\.\\w+",         "err\\s*!=\\s*nil",        "[a-z]+_[a-z]+",         "func\\s*\\(",
    // line anchors `^` / `$` — proven against `rg (?-u)` per-line semantics.
    "^package\\s+\\w+",       "^import",                 "^func\\s",              "^\\s*//",
    "\\)$",                   "^}$",                     ";$",                    "^$",
    // counted repetition `{n}` / `{n,}` / `{n,m}` + a literal-brace check.
    "[0-9]{4}",               "[a-f0-9]{2,}",            "\\w{3,8}",              "x{2,4}",
    "0x[0-9a-fA-F]{2,}",      "interface\\{\\}",
    // alternation multi-literal prefilter — UNION of each ≥3 branch's candidates
    // (`foo|bar|baz`), and a mixed case where a < 3 branch forces a sound scan.
            "return|continue|break", "func|struct|enum",
    "TODO|FIXME|XXX",         "import\\s+\\(|^package",  "context|errors",        "panic|0x",
    // dense / multi-class shapes — the no-prefilter tail the bit-parallel engine
    // and first-byte skip drive, plus real code idioms across languages.
    "if\\s+err\\s*!=\\s*nil", "const\\s+\\w+\\s*=",      "\\w+\\.\\w+\\(",        "[a-z]+_[a-z]+_[a-z]+",
    "[a-z]+[A-Z]\\w+",        "[0-9a-f]{8}-[0-9a-f]{4}",
};
const regex_templates = [_][]const u8{
    "{0}",     "{0}\\s*\\(", "{0}\\.\\w+", "{0}[0-9]",
    "\\w+{0}", "{0}.*;",     "({0}|{1})",  "{0}\\s*=\\s*\\w+",
    "^{0}",    "{0}$",       "^\\s*{0}",   "{0}\\w{2,4}",
};

const corpus_mod = gist.corpus;
const Corpus = corpus_mod.Corpus;
const load = corpus_mod.load;
const out_dir = gist.home.default_out_dir;

// Fixed adversarial slate: rare symbol, dotted ident, trailing-space keyword,
// 3-byte floor, punctuation grams, guaranteed-absent negatives, a 2-byte needle
// (exercises the <3 full-scan fallback), and a repeated-char pathological case.
const fixed_slate = [_][]const u8{
    "pgxpool",    "context.Context", "func ",   "TODO", "queryLiteral",
    "rate_limit", "zzqxv",           "ctx",     "://",  "func(",
    "return nil", "SELECT",          "import",  "})",   "AAAAAA",
    "goroutine",  "panic(",          "Result<", "def ", ".unwrap()",
};

/// gist's true matching docs for `needle`: trigram filter (len ≥ 3) then a
/// parallel verify, or a parallel full scan fallback (len < 3). The candidate
/// filter is single-threaded (already sub-ms); the verify is where the bytes
/// are, so that is what we fan out.
fn gistMatches(idx: *const Index, corpus: *const Corpus, gpa: std.mem.Allocator, needle: []const u8, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    if (needle.len >= 3) {
        if (idx.queryLiteral(gpa, needle)) |cand| {
            defer gpa.free(cand);
            try verify.parallelVerify(gpa, corpus.docs, cand, needle, out);
            return;
        } else |e| switch (e) {
            error.NeedleTooShort => {},
            else => return e,
        }
    }
    const all = try gpa.alloc(u32, corpus.docs.len);
    defer gpa.free(all);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    try verify.parallelVerify(gpa, corpus.docs, all, needle, out);
}

/// gist's matching docs for a compiled regex: prefilter on the required literal
/// (len ≥ 3) or, for an alternation, the UNION of its branches' cover literals
/// (`foo|bar` ⇒ {foo, bar}); then verify with the NFA, else full scan. Sound:
/// every match contains one of the filter literals, so any matching doc passes
/// the (union of) trigram filter(s).
fn regexMatches(re: *const Regex, sim: *Regex.Sim, idx: *const Index, corpus: *const Corpus, gpa: std.mem.Allocator, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    var one = [_][]const u8{re.required};
    const filters: []const []const u8 = if (re.required.len >= 3) one[0..] else re.alts;
    if (filters.len > 0) {
        if (idx.queryAny(gpa, filters)) |cand| {
            defer gpa.free(cand);
            for (cand) |d| if (re.docMatch(sim, corpus.docs[d])) try out.append(gpa, d);
            return;
        } else |_| {}
    }
    for (corpus.docs, 0..) |doc, d| if (re.docMatch(sim, doc)) try out.append(gpa, @intCast(d));
}

/// Sample a pure identifier ([A-Za-z_][A-Za-z0-9_]{3,11}) from the corpus, to
/// splice into regex templates (no metachars ⇒ safe to embed raw in both engines).
fn sampleIdent(rng: std.Random, corpus: *const Corpus) ?[]const u8 {
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        const doc = corpus.docs[rng.uintLessThan(usize, corpus.docs.len)];
        const len = 4 + rng.uintLessThan(usize, 8);
        if (doc.len <= len) continue;
        const off = rng.uintLessThan(usize, doc.len - len);
        const s = doc[off .. off + len];
        if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) continue;
        var ok = true;
        for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            ok = false;
            break;
        };
        if (ok) return s;
    }
    return null;
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    return sorted[@intFromFloat(@round(idx_f))];
}

fn cmpStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn printCorpusHeader(corpus: *const Corpus, load_ns: u64, idx: *const Index, build_ns: u64) void {
    const idx_bytes = idx.serializedSize();
    std.debug.print("corpus: {d} files · {d:.1} MiB · loaded {d:.0} ms\n", .{
        corpus.docs.len, @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20), ms(load_ns),
    });
    std.debug.print("index:  {d} postings ({d} distinct trigrams) · {d:.1} MiB ({d:.2}x corpus) · built {d:.0} ms ({d:.1} MiB/s)\n\n", .{
        idx.posting_count,
        idx.dir_tri.len,
        @as(f64, @floatFromInt(idx_bytes)) / (1 << 20),
        @as(f64, @floatFromInt(idx_bytes)) / @as(f64, @floatFromInt(@max(corpus.bytes, 1))),
        ms(build_ns),
        (@as(f64, @floatFromInt(corpus.bytes)) / (1 << 20)) / (@as(f64, @floatFromInt(build_ns)) / 1e9),
    });
}

fn runBench(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8) !void {
    std.debug.print("gist bench · abi v{d}\nroots:", .{gist.abi()});
    for (roots) |r| std.debug.print(" {s}", .{r});
    std.debug.print("\n\n", .{});

    const load_sp = Span.open(io);
    var corpus = try load(gpa, io, roots);
    defer corpus.deinit();
    const load_ns: u64 = @intCast(load_sp.read(io).ns());

    const build_sp = Span.open(io);
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    const build_ns: u64 = @intCast(build_sp.read(io).ns());
    printCorpusHeader(&corpus, load_ns, &idx, build_ns);

    // ── persistence: a session pays build ONCE, then warm-starts from disk ──
    try Dir.cwd().createDirPath(io, out_dir);
    const blob = try gpa.alloc(u8, idx.serializedSize());
    defer gpa.free(blob);
    _ = idx.writeInto(blob);
    const write_sp = Span.open(io);
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/index.gist", .data = blob });
    const write_ns: u64 = @intCast(write_sp.read(io).ns());
    const read_sp = Span.open(io);
    const read_bytes = try Dir.cwd().readFileAlloc(io, out_dir ++ "/index.gist", gpa, .unlimited);
    defer gpa.free(read_bytes);
    var loaded = try Index.fromBytes(gpa, read_bytes);
    defer loaded.deinit();
    const load2_ns: u64 = @intCast(read_sp.read(io).ns());
    std.debug.print("persist: {d:.1} MiB · write {d:.0} ms · cold-load {d:.0} ms — warm start is {d:.0}x faster than rebuild ({d:.0} ms)\n\n", .{
        @as(f64, @floatFromInt(blob.len)) / (1 << 20),
        ms(write_ns),
        ms(load2_ns),
        ms(build_ns) / @max(ms(load2_ns), 0.001),
        ms(build_ns),
    });

    std.debug.print("full-pipeline latency (filter + verify → matching files), {d} runs each:\n", .{200});
    std.debug.print("{s:<18} {s:>8} {s:>10} {s:>10} {s:>10}\n", .{ "needle", "files", "p50", "p95", "p99" });
    std.debug.print("{s:-<18} {s:->8} {s:->10} {s:->10} {s:->10}\n", .{ "", "", "", "", "" });

    const runs = 200;
    var samples: [runs]u64 = undefined;
    var matchbuf: std.ArrayList(u32) = .empty;
    defer matchbuf.deinit(gpa);
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);

    for (fixed_slate) |needle| {
        var files: usize = 0;
        for (0..runs) |i| {
            const q = Span.open(io);
            try gistMatches(&idx, &corpus, gpa, needle, &matchbuf);
            samples[i] = @intCast(q.read(io).ns());
            files = matchbuf.items.len;
        }
        std.mem.sort(u64, &samples, {}, comptime std.sort.asc(u64));
        const p50 = percentile(&samples, 0.50);
        std.debug.print("{s:<18} {d:>8} {d:>7.1} us {d:>7.1} us {d:>7.1} us\n", .{
            needle,                                                    files,
            @as(f64, @floatFromInt(p50)) / 1e3,                        @as(f64, @floatFromInt(percentile(&samples, 0.95))) / 1e3,
            @as(f64, @floatFromInt(percentile(&samples, 0.99))) / 1e3,
        });
        var line: [128]u8 = undefined;
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{d}\t{d}\n", .{ needle, p50, files }));
    }
    try Dir.cwd().createDirPath(io, out_dir);
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/bench.csv", .data = csv.items });
}

fn runVerify(gpa: std.mem.Allocator, io: std.Io, battery_n: usize, seed: u64) !void {
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    std.debug.print("gist verify · abi v{d} · battery={d} seed={d}\n", .{ gist.abi(), battery_n, seed });

    var corpus = try load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();
    std.debug.print("corpus: {d} files · {d:.1} MiB\n", .{ corpus.docs.len, @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20) });

    const a = corpus.arena.allocator();
    try Dir.cwd().createDirPath(io, out_dir);

    // Race-free snapshot: corpus files are generated/edited live by coworker
    // agents, so reading a file once for gist's index and again for rg can see
    // two different versions. Dump the EXACT bytes gist indexed and point rg at
    // the snapshot — then any diff is a real semantic disagreement, not a race.
    try Dir.cwd().createDirPath(io, out_dir ++ "/snap");
    const snap_paths = try a.alloc([]const u8, corpus.docs.len);
    for (corpus.docs, 0..) |doc, i| {
        snap_paths[i] = try std.fmt.allocPrint(a, "{s}/snap/{d}", .{ out_dir, i });
        try Dir.cwd().writeFile(io, .{ .sub_path = snap_paths[i], .data = doc });
    }

    // Needle slate: fixed adversarial + random literals sampled from the corpus
    // (each guaranteed to occur ≥ once, exercising the true-positive path).
    var needles: std.ArrayList([]const u8) = .empty;
    for (fixed_slate) |n| try needles.append(a, n);
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var made: usize = 0;
    var attempts: usize = 0;
    while (made < battery_n and attempts < battery_n * 100) : (attempts += 1) {
        const d = rng.uintLessThan(usize, corpus.docs.len);
        const doc = corpus.docs[d];
        const len = 3 + rng.uintLessThan(usize, 14); // 3..16
        if (doc.len <= len) continue;
        const off = rng.uintLessThan(usize, doc.len - len);
        const s = doc[off .. off + len];
        if (std.mem.indexOfScalar(u8, s, '\n') != null) continue;
        // Sample only valid-UTF-8 needles (whole codepoints). gist matches raw
        // bytes; rg matches UTF-8-aware by default, so they coincide exactly on
        // valid text — and a half-codepoint byte string is not a real query.
        if (!std.unicode.utf8ValidateSlice(s)) continue;
        var has_alnum = false;
        for (s) |c| if (std.ascii.isAlphanumeric(c)) {
            has_alnum = true;
            break;
        };
        if (!has_alnum) continue;
        try needles.append(a, try a.dupe(u8, s));
        made += 1;
    }

    // Emit the snapshot file list (NUL-separated) for rg to mirror.
    var list_buf: std.ArrayList(u8) = .empty;
    for (snap_paths) |p| {
        try list_buf.appendSlice(a, p);
        try list_buf.append(a, 0);
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/corpus.list", .data = list_buf.items });

    // needles.txt (one per line) + per-needle sorted matching paths.
    var needles_txt: std.ArrayList(u8) = .empty;
    var matchbuf: std.ArrayList(u32) = .empty;
    defer matchbuf.deinit(gpa);
    var path_buf: std.ArrayList([]const u8) = .empty;

    for (needles.items, 0..) |needle, i| {
        try needles_txt.appendSlice(a, needle);
        try needles_txt.append(a, '\n');

        try gistMatches(&idx, &corpus, gpa, needle, &matchbuf);
        path_buf.clearRetainingCapacity();
        for (matchbuf.items) |d| try path_buf.append(a, snap_paths[d]);
        std.mem.sort([]const u8, path_buf.items, {}, cmpStrings);

        var nbuf: std.ArrayList(u8) = .empty;
        for (path_buf.items) |p| {
            try nbuf.appendSlice(a, p);
            try nbuf.append(a, '\n');
        }
        const fname = try std.fmt.allocPrint(a, "{s}/n{d}.txt", .{ out_dir, i });
        try Dir.cwd().writeFile(io, .{ .sub_path = fname, .data = nbuf.items });
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/needles.txt", .data = needles_txt.items });

    // ── regex battery: fixed shapes + templates filled with sampled idents ──
    var regexes: std.ArrayList([]const u8) = .empty;
    for (fixed_regex) |r| try regexes.append(a, r);
    const re_target: usize = @min(battery_n, 80);
    var rmade: usize = 0;
    var rattempts: usize = 0;
    while (rmade < re_target and rattempts < re_target * 50) : (rattempts += 1) {
        const tmpl = regex_templates[rng.uintLessThan(usize, regex_templates.len)];
        const t0 = sampleIdent(rng, &corpus) orelse continue;
        const t1 = sampleIdent(rng, &corpus) orelse continue;
        var pat: std.ArrayList(u8) = .empty;
        var k: usize = 0;
        while (k < tmpl.len) : (k += 1) {
            if (tmpl[k] == '{' and k + 2 < tmpl.len and tmpl[k + 2] == '}') {
                try pat.appendSlice(a, if (tmpl[k + 1] == '0') t0 else t1);
                k += 2;
            } else try pat.append(a, tmpl[k]);
        }
        try regexes.append(a, pat.items);
        rmade += 1;
    }

    var regexes_txt: std.ArrayList(u8) = .empty;
    for (regexes.items, 0..) |pat, i| {
        try regexes_txt.appendSlice(a, pat);
        try regexes_txt.append(a, '\n');

        var re = Regex.compile(gpa, pat) catch continue; // skip if our parser rejects
        defer re.deinit();
        var sim = try Regex.Sim.init(gpa, &re);
        defer sim.deinit();
        try regexMatches(&re, &sim, &idx, &corpus, gpa, &matchbuf);

        path_buf.clearRetainingCapacity();
        for (matchbuf.items) |d| try path_buf.append(a, snap_paths[d]);
        std.mem.sort([]const u8, path_buf.items, {}, cmpStrings);
        var rbuf: std.ArrayList(u8) = .empty;
        for (path_buf.items) |p| {
            try rbuf.appendSlice(a, p);
            try rbuf.append(a, '\n');
        }
        const fname = try std.fmt.allocPrint(a, "{s}/r{d}.txt", .{ out_dir, i });
        try Dir.cwd().writeFile(io, .{ .sub_path = fname, .data = rbuf.items });
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/regexes.txt", .data = regexes_txt.items });

    std.debug.print("wrote {d} literal needles + {d} regexes + corpus.list → {s}/\nrun bench/equality.sh to diff against rg.\n", .{ needles.items.len, regexes.items.len, out_dir });
}

// ── session mode: the persistent-client → daemon product path (ADR-352 rung 2.5) ──
//
// The `bench` mode above times the in-process engine (no transport, no process
// spawn) — the microsecond ceiling. This mode times the number a REAL long-lived
// client sees: a `gist serve` daemon on its own thread, dialed once over a Unix
// socket, then a slate replayed over that ONE connection so no per-query process
// spawn or index reload is paid. It is the honest product analogue of the
// in-process number — the resident daemon's whole reason to exist — and, unlike
// the in-process path, it rides the freshness barrier: on Linux the inotify
// watcher arms the clean fast path (≈ in-process); on a target without a watcher
// backend every query reconciles, so the p50 here truthfully reports the
// freshness tax rather than hiding it.

const DaemonArgs = struct { gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, socket: []const u8 };

fn daemonThread(args: DaemonArgs) void {
    serve.run(args.gpa, args.io, args.roots, args.socket) catch {};
}

/// Dial the freshly spawned daemon, retrying to absorb the bind/listen race.
fn dialRetry(io: std.Io, socket: []const u8) !net.Stream {
    const ua = try net.UnixAddress.init(socket);
    var attempt: usize = 0;
    while (attempt < 1000) : (attempt += 1) {
        if (ua.connect(io)) |s| return s else |_| {}
        try io.sleep(.fromNanoseconds(10 * std.time.ns_per_ms), .real);
    }
    return error.DaemonNeverCameUp;
}

/// One request/response over the persistent connection; returns the scalar the
/// answer carries — the matched-FILE count in files mode, the daemon's total
/// matching-LINE tally (grep `-c`, via `countLines`) in count mode. `qbytes` is
/// the pre-encoded query frame (constant per needle), so the timed loop pays
/// only the write + daemon answer + read, not re-encoding.
fn sessionQuery(gpa: std.mem.Allocator, fd: std.posix.fd_t, qbytes: []const u8) !usize {
    if (!proto.writeAll(fd, qbytes)) return error.ConnClosed;
    var resp = try proto.recvFrame(gpa, fd);
    defer resp.deinit();
    if (resp.op != .result) return error.Declined;
    const view = try proto.decodeResult(resp.payload());
    var n: usize = 0;
    switch (view) {
        .files => |it0| {
            var it = it0;
            while (try it.next()) |_| n += 1;
        },
        .count => |c| n = @intCast(c), // count mode: the daemon's scalar total
        .lines => {}, // bench probes files + count modes only
    }
    return n;
}

fn runSession(gpa: std.mem.Allocator, io: std.Io) !void {
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    try Dir.cwd().createDirPath(io, out_dir);
    const socket = out_dir ++ "/gistd-bench.sock";
    Dir.cwd().deleteFile(io, socket) catch {};

    std.debug.print("gist session · abi v{d} · persistent client → daemon over {s}\nroots:", .{ gist.abi(), socket });
    for (roots) |r| std.debug.print(" {s}", .{r});
    std.debug.print("\n\n", .{});

    const t = try std.Thread.spawn(.{}, daemonThread, .{DaemonArgs{ .gpa = gpa, .io = io, .roots = roots, .socket = socket }});
    const stream = try dialRetry(io, socket);
    const fd = stream.socket.handle;

    // HELLO → READY handshake (proto-version gate).
    try proto.sendFrame(gpa, fd, .hello, &.{proto.protocol_version});
    {
        var ready = try proto.recvFrame(gpa, fd);
        defer ready.deinit();
        if (ready.op != .ready) return error.HandshakeFailed;
    }

    const warmup = 5;
    const runs = 50;
    std.debug.print("per-query latency over the warm connection (files mode), {d} runs each (+{d} warmup):\n", .{ runs, warmup });
    std.debug.print("{s:<18} {s:>8} {s:>12} {s:>12} {s:>12}\n", .{ "needle", "files", "p50", "p95", "p99" });
    std.debug.print("{s:-<18} {s:->8} {s:->12} {s:->12} {s:->12}\n", .{ "", "", "", "", "" });

    var samples: [runs]u64 = undefined;
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);

    for (fixed_slate) |needle| {
        var qbuf: std.ArrayList(u8) = .empty;
        defer qbuf.deinit(gpa);
        try proto.encodeQuery(&qbuf, gpa, .{ .pattern = needle, .mode = .files, .fixed = true });

        var files: usize = 0;
        for (0..warmup) |_| files = try sessionQuery(gpa, fd, qbuf.items);
        for (0..runs) |i| {
            const q = Span.open(io);
            files = try sessionQuery(gpa, fd, qbuf.items);
            samples[i] = @intCast(q.read(io).ns());
        }
        std.mem.sort(u64, &samples, {}, comptime std.sort.asc(u64));
        const p50 = percentile(&samples, 0.50);
        std.debug.print("{s:<18} {d:>8} {d:>9.1} us {d:>9.1} us {d:>9.1} us\n", .{
            needle,                                                    files,
            @as(f64, @floatFromInt(p50)) / 1e3,                        @as(f64, @floatFromInt(percentile(&samples, 0.95))) / 1e3,
            @as(f64, @floatFromInt(percentile(&samples, 0.99))) / 1e3,
        });
        var line: [128]u8 = undefined;
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{d}\t{d}\n", .{ needle, p50, files }));
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/session.csv", .data = csv.items });
    std.debug.print("\nwrote {s}/session.csv\n", .{out_dir});

    // ── count mode over the SAME warm connection (the -c emit path) ──────────
    // The daemon already speaks `.count` (protocol.encodeCount → the matching-
    // line tally from `countLines`, grep `-c` semantics); replaying the identical
    // slate in count mode lets certify_session.sh pair a warm `-c` p50 with
    // ripgrep-cold `-c` — the count analog of the files lane above. `-c` scans
    // every candidate whole (no first-hit short-circuit), so it is the harder
    // proof the resident-index win holds when per-file work rises. Files-mode
    // stays the GATED headline (session_macro.csv); this is reported, since
    // absolute count latency is box-specific.
    std.debug.print("\nper-query latency over the warm connection (count mode), {d} runs each (+{d} warmup):\n", .{ runs, warmup });
    std.debug.print("{s:<18} {s:>10} {s:>12} {s:>12} {s:>12}\n", .{ "needle", "count", "p50", "p95", "p99" });
    std.debug.print("{s:-<18} {s:->10} {s:->12} {s:->12} {s:->12}\n", .{ "", "", "", "", "" });

    var ccsv: std.ArrayList(u8) = .empty;
    defer ccsv.deinit(gpa);
    for (fixed_slate) |needle| {
        var qbuf: std.ArrayList(u8) = .empty;
        defer qbuf.deinit(gpa);
        try proto.encodeQuery(&qbuf, gpa, .{ .pattern = needle, .mode = .count, .fixed = true });

        var total: usize = 0;
        for (0..warmup) |_| total = try sessionQuery(gpa, fd, qbuf.items);
        for (0..runs) |i| {
            const q = Span.open(io);
            total = try sessionQuery(gpa, fd, qbuf.items);
            samples[i] = @intCast(q.read(io).ns());
        }
        std.mem.sort(u64, &samples, {}, comptime std.sort.asc(u64));
        const p50 = percentile(&samples, 0.50);
        std.debug.print("{s:<18} {d:>10} {d:>9.1} us {d:>9.1} us {d:>9.1} us\n", .{
            needle,                                                    total,
            @as(f64, @floatFromInt(p50)) / 1e3,                        @as(f64, @floatFromInt(percentile(&samples, 0.95))) / 1e3,
            @as(f64, @floatFromInt(percentile(&samples, 0.99))) / 1e3,
        });
        var line: [128]u8 = undefined;
        try ccsv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{d}\t{d}\n", .{ needle, p50, total }));
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/session_count.csv", .data = ccsv.items });
    std.debug.print("wrote {s}/session_count.csv\n", .{out_dir});

    // Clean shutdown: stop the accept loop and join the daemon thread.
    proto.sendFrame(gpa, fd, .shutdown, "") catch {};
    stream.close(io);
    t.join();
}

/// Isolate the scan primitive: single-threaded full-corpus scan with
/// `std.mem.indexOf` vs the SIMD `contains`, per needle length. Proves where
/// (and how much) the SIMD path beats std's naive 2–4 byte `findPosLinear`.
fn runScanBench(gpa: std.mem.Allocator, io: std.Io) !void {
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try load(gpa, io, roots);
    defer corpus.deinit();
    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    std.debug.print("scanbench · {d} files · {d:.1} MiB · single-thread full scan\n", .{ corpus.docs.len, mib });
    std.debug.print("{s:<14} {s:>8} {s:>12} {s:>12} {s:>9}\n", .{ "needle", "len", "std MiB/s", "simd MiB/s", "speedup" });

    const needles = [_][]const u8{ "})", "ctx", "func", "=> ", "import", "context.Context" };
    for (needles) |ndl| {
        var hits_std: usize = 0;
        var sp = Span.open(io);
        for (corpus.docs) |d| {
            if (std.mem.indexOf(u8, d, ndl) != null) hits_std += 1;
        }
        const std_ns: u64 = @intCast(sp.read(io).ns());

        var hits_simd: usize = 0;
        sp = Span.open(io);
        for (corpus.docs) |d| {
            if (simd.contains(d, ndl)) hits_simd += 1;
        }
        const simd_ns: u64 = @intCast(sp.read(io).ns());
        if (hits_std != hits_simd) std.debug.print("  !! disagree on '{s}': std={d} simd={d}\n", .{ ndl, hits_std, hits_simd });

        const std_tp = mib / (ms(std_ns) / 1e3);
        const simd_tp = mib / (ms(simd_ns) / 1e3);
        std.debug.print("{s:<14} {d:>8} {d:>12.0} {d:>12.0} {d:>8.1}x\n", .{ ndl, ndl.len, std_tp, simd_tp, simd_tp / std_tp });
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // argv[0]
    const mode = it.next() orelse "bench";

    if (std.mem.eql(u8, mode, "verify")) {
        const battery_n: usize = if (it.next()) |s| std.fmt.parseInt(usize, s, 10) catch 120 else 120;
        const seed: u64 = if (it.next()) |s| std.fmt.parseInt(u64, s, 10) catch 1 else 1;
        try runVerify(gpa, io, battery_n, seed);
        return;
    }
    if (std.mem.eql(u8, mode, "scanbench")) {
        try runScanBench(gpa, io);
        return;
    }
    if (std.mem.eql(u8, mode, "session")) {
        try runSession(gpa, io);
        return;
    }
    if (std.mem.eql(u8, mode, "certify")) {
        try certify.run(gpa, io);
        return;
    }
    if (std.mem.eql(u8, mode, "flagbench")) {
        // `--gate` makes the regression floors blocking (nonzero exit on breach);
        // every other token is a corpus root, defaulting to the resolved tree.
        var gate = false;
        var froots: std.ArrayList([]const u8) = .empty;
        defer froots.deinit(gpa);
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--gate")) gate = true else try froots.append(gpa, arg);
        }
        var fresolved: ?[]const []const u8 = null;
        defer if (fresolved) |r| corpus_mod.freeRoots(gpa, r);
        const roots: []const []const u8 = if (froots.items.len > 0) froots.items else blk: {
            fresolved = try corpus_mod.resolveRoots(gpa);
            break :blk fresolved.?;
        };
        try @import("flagbench.zig").run(gpa, io, roots, gate);
        return;
    }
    if (std.mem.eql(u8, mode, "sessionprof")) {
        // Owns its own flag/root parsing (`--reps`, `--baseline`, `--gate`), so
        // the iterator is handed over rather than pre-drained.
        try @import("sessionprof.zig").run(gpa, io, &it);
        return;
    }

    // bench mode: remaining args (after the mode token) are roots, if any.
    var roots_list: std.ArrayList([]const u8) = .empty;
    defer roots_list.deinit(gpa);
    if (!std.mem.eql(u8, mode, "bench")) try roots_list.append(gpa, mode); // first token was a root
    while (it.next()) |arg| try roots_list.append(gpa, arg);
    var resolved: ?[]const []const u8 = null;
    defer if (resolved) |r| corpus_mod.freeRoots(gpa, r);
    const roots: []const []const u8 = if (roots_list.items.len > 0) roots_list.items else blk: {
        resolved = try corpus_mod.resolveRoots(gpa);
        break :blk resolved.?;
    };
    try runBench(gpa, io, roots);
}
