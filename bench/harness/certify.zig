//! gist bench — `certify`: Layer A of the optimality certificate (the
//! *microscopic* half). For each regex class it runs gist's real query path
//! **single-threaded** over the RAM-resident corpus and records, per rep, the
//! retired **cycles** + **instructions** (PMU) and wall **ns**, then reports
//! cycles/byte, instructions/byte, IPC, and a 95% bootstrap CI on the median.
//!
//! Why single-threaded: the PMU reads the *calling thread's* counters, so a
//! parallel fan-out would leak cycles onto unmeasured workers. Per-core cycles/
//! byte is also exactly the quantity the roofline (Layer C) and the static
//! port-pressure bound (Layer B) compare against — this is the bridge number.
//!
//! Without root the PMU degrades to wall-clock (ns/byte still reported, cycles
//! blank) — the run never fails; re-run under `sudo` for the cycle certificate.
//! The *macroscopic* dominance vs ripgrep (process-vs-process, bootstrap-CI +
//! Mann-Whitney) lives in the sibling `certify.sh` (fair invocations from
//! `_compete.sh`); both write into the same `CERTIFICATE.md`.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("gist");
const corpus_mod = gist.corpus;
const simd = gist.simd;
const pmu = @import("pmu.zig");
const stats = @import("stats.zig");

const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
const Dir = std.Io.Dir;
const load = corpus_mod.load;
const out_dir = corpus_mod.out_dir;
const default_roots = corpus_mod.default_roots;

const reps = 200;
const warmup = 20;

// Single source of truth for the probe classes — Layer D
// (`../lowerbound/lowerbound.zig`) imports the same file so the two layers
// can never drift apart. See `probes.zig`'s header for why this used to be a
// hand-duplicated array.
const probes_mod = @import("probes.zig");
const Kind = probes_mod.Kind;
const Probe = probes_mod.Probe;
const probes = probes_mod.probes;

const Row = struct {
    class: []const u8,
    files: usize,
    cand: usize, // candidate docs after prefilter
    cand_frac: f64, // fraction of corpus the prefilter admits
    bytes: u64, // bytes the verify kernel crunches (candidate bytes)
    ns: stats.Summary,
    has_pmu: bool,
    cyc_med: f64,
    ins_med: f64,
    cyc_per_byte: f64,
    ipc: f64,
};

/// Resolve candidate doc ids for a literal needle (trigram AND, or all docs when
/// the needle is too short to filter). Single-threaded.
fn litCandidates(idx: *const Index, gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus, needle: []const u8) ![]u32 {
    if (needle.len >= 3) {
        if (idx.queryLiteral(gpa, needle)) |c| return c else |_| {}
    }
    const all = try gpa.alloc(u32, corpus.docs.len);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    return all;
}

/// Resolve candidate doc ids for a compiled regex (required literal, or the
/// alternation cover union, or all docs). Single-threaded.
fn rgxCandidates(re: *const Regex, idx: *const Index, gpa: std.mem.Allocator, corpus: *const corpus_mod.Corpus) ![]u32 {
    var one = [_][]const u8{re.required};
    const filters: []const []const u8 = if (re.required.len >= 3) one[0..] else re.alts;
    if (filters.len > 0) {
        if (idx.queryAny(gpa, filters)) |c| return c else |_| {}
    }
    const all = try gpa.alloc(u32, corpus.docs.len);
    for (all, 0..) |*x, i| x.* = @intCast(i);
    return all;
}

/// The measured kernel: single-threaded verify of `cand` against the probe,
/// returning the match count (kept live so the optimizer can't elide the work).
fn verifyLiteral(corpus: *const corpus_mod.Corpus, cand: []const u32, needle: []const u8) usize {
    var hits: usize = 0;
    for (cand) |d| if (simd.contains(corpus.docs[d], needle)) {
        hits += 1;
    };
    return hits;
}

fn verifyRegex(re: *const Regex, sim: *Regex.Sim, corpus: *const corpus_mod.Corpus, cand: []const u32) usize {
    var hits: usize = 0;
    for (cand) |d| if (re.docMatch(sim, corpus.docs[d])) {
        hits += 1;
    };
    return hits;
}

var sink: usize = 0; // defeat dead-code elimination of the measured kernel

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn measure(
    gpa: std.mem.Allocator,
    io: std.Io,
    corpus: *const corpus_mod.Corpus,
    idx: *const Index,
    meter: *pmu.Meter,
    probe: Probe,
    rng: std.Random,
) !Row {
    // Compile (regex) + resolve candidates once; the measured region is verify.
    var re: ?Regex = null;
    var sim: ?Regex.Sim = null;
    defer if (sim) |*s| s.deinit();
    defer if (re) |*r| r.deinit();

    const cand = switch (probe.kind) {
        .literal => try litCandidates(idx, gpa, corpus, probe.pattern),
        .regex => blk: {
            re = try Regex.compile(gpa, probe.pattern);
            sim = try Regex.Sim.init(gpa, &re.?);
            break :blk try rgxCandidates(&re.?, idx, gpa, corpus);
        },
    };
    defer gpa.free(cand);

    var bytes: u64 = 0;
    for (cand) |d| bytes += corpus.docs[d].len;

    var ns: [reps]f64 = undefined;
    var cyc: [reps]f64 = undefined;
    var ins: [reps]f64 = undefined;
    var files: usize = 0;

    for (0..warmup + reps) |it| {
        const c0 = meter.counters();
        const t0 = nowNs(io);
        const hits = switch (probe.kind) {
            .literal => verifyLiteral(corpus, cand, probe.pattern),
            .regex => verifyRegex(&re.?, &sim.?, corpus, cand),
        };
        const elapsed: u64 = @intCast(@max(nowNs(io) - t0, 0));
        const c1 = meter.counters();
        sink +%= hits;
        if (it < warmup) continue;
        const i = it - warmup;
        ns[i] = @floatFromInt(elapsed);
        cyc[i] = @floatFromInt(c1.cycles -% c0.cycles);
        ins[i] = @floatFromInt(c1.instructions -% c0.instructions);
        files = hits;
    }

    var scratch: [reps]f64 = undefined;
    const ns_sum = stats.summarize(&ns, &scratch, rng);
    std.mem.sort(f64, &cyc, {}, std.sort.asc(f64));
    std.mem.sort(f64, &ins, {}, std.sort.asc(f64));
    const cyc_med = stats.quantile(&cyc, 0.50);
    const ins_med = stats.quantile(&ins, 0.50);
    const bf: f64 = @floatFromInt(@max(bytes, 1));

    return .{
        .class = probe.class,
        .files = files,
        .cand = cand.len,
        .cand_frac = @as(f64, @floatFromInt(cand.len)) / @as(f64, @floatFromInt(corpus.docs.len)),
        .bytes = bytes,
        .ns = ns_sum,
        .has_pmu = meter.has_pmu,
        .cyc_med = cyc_med,
        .ins_med = ins_med,
        .cyc_per_byte = if (meter.has_pmu) cyc_med / bf else 0,
        .ipc = if (meter.has_pmu and cyc_med > 0) ins_med / cyc_med else 0,
    };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var corpus = try load(gpa, io, &default_roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();

    var meter = pmu.Meter.init();
    defer meter.deinit();

    var prng = std.Random.DefaultPrng.init(0x6e15);
    const rng = prng.random();

    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    std.debug.print("gist certify · Layer A (microscopic) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("meter:   {s}\n", .{meter.note});
    std.debug.print("corpus:  {d} files · {d:.1} MiB · single-thread verify · {d} reps (+{d} warmup)\n\n", .{ corpus.docs.len, mib, reps, warmup });

    std.debug.print("{s:<18} {s:>7} {s:>7} {s:>11} {s:>14} {s:>10} {s:>6}\n", .{ "class", "files", "cand%", "median", "95% CI", "cyc/byte", "IPC" });
    std.debug.print("{s:-<18} {s:->7} {s:->7} {s:->11} {s:->14} {s:->10} {s:->6}\n", .{ "", "", "", "", "", "", "" });

    var rows: std.ArrayList(Row) = .empty;
    defer rows.deinit(gpa);
    for (probes) |p| {
        const row = try measure(gpa, io, &corpus, &idx, &meter, p, rng);
        try rows.append(gpa, row);
        std.debug.print("{s:<18} {d:>7} {d:>6.1}% {d:>8.1} us {d:>5.1}-{d:>5.1} us {s} {s}\n", .{
            row.class,
            row.files,
            row.cand_frac * 100.0,
            row.ns.median / 1e3,
            row.ns.ci_lo / 1e3,
            row.ns.ci_hi / 1e3,
            fmtCyc(row),
            fmtIpc(row),
        });
    }

    try writeArtifacts(gpa, io, &corpus, &meter, rows.items, mib);
    std.debug.print("\nwrote {s}/CERTIFICATE.md + certify.csv\n", .{out_dir});
    if (!meter.has_pmu) std.debug.print("note: cycles unavailable — re-run `sudo zig build certify` for the cycle/byte certificate.\n", .{});
}

var cyc_buf: [32]u8 = undefined;
var ipc_buf: [16]u8 = undefined;

fn fmtCyc(row: Row) []const u8 {
    if (!row.has_pmu) return std.fmt.bufPrint(&cyc_buf, "{s:>10}", .{"—"}) catch "—";
    return std.fmt.bufPrint(&cyc_buf, "{d:>10.2}", .{row.cyc_per_byte}) catch "?";
}

fn fmtIpc(row: Row) []const u8 {
    if (!row.has_pmu) return std.fmt.bufPrint(&ipc_buf, "{s:>6}", .{"—"}) catch "—";
    return std.fmt.bufPrint(&ipc_buf, "{d:>6.2}", .{row.ipc}) catch "?";
}

fn writeArtifacts(gpa: std.mem.Allocator, io: std.Io, corpus: *const corpus_mod.Corpus, meter: *pmu.Meter, rows: []const Row, mib: f64) !void {
    try Dir.cwd().createDirPath(io, out_dir);
    var csv: std.ArrayList(u8) = .empty;
    defer csv.deinit(gpa);
    var md: std.ArrayList(u8) = .empty;
    defer md.deinit(gpa);
    var line: [256]u8 = undefined;

    try csv.appendSlice(gpa, "class\tfiles\tcand\tcand_frac\tbytes\tmedian_ns\tci_lo_ns\tci_hi_ns\tcyc_med\tins_med\tcyc_per_byte\tipc\toutliers\n");
    for (rows) |r| {
        try csv.appendSlice(gpa, try std.fmt.bufPrint(&line, "{s}\t{d}\t{d}\t{d:.4}\t{d}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.0}\t{d:.4}\t{d:.4}\t{d}\n", .{
            r.class, r.files, r.cand, r.cand_frac, r.bytes, r.ns.median, r.ns.ci_lo, r.ns.ci_hi, r.cyc_med, r.ins_med, r.cyc_per_byte, r.ipc, r.ns.outliers_mild + r.ns.outliers_severe,
        }));
    }
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/certify.csv", .data = csv.items });

    try md.appendSlice(gpa, "# gist — Certificate of Optimality\n\n");
    try md.appendSlice(gpa, "> Auto-generated by `zig build certify` (microscopic) + `bench/certify.sh`\n> (macroscopic). Every line is a **measured number with a provenance**, not a\n> claim. Do not hand-edit — re-run to refresh.\n\n");
    try md.appendSlice(gpa, "## What this certifies (and what it doesn't)\n\n");
    try md.appendSlice(gpa, "A *certificate of optimality* is built in four layers, cheapest evidence first:\n\n");
    try md.appendSlice(gpa, "- **Layer A — empirical dominance (this document).** gist is *fastest in its\n  class* on real workloads, established with statistics, not a single mean: a\n  95% bootstrap-CI on every median + a Mann-Whitney significance test, **fail-\n  closed** (a win requires a lower median AND p<0.05). Two halves: *microscopic*\n  (retired cycles + instructions per byte for the single-thread verify kernel —\n  the bridge number Layers B–C bound) and *macroscopic* (process-vs-process vs\n  the field, the end-to-end claim).\n");
    try md.appendSlice(gpa, "- **Layer B — port-optimality.** the hot loop's instruction selection + port\n  pressure match the static microarchitectural bound (llvm-mca). See `bench/portcert/` — run `bench/portcert/portcert.sh` to (re)populate its section below.\n");
    try md.appendSlice(gpa, "- **Layer C — roofline.** cycles/byte sits on the hardware ceiling (memory\n  bandwidth or compute), so no implementation on this chip can go faster. See `bench/roofline/` — run `zig build roofline` then `bench/roofline/roofline_report.py` to (re)populate its section below.\n");
    try md.appendSlice(gpa, "- **Layer D — algorithmic lower bound.** the algorithm matches the\n  information-theoretic floor for the operation. See `bench/lowerbound/` — run `zig build lowerbound` then `bench/lowerbound/lowerbound_report.py` to (re)populate its section below.\n\n");
    try md.appendSlice(gpa, "Honesty rule: this is a *fit + dominance* certificate. Every claim above is\n  a **measured number with a provenance**, never asserted. Note the layering:\n  this run (`zig build certify`) rewrites the WHOLE file, so Layers B-D's\n  sections below only exist if you re-splice them afterward — see each\n  layer's own `bench/<layer>/README.md` for its one-line rerun command.\n\n");
    try md.appendSlice(gpa, "## Layer A — empirical, microscopic (single-thread kernel)\n\n");
    try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "- machine: `{s}` · zig `{s}`\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string }));
    try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "- meter: {s}\n", .{meter.note}));
    try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "- corpus: {d} files · {d:.1} MiB · {d} reps (+{d} warmup) · seeded bootstrap (10k)\n", .{ corpus.docs.len, mib, reps, warmup }));
    try md.appendSlice(gpa, "- method: each class times gist's **real** verify path single-threaded over the\n  RAM-resident corpus; `cyc/byte` = retired cycles ÷ candidate bytes crunched,\n  `IPC` = instructions ÷ cycles, `cand%` = fraction of the corpus the trigram\n  prefilter admits. Lower `median` / `cyc/byte` is better.\n\n");
    try md.appendSlice(gpa, "| class | files | cand% | median (95% CI) | cyc/byte | IPC | outliers |\n");
    try md.appendSlice(gpa, "|---|--:|--:|--:|--:|--:|--:|\n");
    for (rows) |r| {
        const cyc = if (r.has_pmu) std.fmt.bufPrint(cyc_buf[0..16], "{d:.2}", .{r.cyc_per_byte}) catch "?" else "—";
        const ipc = if (r.has_pmu) std.fmt.bufPrint(ipc_buf[0..12], "{d:.2}", .{r.ipc}) catch "?" else "—";
        try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "| `{s}` | {d} | {d:.1}% | {d:.1} µs ({d:.1}–{d:.1}) | {s} | {s} | {d} |\n", .{
            r.class, r.files, r.cand_frac * 100.0, r.ns.median / 1e3, r.ns.ci_lo / 1e3, r.ns.ci_hi / 1e3, cyc, ipc, r.ns.outliers_mild + r.ns.outliers_severe,
        }));
    }
    if (!meter.has_pmu) try md.appendSlice(gpa, "\n> ⚠ cycles unavailable (no PMU permission). Re-run under `sudo` on Apple Silicon for the cycle/byte certificate.\n");
    try md.appendSlice(gpa, "\n## Layer A — macroscopic dominance vs the field\n\n_Populated by `bench/certify.sh` (process-vs-process, bootstrap CI + Mann-Whitney)._\n");
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/CERTIFICATE.md", .data = md.items });
}
