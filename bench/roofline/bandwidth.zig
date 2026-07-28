//! gist bench — `roofline`: Layer C of the performance certificate. A STREAM-style
//! (McCalpin 1995) single-thread **read-bandwidth** microbenchmark that measures
//! the achievable memory bandwidth of THIS machine at three working-set tiers —
//! L1-, L2-, and DRAM-resident — exposing the cache hierarchy. gist's verify path
//! is then measured through a matched ladder: the same dual-window load/compare
//! shape on one contiguous DRAM buffer, production `simd.contains` on that buffer,
//! and production over the fragmented corpus. The roofline model (Williams,
//! Waterman & Patterson, CACM 2009) supplies an upper bound; the ladder explains
//! the distance to it instead of pretending that a sub-ceiling point saturates it.
//!
//! Zero-dep, mirroring gist's discipline: a plain vectorized sum-reduction over
//! an aligned buffer, kept live through a global `sink` to defeat DCE (as
//! certify.zig does), timed with `std.Io.Clock`. Single-threaded on purpose —
//! certify's verify kernel is single-threaded, so the honest ceiling is the
//! per-core achievable bandwidth, not the chip's aggregate.
//!
//! Frequency (needed only for the derived cycles/byte ceiling) is **measured**
//! via the same kperf PMU certify uses when run under `sudo`; without it we fall
//! back to a clearly-labeled assumed clock and report the ceiling primarily in
//! GB/s (bytes/ns), which needs no frequency at all. Never fails the run
//! (pmu.zig's discipline): no PMU ⇒ assumed clock + a loud note.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const pmu = @import("pmu"); // bench/harness/pmu.zig, wired as a module in build.zig

const corpus_mod = gist.corpus;
const simd = gist.simd;
const out_dir = gist.home.default_out_dir;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span

// 8×u64 = 64-byte logical vector (lowered to NEON 128-bit loads on aarch64);
// NACC independent accumulators hide load-use latency so the loop is bound by
// load-port / cache bandwidth, not by the dependency chain.
const V = 8;
const NACC = 8;
const STEP = NACC * V; // u64 words consumed per inner iteration (512 B)
const Vu = @Vector(V, u64);
const scan_vlen: usize = std.simd.suggestVectorLength(u8) orelse 16;
const ScanVec = @Vector(scan_vlen, u8);
const ScanMask = std.meta.Int(.unsigned, scan_vlen);

// Best-of-N: interference from ~10 coworking agents on this shared box only ever
// *slows* a trial, so the max GB/s across trials is the cleanest estimate of the
// true achievable ceiling (min-of-N time). Median is kept for context.
const trials = 9;
const traffic_budget = 2 << 30; // ~2 GiB of reads per trial, per tier

/// Assumed core clock when no PMU (Apple M4 Max P-core sustained boost, ~4.4 GHz;
/// labeled loudly in output). Only affects the *derived* cycles/byte figure —
/// the primary GB/s ceiling is frequency-free.
const assumed_ghz = 4.4;

var sink: u64 = 0; // defeat DCE of the measured reduction

/// The measured kernel: a pure streaming read reduction over `buf`. Returns the
/// checksum (kept live via `sink`) so the optimizer can't elide the loads.
fn streamSum(buf: []const u64) u64 {
    var acc: [NACC]Vu = undefined;
    inline for (&acc) |*a| a.* = @splat(0);

    var i: usize = 0;
    while (i + STEP <= buf.len) : (i += STEP) {
        inline for (0..NACC) |k| {
            const v: Vu = buf[i + k * V ..][0..V].*;
            acc[k] +%= v;
        }
    }
    var total: Vu = @splat(0);
    inline for (0..NACC) |k| total +%= acc[k];
    var s: u64 = @reduce(.Add, total);
    while (i < buf.len) : (i += 1) s +%= buf[i]; // tail
    return s;
}

const Tier = struct {
    name: []const u8,
    bytes: usize,
    gbps_max: f64,
    gbps_median: f64,
};

const Stage = struct {
    name: []const u8,
    gbps_max: f64,
    gbps_median: f64,
};

/// Read-bandwidth of one working-set size: sweep `buf` enough times to move
/// ~`traffic_budget` bytes per trial, take the fastest of `trials` (best = least
/// contended). GB/s = bytes moved ÷ ns (1 GB/s ≡ 1 byte/ns).
fn measureTier(io: std.Io, name: []const u8, buf: []u64) Tier {
    const buf_bytes = buf.len * @sizeOf(u64);
    const sweeps: usize = @max(traffic_budget / buf_bytes, 1);
    const moved: f64 = @floatFromInt(buf_bytes * sweeps);

    var samples: [trials]f64 = undefined; // GB/s per trial
    for (0..trials) |t| {
        // Warm the buffer into its target cache level before timing.
        sink +%= streamSum(buf);
        const sp = Span.open(io);
        var acc: u64 = 0;
        for (0..sweeps) |_| acc +%= streamSum(buf);
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        sink +%= acc;
        samples[t] = moved / ns; // bytes/ns == GB/s
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return .{
        .name = name,
        .bytes = buf_bytes,
        .gbps_max = samples[trials - 1],
        .gbps_median = samples[trials / 2],
    };
}

/// Production-shaped control: two offset vector loads, two compares, mask AND,
/// and the same rare-survivor branch as `simd.indexOfPos`, but no candidate
/// verification or per-document dispatch. Its gap from STREAM is instruction /
/// load-port cost; later ladder gaps isolate production control and corpus shape.
fn dualWindowCandidates(buf: []const u8, needle: []const u8) usize {
    const first: ScanVec = @splat(needle[0]);
    const last: ScanVec = @splat(needle[needle.len - 1]);
    const last_off = needle.len - 1;
    var candidates: usize = 0;
    var i: usize = 0;
    while (i + last_off + scan_vlen <= buf.len) : (i += scan_vlen) {
        const bf: ScanVec = buf[i..][0..scan_vlen].*;
        const bl: ScanVec = buf[i + last_off ..][0..scan_vlen].*;
        const bits: ScanMask = @bitCast((bf == first) & (bl == last));
        if (bits != 0) candidates +%= @popCount(bits);
    }
    return candidates;
}

fn measureContiguous(io: std.Io, name: []const u8, buf: []const u8, needle: []const u8, comptime matched: bool) Stage {
    const sweeps: usize = @max(traffic_budget / buf.len, 1);
    const moved: f64 = @floatFromInt(buf.len * sweeps);
    var samples: [trials]f64 = undefined;
    for (0..trials) |t| {
        var result: usize = 0;
        const sp = Span.open(io);
        for (0..sweeps) |_| {
            if (matched) {
                result +%= dualWindowCandidates(buf, needle);
            } else {
                result +%= @intFromBool(simd.contains(buf, needle));
            }
        }
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        sink +%= result;
        samples[t] = moved / ns;
    }
    std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
    return .{ .name = name, .gbps_max = samples[trials - 1], .gbps_median = samples[trials / 2] };
}

/// Effective core clock (GHz) via the kperf PMU: stream the DRAM buffer once with
/// the cycle counter live, GHz = Δcycles ÷ Δns — the honest frequency *under
/// memory load*, which is exactly the regime the memory ceiling describes. Falls
/// back to the assumed clock when the PMU is unavailable (no sudo / not macOS).
fn measureGhz(io: std.Io, meter: *pmu.Meter, buf: []u64) struct { ghz: f64, source: []const u8 } {
    if (!meter.has_pmu) return .{ .ghz = assumed_ghz, .source = "assumed (no PMU — run `sudo` for a measured clock)" };
    const c0 = meter.counters();
    const sp = Span.open(io);
    var acc: u64 = 0;
    for (0..64) |_| acc +%= streamSum(buf);
    const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
    const c1 = meter.counters();
    sink +%= acc;
    const cycles: f64 = @floatFromInt(c1.cycles -% c0.cycles);
    if (cycles <= 0) return .{ .ghz = assumed_ghz, .source = "assumed (PMU returned no cycles)" };
    return .{ .ghz = cycles / ns, .source = "measured (kperf, cycles ÷ ns under memory load)" };
}

const ScanResult = struct { needle: []const u8, kind: []const u8, gbps: f64 };

// Absent needle forces a full scan of every byte (no early exit, no verify) —
// the clean streaming point. The realistic ones show early-exit + verification.
const scan_needles = [_]ScanResult{
    .{ .needle = "Zq9_gist_roofline_absent_needle_", .kind = "full-scan (0 matches, pure streaming)", .gbps = 0 },
    .{ .needle = "func", .kind = "with matches (early-exit + verify)", .gbps = 0 },
    .{ .needle = "})", .kind = "with matches (early-exit + verify)", .gbps = 0 },
};

/// gist's real SIMD substring scan (`scan/simd.zig` `contains`) streamed over the
/// RAM-resident corpus — the **clean** roofline operating point. With an absent
/// needle it reads every byte (no early exit, no verification), so corpus_bytes ÷
/// ns is gist's true streaming bandwidth, directly comparable to the STREAM
/// ceiling. (certify.csv's per-class bytes÷ns conflates early-exit + false-positive
/// verification, so it is *not* a clean bandwidth — the report flags that.)
fn measureGistScan(io: std.Io, corpus: *const corpus_mod.Corpus, needle: []const u8) f64 {
    const bytes: f64 = @floatFromInt(corpus.bytes);
    var best: f64 = 0;
    for (0..trials) |_| {
        var hits: usize = 0;
        const sp = Span.open(io);
        for (corpus.docs) |d| if (simd.contains(d, needle)) {
            hits += 1;
        };
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        sink +%= hits;
        best = @max(best, bytes / ns);
    }
    return best;
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    // Three tiers sized to land in distinct levels of the M-series hierarchy:
    // L1 (128 KiB P-core L1D) · L2 (16 MiB shared per P-cluster) · DRAM (beyond
    // the system-level cache). Sizes are rounded to whole STEP strides.
    const sizes = [_]struct { name: []const u8, bytes: usize }{
        .{ .name = "L1", .bytes = 16 << 10 }, // 16 KiB — deep inside L1D
        .{ .name = "L2", .bytes = 3 << 20 }, // 3 MiB — past L1, inside L2
        .{ .name = "DRAM", .bytes = 512 << 20 }, // 512 MiB — well past any cache
    };

    var meter = pmu.Meter.init();
    defer meter.deinit();

    std.debug.print("gist roofline · Layer C (measured headroom) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} · zig {s}\n", .{ @tagName(builtin.target.cpu.arch), builtin.zig_version_string });
    std.debug.print("meter:   {s}\n", .{meter.note});
    std.debug.print("method:  single-thread STREAM read reduction · best-of-{d} · ~{d} MiB/trial\n\n", .{ trials, traffic_budget >> 20 });

    std.debug.print("{s:<6} {s:>12} {s:>14} {s:>14}\n", .{ "tier", "working set", "read GB/s", "median GB/s" });
    std.debug.print("{s:-<6} {s:->12} {s:->14} {s:->14}\n", .{ "", "", "", "" });

    var tiers: [sizes.len]Tier = undefined;
    var dram_buf: []u64 = &.{};
    for (sizes, 0..) |s, i| {
        const words = (s.bytes / @sizeOf(u64) / STEP) * STEP;
        const buf = try gpa.alignedAlloc(u64, comptime .fromByteUnits(64), words);
        for (buf, 0..) |*x, k| x.* = k *% 0x9E3779B97F4A7C15; // non-zero, non-trivial
        tiers[i] = measureTier(io, s.name, buf);
        std.debug.print("{s:<6} {d:>9} KiB {d:>12.1}   {d:>12.1}\n", .{
            tiers[i].name, tiers[i].bytes >> 10, tiers[i].gbps_max, tiers[i].gbps_median,
        });
        if (i == sizes.len - 1) dram_buf = buf else gpa.free(buf);
    }
    defer gpa.free(dram_buf);

    const clk = measureGhz(io, &meter, dram_buf);
    const dram = tiers[sizes.len - 1];
    const l2 = tiers[1];
    // cycles/byte ceiling = cycles/ns ÷ bytes/ns = GHz ÷ GB/s. The floor no
    // single-thread kernel can beat: it would have to read faster than memory.
    const dram_cpb = clk.ghz / dram.gbps_max;
    const l2_cpb = clk.ghz / l2.gbps_max;

    std.debug.print("\nclock:   {d:.3} GHz · {s}\n", .{ clk.ghz, clk.source });
    std.debug.print("ceiling: DRAM {d:.1} GB/s = {d:.4} cyc/byte · L2 {d:.1} GB/s = {d:.4} cyc/byte\n", .{
        dram.gbps_max, dram_cpb, l2.gbps_max, l2_cpb,
    });

    const absent = scan_needles[0].needle;
    const dram_bytes = std.mem.sliceAsBytes(dram_buf);
    const stages = [_]Stage{
        measureContiguous(io, "matched dual-window control", dram_bytes, absent, true),
        measureContiguous(io, "production contiguous", dram_bytes, absent, false),
    };
    std.debug.print("\nmatched scan ladder over the DRAM buffer (logical input GB/s):\n", .{});
    for (stages) |stage| {
        std.debug.print("  {d:>6.1} GB/s · median {d:>6.1} · {s}\n", .{ stage.gbps_max, stage.gbps_median, stage.name });
    }

    // Production over the real corpus completes the ladder. The same process and
    // timing method make ratios useful; none of these sub-ceiling points is called
    // a saturated hardware bound.
    const roots = try corpus_mod.resolveRoots(gpa);
    defer corpus_mod.freeRoots(gpa, roots);
    var corpus = try corpus_mod.load(gpa, io, roots);
    defer corpus.deinit();
    const corpus_mib = @as(f64, @floatFromInt(corpus.bytes)) / (1 << 20);
    var scans = scan_needles;
    std.debug.print("\ngist SIMD scan over {d} files · {d:.1} MiB (single-thread `contains`):\n", .{ corpus.docs.len, corpus_mib });
    for (&scans) |*s| {
        s.gbps = measureGistScan(io, &corpus, s.needle);
        std.debug.print("  {d:>6.1} GB/s = {d:>4.0}% of DRAM ceiling · {s}\n", .{ s.gbps, s.gbps / dram.gbps_max * 100.0, s.kind });
    }

    try writeJson(gpa, io, tiers[0..], clk.ghz, clk.source, dram_cpb, l2_cpb, stages[0..], scans[0..], corpus_mib);
    std.debug.print("\nwrote {s}/roofline.json — run bench/roofline/roofline_report.py to splice Layer C\n", .{out_dir});
    if (!meter.has_pmu) std.debug.print("note: clock assumed (GB/s is frequency-free; cyc/byte derived). Re-run `sudo` for a measured clock.\n", .{});
}

fn writeJson(
    gpa: std.mem.Allocator,
    io: std.Io,
    tiers: []const Tier,
    ghz: f64,
    ghz_source: []const u8,
    dram_cpb: f64,
    l2_cpb: f64,
    stages: []const Stage,
    scans: []const ScanResult,
    corpus_mib: f64,
) !void {
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);
    var line: [512]u8 = undefined;

    try j.appendSlice(gpa, "{\n");
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"machine\": \"{s}\",\n", .{@tagName(builtin.target.cpu.arch)}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"zig\": \"{s}\",\n", .{builtin.zig_version_string}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"ghz\": {d:.4},\n", .{ghz}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"ghz_source\": \"{s}\",\n", .{ghz_source}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"dram_cyc_per_byte_ceiling\": {d:.6},\n", .{dram_cpb}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"l2_cyc_per_byte_ceiling\": {d:.6},\n", .{l2_cpb}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"corpus_mib\": {d:.1},\n", .{corpus_mib}));
    try j.appendSlice(gpa, "  \"tiers\": [\n");
    for (tiers, 0..) |t, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"name\": \"{s}\", \"bytes\": {d}, \"gbps\": {d:.3}, \"gbps_median\": {d:.3} }}{s}\n", .{
            t.name, t.bytes, t.gbps_max, t.gbps_median, if (i + 1 < tiers.len) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ],\n");
    try j.appendSlice(gpa, "  \"matched_ladder\": [\n");
    for (stages, 0..) |stage, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"name\": \"{s}\", \"gbps\": {d:.3}, \"gbps_median\": {d:.3} }}{s}\n", .{
            stage.name, stage.gbps_max, stage.gbps_median, if (i + 1 < stages.len) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ],\n");
    try j.appendSlice(gpa, "  \"gist_scan\": [\n");
    for (scans, 0..) |s, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"needle\": \"{s}\", \"kind\": \"{s}\", \"gbps\": {d:.3} }}{s}\n", .{
            s.needle, s.kind, s.gbps, if (i + 1 < scans.len) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ]\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/roofline.json", .data = j.items });
}

test "streamSum reduces every word (checksum matches scalar)" {
    var buf: [STEP * 4 + 3]u64 = undefined;
    var expect: u64 = 0;
    for (&buf, 0..) |*x, i| {
        x.* = @as(u64, i) *% 0x9E3779B97F4A7C15 +% 1;
        expect +%= x.*;
    }
    try std.testing.expectEqual(expect, streamSum(&buf));
}
