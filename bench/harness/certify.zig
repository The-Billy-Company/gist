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
const gist = @import("irregex");
const corpus_mod = gist.corpus;
const simd = gist.simd;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span
const pmu = @import("pmu.zig");
const stats = @import("stats.zig");

const Index = gist.trigram.Index;
const Regex = gist.regex.Regex;
const Dir = std.Io.Dir;
const load = corpus_mod.load;
const out_dir = gist.home.default_out_dir;

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
            // The committed 12-class certificate was minted over the ASCII
            // engine; keep measuring it here so the microscopic numbers stay
            // byte-consistent with the published artifact. The next clean-tree
            // republish flips this to `.unicode = true` alongside the new
            // Unicode probe classes atomically.
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
        const sp = Span.open(io);
        const hits = switch (probe.kind) {
            .literal => verifyLiteral(corpus, cand, probe.pattern),
            .regex => verifyRegex(&re.?, &sim.?, corpus, cand),
        };
        const elapsed: u64 = @intCast(@max(sp.read(io).ns(), 0));
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
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try load(gpa, io, roots);
    defer corpus.deinit();
    var idx = try Index.build(gpa, corpus.docs);
    defer idx.deinit();

    var meter = pmu.Meter.init();
    defer meter.deinit();

    // Host provenance + P-core bias — both once, strictly before any timed
    // window, so nothing new ever executes inside a measured region.
    var brand_buf: [64]u8 = undefined;
    const brand = pmu.cpuBrand(&brand_buf);
    const qos: []const u8 = if (pmu.requestPerformanceQos())
        "USER_INTERACTIVE QoS (P-core-biased)"
    else
        "default QoS (no core bias)";

    var prng = std.Random.DefaultPrng.init(0x6e15);
    const rng = prng.random();

    const mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    std.debug.print("gist certify · Layer A (microscopic) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} ({s}) · zig {s} · {s}\n", .{ brand, @tagName(builtin.target.cpu.arch), builtin.zig_version_string, qos });
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

    try writeArtifacts(gpa, io, &corpus, &meter, rows.items, mib, brand, qos);
    std.debug.print("\nwrote {s}/CERTIFICATE.md + certify.csv\n", .{out_dir});
    if (!meter.has_pmu) std.debug.print("note: cycles NOT measured on this machine (no PMU) — the certificate says so. Re-run `sudo pkg/kernels/irregex/zig-out/bin/gist-bench certify` from the repo root for measured cycles/byte.\n", .{});
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

fn writeArtifacts(gpa: std.mem.Allocator, io: std.Io, corpus: *const corpus_mod.Corpus, meter: *pmu.Meter, rows: []const Row, mib: f64, brand: []const u8, qos: []const u8) !void {
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

    try md.appendSlice(gpa, "# gist — Dominance-and-Fit Certificate\n\n");
    try md.appendSlice(gpa, "> Auto-generated by `zig build certify` (microscopic) + `bench/certify.sh`\n> (macroscopic). Every line is a **measured number with a provenance**, not a\n> claim. Do not hand-edit — re-run to refresh.\n\n");
    try md.appendSlice(gpa, "## What this certifies (and what it doesn't)\n\n");
    try md.appendSlice(gpa, "A *dominance-and-fit certificate* is built in layers **A through L**, cheapest evidence first. It certifies measured dominance over a named baseline and each layer's fit against a stated bound — never universal or hardware optimality. The roster every gate reads is `bench/certify/layers.py`; a layer that mints without a row there is a hard failure, which is how a silently dropped section gets caught:\n\n");
    try md.appendSlice(gpa, "- **Layer A — empirical dominance (this document).** gist outperforms the\n  official ripgrep baseline on the registered workloads, established with\n  statistics, not a single mean: a 95% bootstrap-CI on every median + a\n  Mann-Whitney significance test, **fail-closed** (a win requires a lower\n  median AND p<0.05). Two halves: *microscopic* (retired cycles + instructions\n  per byte for the single-thread verify kernel — the bridge number Layers B–C\n  bound) and *macroscopic* (process-vs-process, with the wider field shown as\n  context rather than folded into the verdict).\n");
    try md.appendSlice(gpa, "- **Layer B — port-optimality.** the hot loop's instruction selection + port\n  pressure match the static microarchitectural bound (llvm-mca). See `bench/portcert/` — run `bench/portcert/portcert.sh` to (re)populate its section below.\n");
    try md.appendSlice(gpa, "- **Layer C — roofline headroom.** measures the scan's distance from the pure-read roof and decomposes it with matched dual-window, contiguous-production, and corpus-production stages. It reports near-roof placement only above its pre-registered threshold; otherwise it reports optimization headroom. See `bench/roofline/` — run `zig build roofline` then `bench/roofline/roofline_report.py` to (re)populate its section below.\n");
    try md.appendSlice(gpa, "- **Layer D — algorithmic lower bound.** the algorithm matches the\n  information-theoretic floor for the operation. See `bench/lowerbound/` — run `zig build lowerbound` then `bench/lowerbound/lowerbound_report.py` to (re)populate its section below.\n");
    try md.appendSlice(gpa, "- **Layer E — crest sieve (index completeness).** the one place gist's index math is new: a sound forced-class-run necessary condition that prunes the literal-free class repetitions (`[0-9a-f]{12}`) every trigram-family index concedes — Layer A's `regex-classcount` cand%=100% hole. Fail-closed (`matched ⇒ ¬pruned` over the corpus + adversarial sweeps); measures pruning + speedup vs the real matcher, with the count-cousin ablation proving necessity. See `bench/crest/` — run `zig build crest` then `bench/certify/certify_crest_report.py` to (re)populate its section below.\n");
    try md.appendSlice(gpa, "- **Layer F — codex self-index.** the FM-index tier that answers corpus-wide exact-literal counting from a compressed self-index instead of a scan. See `bench/codex/`.\n");
    try md.appendSlice(gpa, "- **Layer G — relate.** the compression-as-search sibling: kinship and repetition answers regex cannot express, priced against its own baselines. See `bench/knn/`.\n");
    try md.appendSlice(gpa, "- **Layer H — portability (executed).** every target ripgrep declares, *built and run* rather than merely compiled — POSIX triples plus Windows, with emulated runs scored on their own rung so a Wine pass can never be rounded up into native conformance. See `bench/targets/`.\n");
    try md.appendSlice(gpa, "- **Layer I — scanner mode + ripgrep conformance.** the claim that gist only wins because it has an index, tested by switching the index off (`--no-index`, no crest sidecar, no daemon), plus rg-conformance measured against a denominator ripgrep owns (its own documented flag surface + its own mined test corpus). See `bench/races/scanner_headtohead.sh` + `bench/rgsuite/`.\n");
    try md.appendSlice(gpa, "- **Layer J — index tiers at scale (vs zoekt).** the substring (sliver) tier that closes the 1–2 byte-needle hole for zero bytes on disk, the positional tier priced and *declined* with its Pareto curve published, and build/query/residency at multi-GB scale — including the residency lane gist loses. See `bench/sliver/`.\n");
    try md.appendSlice(gpa, "- **Layer K — multi-pattern (vs Hyperscan/Vectorscan).** N patterns in one walk with exact per-pattern attribution, across both prefilter tiers (SIMD dragnet, Aho–Corasick trawl) so moving the dispatch threshold cannot move which code was proven exact. See `bench/multipattern/`.\n");
    try md.appendSlice(gpa, "- **Layer L — index quality (vs csearch).** the trigram index judged head-to-head on the axes that decide a filter: candidate bytes admitted, build time, and size. See `bench/indexq/`.\n\n");
    try md.appendSlice(gpa, "Honesty rule: this is a *fit + dominance* certificate. Every claim above is\n  a **measured number with a provenance**, never asserted. Note the layering:\n  this run (`zig build certify`) rewrites the WHOLE file, so Layers B-L's\n  sections below only exist if you re-splice them afterward — see each\n  layer's own `bench/<layer>/README.md` for its one-line rerun command.\n  `bench/certify/certify_layers.sh` re-splices the whole tail in one pass.\n\n");
    try md.appendSlice(gpa, "## Layer A — empirical, microscopic (single-thread kernel)\n\n");
    try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "- machine: **{s}** (`{s}`) · zig `{s}` · {s}\n", .{ brand, @tagName(builtin.target.cpu.arch), builtin.zig_version_string, qos }));
    try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "- meter: {s}\n", .{meter.note}));
    // PMU state is a first-class certificate fact — fail-closed. A blank cycles
    // column must never read as "measured but small"; the provenance line below
    // says exactly which machine (if any) the cyc/byte numbers were minted on.
    if (meter.has_pmu) {
        try md.appendSlice(gpa, try std.fmt.bufPrint(&line, "- cycles/byte provenance: **measured on this machine** ({s}, {s})\n", .{ brand, qos }));
    } else {
        try md.appendSlice(gpa, "- cycles/byte provenance: **NOT measured on this machine** — cross-checked against Layer B's reference-core static bounds only. Re-run `sudo pkg/kernels/irregex/zig-out/bin/gist-bench certify` (repo root) for the measured certificate.\n");
    }
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
    if (!meter.has_pmu) try md.appendSlice(gpa, "\n> ⚠ **cyc/byte + IPC are blank, not zero — NOT measured on this machine** (xnu\n> gates the PMU to root). Until a `sudo` run mints them, the cycles/byte claim\n> rests on the reference-core cross-check (Layer B) alone. Re-run\n> `sudo pkg/kernels/irregex/zig-out/bin/gist-bench certify` from the repo root\n> for measured cycles + IPC.\n");
    try md.appendSlice(gpa, "\n## Layer A — macroscopic dominance over ripgrep\n\n_Populated by `bench/certify.sh` (process-vs-process, bootstrap CI + Mann-Whitney; wider-field timings remain context)._\n");
    try Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/CERTIFICATE.md", .data = md.items });
}
