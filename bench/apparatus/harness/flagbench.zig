//! gist bench — per-function micro-profiles for the flags agents reach for most:
//! `-i` (ignore-case), `-n` (line-number), `-v` (invert), `-l` (files-with-
//! matches), `-c` (count), `-o` (only-matching), `-w` (word-regexp), and
//! `-r`/`-rn` (replace).
//!
//!   zig build -Doptimize=ReleaseFast flagbench  [-- <dirs…>]  [--gate]
//!
//! Unlike `bench`/`certify` (whole-pipeline, multi-thread), this isolates the
//! ONE hot function each flag adds and times it directly, so an optimization's
//! effect is legible and not drowned by the walk/read/fan-out around it:
//!
//!   * `-i` → `simd.containsCaseless` / `indexOfCaselessPos` (the caseless
//!     required-literal gate) vs the case-sensitive `simd.contains` twin — the
//!     ratio IS the case-insensitivity tax. Correctness is checked against a
//!     scalar caseless oracle over the whole corpus (byte-identical booleans).
//!   * `-n` → integer→decimal formatting of the line number, per emitted line:
//!     `std.fmt.bufPrint("{d}")` (the old path) vs `emit.writeDecimal` (the
//!     specialized itoa). Asserted byte-identical over the sampled distribution
//!     plus the edge values.
//!   * `-v`/`-l`/`-c`/`-o`/`-w`/`-r` → `Emitter.file` in each mode over real
//!     files, MiB/s + cycles/byte. `-v` self-checks vs an independent scalar
//!     invert emit; `-l` (emitPathOnly) and `-c` (bufTally→writeDecimal) — whose
//!     emit hot function this change rewrote — self-check byte-identity vs a
//!     line-hit oracle; `-o`/`-w` are unchanged code the CLI parity suite proves.
//!     `-rn` is not recursion: ripgrep (and gist) parse it as `--replace=n`, so
//!     it shares the `-r` template-expansion path (`expandInto`).
//!   * `--json` → the `rg --json` record encoder (`json.run`) over the whole
//!     corpus: the serial stream the CLI ships, so the per-record hot-path
//!     shaves (`pathData` cache, `writeUint`, `asciiOnly`) are timed in
//!     isolation. Self-checks the emitted `match`-record count against the same
//!     line-hit oracle `-l`/`-c` trust — dropped/duplicated records fail loud.
//!
//! The corpus is the same rg-style non-binary tree `bench` loads, so the line
//! shapes, file sizes, and case distribution are the real agent workload.

const std = @import("std");
const gist = @import("irregex");
const simd = gist.simd;
const Meter = @import("pmu").Meter;

const Regex = gist.regex.Regex;
const Matcher = gist.matcher.Matcher;
const Emitter = gist.emit.Emitter;
const json = gist.emit_json;
const Opts = gist.argv.Opts;

const corpus_mod = gist.corpus;
const Corpus = corpus_mod.Corpus;
const load = corpus_mod.load;
const Dir = std.Io.Dir;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span

/// One measured region: wall-ns and (when the PMU is live) retired cycles over
/// `bytes` of work. `throughput`/`cpb` render the two numbers a scan cares
/// about — MiB/s from the clock, cycles/byte from the counter.
const Sample = struct {
    ns: u64,
    cycles: u64,
    has_pmu: bool,
    bytes: u64,

    fn mibps(self: Sample) f64 {
        const secs = @as(f64, @floatFromInt(self.ns)) / 1e9;
        return (@as(f64, @floatFromInt(self.bytes)) / (1 << 20)) / @max(secs, 1e-12);
    }
    fn cpb(self: Sample) f64 {
        if (!self.has_pmu or self.bytes == 0) return 0;
        return @as(f64, @floatFromInt(self.cycles)) / @as(f64, @floatFromInt(self.bytes));
    }
};

/// A prevent-elision sink: XOR-fold every result byte/bool so the optimizer
/// cannot delete the timed work as dead.
var sink: u64 = 0;

fn splitLines(a: std.mem.Allocator, buf: []const u8) ![]const []const u8 {
    // rg line model (mirrors legible.collectLines): '\n' terminates, a trailing
    // terminator yields no phantom empty line, content after the last '\n' is a line.
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |line| try out.append(a, line);
    if (buf.len == 0 or buf[buf.len - 1] == '\n') _ = out.pop();
    return try out.toOwnedSlice(a);
}

// ─────────────────────────── -i: caseless gate ───────────────────────────

/// A scalar, obviously-correct caseless substring oracle (needle pre-lowered).
fn oracleCaseless(hay: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return true;
    if (needle_lower.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= hay.len) : (i += 1) {
        var ok = true;
        for (hay[i .. i + needle_lower.len], needle_lower) |h, l| {
            if (std.ascii.toLower(h) != l) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

const NeedleSpec = struct { text: []const u8, note: []const u8 };

// Absent needles (full-scan cost) at a range of lengths and anchor case-classes,
// plus a few present ones for the true-positive path. Anchor kind drives the
// caseless gate's per-window ALU cost: an alphabetic anchor needs both case
// spellings compared, a digit/punct anchor folds to itself (one compare).
const caseless_needles = [_]NeedleSpec{
    .{ .text = "zq", .note = "len2 alpha/alpha (absent)" },
    .{ .text = "zqx", .note = "len3 alpha/alpha (absent)" },
    .{ .text = "zqxj", .note = "len4 alpha/alpha (absent)" },
    .{ .text = "zqxjvk", .note = "len6 alpha/alpha (absent)" },
    .{ .text = "zqxjvk4m", .note = "len8 alpha/alpha (absent)" },
    .{ .text = "zqxjvk4m9p3wyb", .note = "len14 alpha/alpha (absent)" },
    .{ .text = "0zqxj9", .note = "len6 digit/digit anchors (absent)" },
    .{ .text = "0qxjvk", .note = "len6 digit/alpha anchors (absent)" },
    .{ .text = ".zqxj)", .note = "len6 punct/punct anchors (absent)" },
    .{ .text = "function", .note = "len8 alpha/alpha (present)" },
    .{ .text = "return", .note = "len6 alpha/alpha (present)" },
    .{ .text = "context", .note = "len7 alpha/alpha (present)" },
};

/// Returns the WORST-case case-insensitivity tax (max cs÷ci over the needles) —
/// the number the `-i` regression floor bounds.
fn profileCaseless(io: std.Io, meter: *Meter, corpus: *const Corpus) !f64 {
    std.debug.print("\n── -i  caseless required-literal gate (simd.containsCaseless) ──\n", .{});
    std.debug.print("{s:<32} {s:>10} {s:>12} {s:>12} {s:>8} {s:>10}\n", .{ "needle", "cs MiB/s", "ci MiB/s", "ci cyc/byte", "tax", "hits" });

    var worst_tax: f64 = 0;
    var lower_buf: [64]u8 = undefined;
    for (caseless_needles) |spec| {
        const n = spec.text;
        const low = lower_buf[0..n.len];
        for (n, 0..) |c, i| low[i] = std.ascii.toLower(c);

        // Correctness: the SIMD caseless gate must agree with the scalar oracle
        // on every file (byte-identical boolean), independent of timing.
        for (corpus.docs) |d| {
            if (simd.containsCaseless(d, low) != oracleCaseless(d, low))
                std.debug.panic("caseless disagree on '{s}'", .{n});
        }

        // A single corpus pass is ~200µs — below stable clock resolution — so
        // repeat each scan `reps` times and take the BEST (min-time ⇒ peak,
        // least-noise) pass. Setup is paid per pass, exactly as in production.
        const reps = 200;

        // Case-sensitive twin (the -i tax denominator).
        var cs = Sample{ .ns = std.math.maxInt(u64), .cycles = 0, .has_pmu = false, .bytes = corpus.bytes };
        for (0..reps) |_| {
            const sp = Span.open(io);
            const c0 = meter.counters();
            var hits_cs: usize = 0;
            for (corpus.docs) |d| hits_cs += @intFromBool(simd.contains(d, low));
            const c1 = meter.counters();
            sink +%= hits_cs;
            const ns: u64 = @intCast(sp.read(io).ns());
            if (ns < cs.ns) cs = .{ .ns = ns, .cycles = c1.cycles -% c0.cycles, .has_pmu = c0.valid and c1.valid, .bytes = corpus.bytes };
        }

        // Caseless (the -i path).
        var ci = Sample{ .ns = std.math.maxInt(u64), .cycles = 0, .has_pmu = false, .bytes = corpus.bytes };
        var hits_ci: usize = 0;
        for (0..reps) |_| {
            const sp = Span.open(io);
            const c0 = meter.counters();
            hits_ci = 0;
            for (corpus.docs) |d| hits_ci += @intFromBool(simd.containsCaseless(d, low));
            const c1 = meter.counters();
            sink +%= hits_ci;
            const ns: u64 = @intCast(sp.read(io).ns());
            if (ns < ci.ns) ci = .{ .ns = ns, .cycles = c1.cycles -% c0.cycles, .has_pmu = c0.valid and c1.valid, .bytes = corpus.bytes };
        }

        const tax = cs.mibps() / @max(ci.mibps(), 1e-9);
        worst_tax = @max(worst_tax, tax);
        std.debug.print("{s:<32} {d:>10.0} {d:>12.0} {d:>12.3} {d:>7.2}x {d:>10}\n", .{
            spec.note, cs.mibps(), ci.mibps(), ci.cpb(), tax, hits_ci,
        });
    }
    return worst_tax;
}

// ─────────────────────────── -n: line-number itoa ───────────────────────────

/// Returns `writeDecimal ÷ std.fmt` throughput speedup — the `-n` floor's number.
fn profileLineNum(gpa: std.mem.Allocator, io: std.Io, meter: *Meter, corpus: *const Corpus) !f64 {
    std.debug.print("\n── -n  line-number integer→decimal (per emitted line) ──\n", .{});

    // Correctness: writeDecimal is byte-identical to `{d}` over edges + the
    // whole sampled range.
    const edges = [_]usize{ 0, 1, 9, 10, 11, 99, 100, 999, 1000, 65535, 100000, 4294967295, std.math.maxInt(usize) };
    var fbuf: [24]u8 = undefined;
    var wbuf: [24]u8 = undefined;
    for (edges) |v| {
        const f = try std.fmt.bufPrint(&fbuf, "{d}", .{v});
        const w = gist.emit.writeDecimal(&wbuf, v);
        if (!std.mem.eql(u8, f, w)) std.debug.panic("writeDecimal != fmt for {d}: '{s}' vs '{s}'", .{ v, f, w });
    }

    // The realistic distribution: sample a real file, then a real line index in
    // it — the true magnitude spread of line numbers an agent's search prints.
    const N = 2_000_000;
    var prng = std.Random.DefaultPrng.init(0xF1A6);
    const rng = prng.random();
    const nums = try gpa.alloc(u32, N);
    defer gpa.free(nums);
    for (nums) |*x| {
        const d = corpus.docs[rng.uintLessThan(usize, corpus.docs.len)];
        const nl = std.mem.count(u8, d, "\n") + 1;
        x.* = @intCast(1 + rng.uintLessThan(usize, nl));
    }

    // Byte-identity across the full sample, then time each path.
    for (nums) |v| {
        const f = try std.fmt.bufPrint(&fbuf, "{d}", .{v});
        const w = gist.emit.writeDecimal(&wbuf, v);
        if (!std.mem.eql(u8, f, w)) std.debug.panic("writeDecimal != fmt for {d}", .{v});
    }

    var sp = Span.open(io);
    var c0 = meter.counters();
    var acc: u64 = 0;
    for (nums) |v| {
        const f = try std.fmt.bufPrint(&fbuf, "{d}", .{v});
        acc +%= f.len +% fbuf[0];
    }
    var c1 = meter.counters();
    const fmt = Sample{ .ns = @intCast(sp.read(io).ns()), .cycles = c1.cycles -% c0.cycles, .has_pmu = c0.valid and c1.valid, .bytes = N };
    sink +%= acc;

    sp = Span.open(io);
    c0 = meter.counters();
    acc = 0;
    for (nums) |v| {
        const w = gist.emit.writeDecimal(&wbuf, v);
        acc +%= w.len +% wbuf[0];
    }
    c1 = meter.counters();
    const wd = Sample{ .ns = @intCast(sp.read(io).ns()), .cycles = c1.cycles -% c0.cycles, .has_pmu = c0.valid and c1.valid, .bytes = N };
    sink +%= acc;

    const fmt_mps = @as(f64, @floatFromInt(N)) / (@as(f64, @floatFromInt(fmt.ns)) / 1e9) / 1e6;
    const wd_mps = @as(f64, @floatFromInt(N)) / (@as(f64, @floatFromInt(wd.ns)) / 1e9) / 1e6;
    std.debug.print("{s:<24} {s:>14} {s:>14} {s:>10}\n", .{ "path", "M nums/s", "ns/num", "cyc/num" });
    std.debug.print("{s:<24} {d:>14.1} {d:>14.2} {d:>10.2}\n", .{ "std.fmt {d}", fmt_mps, @as(f64, @floatFromInt(fmt.ns)) / N, if (fmt.has_pmu) @as(f64, @floatFromInt(fmt.cycles)) / N else 0 });
    std.debug.print("{s:<24} {d:>14.1} {d:>14.2} {d:>10.2}\n", .{ "writeDecimal", wd_mps, @as(f64, @floatFromInt(wd.ns)) / N, if (wd.has_pmu) @as(f64, @floatFromInt(wd.cycles)) / N else 0 });
    const speedup = wd_mps / @max(fmt_mps, 1e-9);
    std.debug.print("speedup: {d:.2}x\n", .{speedup});
    return speedup;
}

// ─────────────────── shared emit-path profiling (-v/-l/-c/-o/-w/-r) ───────────────────
//
// Every "emit" flag routes through one `Emitter.file` over a file's split lines;
// what differs is the mode bit in `Opts` and the ONE hot function it lights up.
// These helpers time that path over the real corpus, best-of-N, so each flag's
// throughput is legible and floorable.

/// The emit-mode needle set: common code tokens spanning selectivity (moderately
/// rare `func` … ubiquitous `the`), so a mode's floor sees both the short-circuit
/// and the every-line extremes.
const emit_needles = [_][]const u8{ "func", "return", "err", "the" };

/// Split every corpus doc into rg-model lines once (setup, untimed). Caller frees.
fn splitCorpus(gpa: std.mem.Allocator, corpus: *const Corpus) ![][]const []const u8 {
    const per = try gpa.alloc([]const []const u8, corpus.docs.len);
    for (corpus.docs, 0..) |d, i| per[i] = try splitLines(gpa, d);
    return per;
}

fn freePer(gpa: std.mem.Allocator, per: [][]const []const u8) void {
    for (per) |ls| gpa.free(ls);
    gpa.free(per);
}

/// Reference matching-line count for a file (independent of the Emitter) — the
/// oracle behind the `-l`/`-c` byte-identity self-checks.
fn refLineHits(a: std.mem.Allocator, m: *const Matcher, lines: []const []const u8) !usize {
    var sim = try Matcher.Sim.init(a, m);
    defer sim.deinit();
    var n: usize = 0;
    for (lines) |line| n += @intFromBool(m.lineMatch(&sim, line));
    return n;
}

/// Best-of-`reps` full-corpus pass through `Emitter.file` in mode `o`, returning
/// the min-time (least-noise) Sample and — via out-params — the emitted byte
/// total and matching-file count. Production-faithful: one reused boolean `sim`
/// (the Emitter contract — file-agnostic, amortized across files), an optional
/// `-r` capture matcher, the required-literal gate when the pattern exposes one,
/// and a per-file arena reset bounding the render buffer exactly as the parallel
/// engine's per-file scratch does. `sim`/`caps` come from a STABLE allocator —
/// never the reset arena, whose memory the next file reclaims.
fn emitBest(io: std.Io, meter: *Meter, work: *std.heap.ArenaAllocator, m: *const Matcher, o: Opts, sim: *Matcher.Sim, caps: ?*gist.captures.Caps, per: []const []const []const u8, corpus: *const Corpus, reps: usize, out_bytes: *u64, files_with: *usize) Sample {
    const a = work.allocator();
    const gate: ?simd.Gate = if (m.required().len > 0) .of(m.required()) else null;
    var s = Sample{ .ns = std.math.maxInt(u64), .cycles = 0, .has_pmu = false, .bytes = corpus.bytes };
    for (0..reps) |_| {
        out_bytes.* = 0;
        files_with.* = 0;
        const sp = Span.open(io);
        const c0 = meter.counters();
        for (per, 0..) |lines, i| {
            _ = work.reset(.retain_capacity);
            var eout: std.ArrayList(u8) = .empty;
            var em = Emitter{ .a = a, .re = m, .o = o, .show_name = false, .out = &eout, .base = @intFromPtr(corpus.docs[i].ptr), .needle = gate, .sim = sim, .caps = caps };
            const hits = em.file("f", lines);
            out_bytes.* += eout.items.len;
            if (hits > 0) files_with.* += 1;
            sink +%= eout.items.len;
        }
        const c1 = meter.counters();
        const ns: u64 = @intCast(sp.read(io).ns());
        if (ns < s.ns) s = .{ .ns = ns, .cycles = c1.cycles -% c0.cycles, .has_pmu = c0.valid and c1.valid, .bytes = corpus.bytes };
    }
    return s;
}

fn emitHeader(label: []const u8) void {
    std.debug.print("\n── {s} ──\n", .{label});
    std.debug.print("{s:<20} {s:>12} {s:>12} {s:>10} {s:>12}\n", .{ "needle", "MiB/s", "cyc/byte", "out MiB", "files" });
}

// ─────────────────────────── -v: invert emit ───────────────────────────

/// Independent reference for the simple invert frame (no context / column):
/// emit `<lineno><sep><line><term>` for every line that does NOT match. Proves
/// `Emitter.file` invert output byte-for-byte without trusting the emitter.
fn refInvert(a: std.mem.Allocator, out: *std.ArrayList(u8), m: *const Matcher, o: Opts, lines: []const []const u8) !void {
    var sim = try Matcher.Sim.init(a, m);
    defer sim.deinit();
    var emitted: usize = 0;
    for (lines, 0..) |line, k| {
        const hit = m.lineMatch(&sim, line);
        if (hit) continue; // invert: skip matching lines
        if (o.line_num) {
            var b: [24]u8 = undefined;
            try out.appendSlice(a, try std.fmt.bufPrint(&b, "{d}", .{k + 1}));
            try out.append(a, ':');
        }
        try out.appendSlice(a, line);
        try out.append(a, '\n');
        emitted += 1;
        if (o.max_per_file != 0 and emitted >= o.max_per_file) break;
    }
}

/// Returns the SLOWEST invert-emit throughput (min MiB/s over the needles) — the
/// number the `-v` absolute floor guards against a catastrophic regression.
fn profileInvert(gpa: std.mem.Allocator, io: std.Io, meter: *Meter, corpus: *const Corpus) !f64 {
    emitHeader("-v  invert-match emit (Emitter.file → invertPlain)");
    const o = Opts{ .invert = true, .line_num = true };
    var slowest: f64 = std.math.floatMax(f64);
    for (emit_needles) |ndl| {
        var m = Matcher{ .linear = Regex.compile(gpa, ndl) catch continue };
        defer m.deinit();
        var sim = try Matcher.Sim.init(gpa, &m);
        defer sim.deinit();
        const per = try splitCorpus(gpa, corpus);
        defer freePer(gpa, per);

        // Self-check: emitter invert output == independent reference, on a
        // spread of files (first, middle, last).
        for ([_]usize{ 0, corpus.docs.len / 2, corpus.docs.len - 1 }) |ci| {
            var eout: std.ArrayList(u8) = .empty;
            defer eout.deinit(gpa);
            var em = Emitter{ .a = gpa, .re = &m, .o = o, .show_name = false, .out = &eout, .base = @intFromPtr(corpus.docs[ci].ptr), .needle = if (m.required().len > 0) .of(m.required()) else null, .sim = &sim };
            _ = em.file("f", per[ci]);
            var rout: std.ArrayList(u8) = .empty;
            defer rout.deinit(gpa);
            try refInvert(gpa, &rout, &m, o, per[ci]);
            if (!std.mem.eql(u8, eout.items, rout.items))
                std.debug.panic("invert emit != reference on doc {d} needle '{s}'", .{ ci, ndl });
        }

        var work = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer work.deinit();
        var out_bytes: u64 = 0;
        var files_with: usize = 0;
        const s = emitBest(io, meter, &work, &m, o, &sim, null, per, corpus, 40, &out_bytes, &files_with);
        slowest = @min(slowest, s.mibps());
        std.debug.print("{s:<20} {d:>12.0} {d:>12.3} {d:>10.1} {d:>12}\n", .{ ndl, s.mibps(), s.cpb(), @as(f64, @floatFromInt(out_bytes)) / (1 << 20), files_with });
    }
    return if (slowest == std.math.floatMax(f64)) 0 else slowest;
}

// ─────────────────── -l / -c / -o / -w: the other emit modes ───────────────────

/// Which emit function this change touched — so its byte-identity is self-checked
/// as it profiles. `-l` (emitPathOnly) and `-c` (bufTally→writeDecimal) got
/// hot-path rewrites here; `-o`/`-w` are unchanged code the CLI parity suite
/// (rgsuite + matrix.py) already proves byte-for-byte, so they profile only.
const EmitCheck = enum { none, files, count };

/// Profile one Emitter emit mode over the corpus, returning its SLOWEST
/// per-needle throughput (MiB/s) — the floor's number.
fn profileEmitMode(gpa: std.mem.Allocator, io: std.Io, meter: *Meter, corpus: *const Corpus, label: []const u8, o: Opts, check: EmitCheck) !f64 {
    emitHeader(label);
    var slowest: f64 = std.math.floatMax(f64);
    for (emit_needles) |ndl| {
        var m = Matcher{ .linear = Regex.compile(gpa, ndl) catch continue };
        defer m.deinit();
        var sim = try Matcher.Sim.init(gpa, &m);
        defer sim.deinit();
        const per = try splitCorpus(gpa, corpus);
        defer freePer(gpa, per);

        if (check != .none) {
            const gate: ?simd.Gate = if (m.required().len > 0) .of(m.required()) else null;
            for ([_]usize{ 0, corpus.docs.len / 2, corpus.docs.len - 1 }) |ci| {
                var eout: std.ArrayList(u8) = .empty;
                defer eout.deinit(gpa);
                var em = Emitter{ .a = gpa, .re = &m, .o = o, .show_name = false, .out = &eout, .base = @intFromPtr(corpus.docs[ci].ptr), .needle = gate, .sim = &sim };
                _ = em.file("f", per[ci]);
                const want_hits = try refLineHits(gpa, &m, per[ci]);
                var wbuf: [24]u8 = undefined;
                const want: []const u8 = switch (check) {
                    .files => if (want_hits > 0) "f\n" else "",
                    .count => if (want_hits > 0) try std.fmt.bufPrint(&wbuf, "{d}\n", .{want_hits}) else "",
                    .none => unreachable,
                };
                if (!std.mem.eql(u8, eout.items, want))
                    std.debug.panic("{s} emit != reference on doc {d} needle '{s}': '{s}' vs '{s}'", .{ label, ci, ndl, eout.items, want });
            }
        }

        var work = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer work.deinit();
        var out_bytes: u64 = 0;
        var files_with: usize = 0;
        const s = emitBest(io, meter, &work, &m, o, &sim, null, per, corpus, 40, &out_bytes, &files_with);
        slowest = @min(slowest, s.mibps());
        std.debug.print("{s:<20} {d:>12.0} {d:>12.3} {d:>10.1} {d:>12}\n", .{ ndl, s.mibps(), s.cpb(), @as(f64, @floatFromInt(out_bytes)) / (1 << 20), files_with });
    }
    return if (slowest == std.math.floatMax(f64)) 0 else slowest;
}

// ─────────────────────────── -r / -rn: replace emit ───────────────────────────

/// Profile the `-r`/`--replace` emit — the real path behind grep-muscle-memory
/// `-rn` (ripgrep, and gist, parse `-rn` as `--replace=n`, not recursion). The
/// `<<<$0>>>` template exercises the batched-literal `expandInto` (long literal
/// runs bracketing a group ref). Byte-identity of the replace frame is the CLI
/// parity suite's job (rgsuite/matrix.py); this measures throughput + floors it.
fn profileReplace(gpa: std.mem.Allocator, io: std.Io, meter: *Meter, corpus: *const Corpus) !f64 {
    emitHeader("-r/-rn  replace emit (Emitter.file → expandInto)");
    const o = Opts{ .replace = "<<<$0>>>", .line_num = true };
    var slowest: f64 = std.math.floatMax(f64);
    for (emit_needles) |ndl| {
        var m = Matcher{ .linear = Regex.compile(gpa, ndl) catch continue };
        defer m.deinit();
        var caps = gist.captures.Caps{ .linear = gist.captures.Captures.compile(gpa, ndl, false, true) catch continue };
        defer caps.deinit();
        var sim = try Matcher.Sim.init(gpa, &m);
        defer sim.deinit();
        const per = try splitCorpus(gpa, corpus);
        defer freePer(gpa, per);

        var work = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer work.deinit();
        var out_bytes: u64 = 0;
        var files_with: usize = 0;
        const s = emitBest(io, meter, &work, &m, o, &sim, &caps, per, corpus, 40, &out_bytes, &files_with);
        slowest = @min(slowest, s.mibps());
        std.debug.print("{s:<20} {d:>12.0} {d:>12.3} {d:>10.1} {d:>12}\n", .{ ndl, s.mibps(), s.cpb(), @as(f64, @floatFromInt(out_bytes)) / (1 << 20), files_with });
    }
    return if (slowest == std.math.floatMax(f64)) 0 else slowest;
}

// ─────────────────────────── --json: record-stream emit ───────────────────────────

/// Count `match` records in a `--json` stream — the independent oracle behind the
/// emit self-check. rg's record head is `{"type":"match",…` for a matching line
/// and `{"type":"context",…`/`{"type":"begin",…` otherwise, so counting the
/// `"type":"match"` heads is exactly the matched-line total (non-inverted, no
/// context), which must equal `refLineHits` summed over the files.
fn countJsonMatchRecords(stream: []const u8) usize {
    return std.mem.count(u8, stream, "{\"type\":\"match\"");
}

/// Profile the `--json` record encoder over the whole corpus, returning its
/// SLOWEST per-needle throughput (MiB/s of bytes searched) — the `--json`
/// floor's number. Times the PUBLIC per-file core `json.emitOne` (one `begin`/
/// records/`end` per file, no cross-file summary or output budget), the exact
/// encoder every serial/shard/walk path shares, so the per-record hot-path shaves
/// (`pathData` cache, `writeUint`, `asciiOnly`) are timed in isolation from the
/// walk/read/fan-out. Production-faithful: one reused `SpanSim` (the shard
/// contract), the required-literal gate when the pattern exposes one, and a
/// per-rep arena reset bounding the render buffers exactly as the query arena
/// does. Correctness: on a spread of files the emitted `match`-record count
/// equals the independent per-line-hit oracle, proving the rewrite still emits
/// exactly one record per matching line — no dropped/duplicated record.
fn profileJson(gpa: std.mem.Allocator, io: std.Io, meter: *Meter, corpus: *const Corpus) !f64 {
    emitHeader("--json  record-stream emit (json.emitOne → pathData/writeUint/asciiOnly)");
    // The File set is built once (untimed): synthetic path, real doc bytes.
    const files = try gpa.alloc(json.File, corpus.docs.len);
    defer gpa.free(files);
    for (corpus.docs, 0..) |d, i| files[i] = .{ .path = "f", .body = d };

    const o = Opts{ .mode = .json };
    var slowest: f64 = std.math.floatMax(f64);
    for (emit_needles) |ndl| {
        var m = Matcher{ .linear = Regex.compile(gpa, ndl) catch continue };
        defer m.deinit();
        const gate: ?simd.Gate = if (m.required().len > 0) .of(m.required()) else null;
        const per = try splitCorpus(gpa, corpus);
        defer freePer(gpa, per);

        // Self-check on a spread of files (first, middle, last): the per-file
        // encoder's `match`-record count == the independent line-hit oracle. Each
        // file's stream is small (well under the cross-file output cap the whole-
        // corpus stream would hit), so this is a clean drop/duplicate detector;
        // byte-identity of the record shape is the CLI parity suite's job.
        for ([_]usize{ 0, corpus.docs.len / 2, corpus.docs.len - 1 }) |ci| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var ss = try Matcher.SpanSim.init(gpa, &m);
            defer ss.deinit();
            var st = json.Stats{};
            json.emitOne(gpa, &out, &m, &ss, null, o, files[ci], &st, gate);
            const got = countJsonMatchRecords(out.items);
            const want = try refLineHits(gpa, &m, per[ci]);
            if (got != want)
                std.debug.panic("--json match records {d} != line-hit oracle {d} on doc {d} needle '{s}'", .{ got, want, ci, ndl });
        }

        // Throughput: best-of-N per-file `emitOne` sweep over the whole corpus into
        // a per-rep-reset arena (one reused SpanSim, as a shard reuses one).
        var work = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer work.deinit();
        var s = Sample{ .ns = std.math.maxInt(u64), .cycles = 0, .has_pmu = false, .bytes = corpus.bytes };
        var out_bytes: u64 = 0;
        var files_with: usize = 0;
        for (0..40) |_| {
            _ = work.reset(.retain_capacity);
            const a = work.allocator();
            var ss = try Matcher.SpanSim.init(a, &m);
            out_bytes = 0;
            files_with = 0;
            const sp = Span.open(io);
            const c0 = meter.counters();
            for (files) |f| {
                var out: std.ArrayList(u8) = .empty;
                var st = json.Stats{};
                json.emitOne(a, &out, &m, &ss, null, o, f, &st, gate);
                out_bytes += out.items.len;
                if (st.get(.files_with_match) > 0) files_with += 1;
                sink +%= out.items.len;
            }
            const c1 = meter.counters();
            const ns: u64 = @intCast(sp.read(io).ns());
            if (ns < s.ns) s = .{ .ns = ns, .cycles = c1.cycles -% c0.cycles, .has_pmu = c0.valid and c1.valid, .bytes = corpus.bytes };
        }
        slowest = @min(slowest, s.mibps());
        std.debug.print("{s:<20} {d:>12.0} {d:>12.3} {d:>10.1} {d:>12}\n", .{ ndl, s.mibps(), s.cpb(), @as(f64, @floatFromInt(out_bytes)) / (1 << 20), files_with });
    }
    return if (slowest == std.math.floatMax(f64)) 0 else slowest;
}

// ─────────────────────────── regression floors ───────────────────────────
//
// Deliberately conservative so the shared coworking box's load never false-trips
// them: the -i/-n floors are RATIOS of two paths timed back-to-back in the same
// run (hardware + jitter cancel), and the -v floor is an absolute far below the
// observed throughput (it only fires on a catastrophic, e.g. O(n²), regression).
// A breach means an optimization was actually lost — fix the code, don't relax
// the floor (the lint-ratchet discipline, applied to perf).
const tax_ceiling: f64 = 3.0; // -i: caseless must stay within 3× of case-sensitive
const decimal_floor: f64 = 1.5; // -n: writeDecimal ≥ 1.5× std.fmt {d}
const invert_floor: f64 = 200.0; // -v: invert emit ≥ 200 MiB/s
// The other emit modes — absolute MiB/s floors, each set well below the observed
// throughput so the shared box's load never false-trips them (a breach means a
// real, e.g. accidentally-quadratic, regression). Selectivity-worst needle.
const files_floor: f64 = 400.0; // -l: files-with-matches (first-hit short-circuit)
const count_floor: f64 = 200.0; // -c: count emit (whole-file line scan + tally)
const only_floor: f64 = 120.0; // -o: only-matching (every span emitted)
const word_floor: f64 = 120.0; // -w: word-regexp gate (SpanSim per line)
const replace_floor: f64 = 50.0; // -r/-rn: replace emit (template expansion)
const json_floor: f64 = 500.0; // --json: record-stream encode (path-cache + writeUint + asciiOnly)

pub fn run(gpa: std.mem.Allocator, io: std.Io, roots: []const []const u8, gate: bool) !void {
    var brand_buf: [128]u8 = undefined;
    const pmu = @import("pmu");
    _ = pmu.requestPerformanceQos();
    var meter = Meter.init();
    defer meter.deinit();

    std.debug.print("gist flagbench · {s} · {s}{s}\nroots:", .{ pmu.cpuBrand(&brand_buf), meter.note, if (gate) " · GATE" else "" });
    for (roots) |r| std.debug.print(" {s}", .{r});
    std.debug.print("\n", .{});

    var corpus = try load(gpa, io, roots, .contiguous);
    defer corpus.deinit();
    std.debug.print("corpus: {d} files · {d:.1} MiB\n", .{ corpus.docs.len, @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20) });

    const tax = try profileCaseless(io, &meter, &corpus);
    const decimal = try profileLineNum(gpa, io, &meter, &corpus);
    const invert = try profileInvert(gpa, io, &meter, &corpus);
    const files_l = try profileEmitMode(gpa, io, &meter, &corpus, "-l  files-with-matches emit (Emitter.file → emitPathOnly)", .{ .mode = .files_with_matches }, .files);
    const count_c = try profileEmitMode(gpa, io, &meter, &corpus, "-c  count emit (Emitter.file → bufTally→writeDecimal)", .{ .mode = .count }, .count);
    const only_o = try profileEmitMode(gpa, io, &meter, &corpus, "-o  only-matching emit (Emitter.onlyMatching)", .{ .only_matching = true }, .none);
    const word_w = try profileEmitMode(gpa, io, &meter, &corpus, "-w  word-regexp gate (Emitter.file + wordOk)", .{ .word = true, .line_num = true }, .none);
    const replace_r = try profileReplace(gpa, io, &meter, &corpus);
    const json_j = try profileJson(gpa, io, &meter, &corpus);

    std.debug.print("\n(sink={d})\n", .{sink});

    // Verdict: advisory by default, blocking under --gate (mirrors the certificate
    // gates' report-only-vs-fail-closed split).
    std.debug.print("\n── floors ({s}) ──\n", .{if (gate) "blocking" else "advisory"});
    var breached = false;
    breached = floor("-i caseless tax", "<=", tax_ceiling, tax, tax <= tax_ceiling) or breached;
    breached = floor("-n writeDecimal speedup", ">=", decimal_floor, decimal, decimal >= decimal_floor) or breached;
    breached = floor("-v invert emit MiB/s", ">=", invert_floor, invert, invert >= invert_floor) or breached;
    breached = floor("-l files-only emit MiB/s", ">=", files_floor, files_l, files_l >= files_floor) or breached;
    breached = floor("-c count emit MiB/s", ">=", count_floor, count_c, count_c >= count_floor) or breached;
    breached = floor("-o only-matching MiB/s", ">=", only_floor, only_o, only_o >= only_floor) or breached;
    breached = floor("-w word-regexp MiB/s", ">=", word_floor, word_w, word_w >= word_floor) or breached;
    breached = floor("-r/-rn replace emit MiB/s", ">=", replace_floor, replace_r, replace_r >= replace_floor) or breached;
    breached = floor("--json record emit MiB/s", ">=", json_floor, json_j, json_j >= json_floor) or breached;
    if (breached and gate) return error.FlagbenchFloorBreached;
}

/// Print one floor verdict (`PASS`/`FAIL`), returning true iff it was breached.
fn floor(name: []const u8, op: []const u8, bound: f64, got: f64, ok: bool) bool {
    std.debug.print("  [{s}] {s:<26} {s} {d:>7.2}  (got {d:.2})\n", .{ if (ok) "PASS" else "FAIL", name, op, bound, got });
    return !ok;
}
