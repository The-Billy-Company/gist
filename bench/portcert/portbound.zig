//! gist bench — `gist-portbound`: Layer B′ of the dominance-and-fit certificate —
//! the **port bound, measured on this machine**.
//!
//! Layer B (`portcert.sh`) is a *static* llvm-mca bound on gist's two hot loops,
//! necessarily taken on reference cores (znver4 / neoverse-v2) because LLVM has
//! no real scheduling model for any Apple CPU (LLVM issue #63698). That leaves a
//! disclosed truth gap: the "at the hardware limit" claim was cross-checked on
//! *other* microarchitectures, never measured on the machine the certificate is
//! minted on. This runner closes it empirically: it executes the **same
//! drift-guarded probes** (`probes/simd_contains.zig`, `probes/dfa_step.zig` —
//! bit-identical to production per `probes_test.zig`) as standalone timed
//! kernels on THIS machine under the PMU, deriving
//!   * `simd_contains` — measured **cycles/byte** of the throughput-bound vector
//!     filter over an L1-resident, guaranteed-miss haystack (steady-state hot
//!     loop, no survivor verification, memory never binds), and
//!   * `dfa_step` — measured **cycles/step** of the latency-bound transition
//!     recurrence `s = trans_in[s + class[b]]` over a match-free document
//!     (1 byte per step, the dependent-load chain is the floor).
//!
//! Honesty rules (all inherited from `pmu.zig` / the certificate discipline):
//!   * **Fail-closed on cycles.** Without the PMU (xnu gates kpc to root) the
//!     run still completes and reports wall-clock ns, but the JSON says
//!     `"pmu": false` and the certificate labels cycles as *NOT measured on
//!     this machine* — it never converts wall-clock to cycles via an assumed
//!     frequency. Re-run under `sudo` for the measured figures.
//!   * **Provenance stamped**: CPU brand (`machdep.cpu.brand_string`), the
//!     P-core note (USER_INTERACTIVE QoS request + the *measured* effective GHz,
//!     which itself distinguishes a P-core from an E-core placement), and the
//!     PMU source ride in the JSON and the spliced section.
//!   * **Counter reads stay exactly two per trial** (start/stop around the
//!     sweep loop); nothing executes inside a timed window that isn't the probe.
//!   * The asm `LLVM-MCA-BEGIN/END` markers inside the probes are assembly
//!     *comments* — zero instructions at runtime; their register operands pin
//!     values the loop needs live anyway. The production `simd.contains` is
//!     timed alongside as a marker-overhead cross-check.
//!
//! Output: stdout table + `.local/gist-verify/portbound.json`. Re-run
//! `bench/portcert/portcert.sh` (or `portcert_report.py`) afterward to splice
//! the measured subsection into `CERTIFICATE.md`.

const std = @import("std");
const builtin = @import("builtin");
const gist = @import("irregex");
const pmu = @import("pmu"); // bench/harness/pmu.zig, wired as a module in build.zig

const simd_probe = @import("probes/simd_contains.zig");
const dfa_probe = @import("probes/dfa_step.zig");

const Regex = gist.regex.Regex;
const out_dir = gist.home.default_out_dir;
const Span = gist.assay.Span; // package instrumentation floor: monotonic Span

// Best-of-N: interference from coworking agents on this shared box only ever
// *slows* a trial, so the min cycles (and min ns) across trials is the cleanest
// estimate of the true per-core cost (same rationale as bench/roofline).
const trials = 9;

// simd_contains working set: well inside the P-core L1D (128 KiB on M-series),
// so the loop is bound by ports, never by the memory hierarchy — the same
// regime llvm-mca's static bound describes. Filled from 'a'..'p', while the
// needle's first/last bytes ('Z','!') never occur, so the vector compare masks
// are zero every stride and the loop runs its pure steady state (no survivor
// verify), exactly the marked region Layer B scores.
const simd_hay_bytes = 32 << 10;
const simd_needle = "ZgistPortbound!"; // first 'Z', last '!' — absent from fill
const simd_sweeps = 1024; // ~32 MiB filtered per trial

// dfa_step working set: match-free by construction for the probed pattern —
// the alphabet is lowercase alnum with NO '-', and the pattern requires a '-'
// after 8 hex digits, so `is_match` is unreachable while the hex-run states
// still wander (varied transitions, no trivially-predictable fixed point).
// No '\n' either, so every byte takes exactly one recurrence step.
const dfa_pattern = "[0-9a-f]{8}-[0-9a-f]{4}";
const dfa_doc_bytes = 256 << 10;
const dfa_sweeps = 64; // ~16 M recurrence steps per trial

var sink: usize = 0; // defeat dead-code elimination of the measured kernels

/// One measured result. `cyc_per_unit`/`ipc`/`ghz` are zero unless `has_pmu` —
/// never derived from wall-clock (that would be fabricated precision).
const Sample = struct {
    cyc_per_unit: f64,
    ns_per_unit: f64,
    ipc: f64,
    ghz: f64, // measured effective clock = Δcycles ÷ Δns (P-core tell-tale)
    has_pmu: bool,
};

/// Best-of-`trials` measurement of `body(ctx)`, attributing cost to
/// `units_per_trial` (bytes or recurrence steps). Exactly two counter reads
/// bracket each trial; the min across trials is reported (least interference).
fn measure(io: std.Io, meter: *pmu.Meter, units_per_trial: f64, ctx: anytype, comptime body: fn (@TypeOf(ctx)) void) Sample {
    var best_cyc = std.math.inf(f64);
    var best_ns = std.math.inf(f64);
    var best_ipc: f64 = 0;
    var best_ghz: f64 = 0;

    body(ctx); // warm the working set + branch predictors, untimed

    for (0..trials) |_| {
        const c0 = meter.counters();
        const sp = Span.open(io);
        body(ctx);
        const ns: f64 = @floatFromInt(@max(sp.read(io).ns(), 1));
        const c1 = meter.counters();

        best_ns = @min(best_ns, ns);
        if (meter.has_pmu and c0.valid and c1.valid) {
            const cyc: f64 = @floatFromInt(c1.cycles -% c0.cycles);
            const ins: f64 = @floatFromInt(c1.instructions -% c0.instructions);
            if (cyc > 0 and cyc < best_cyc) {
                best_cyc = cyc;
                best_ipc = ins / cyc;
                best_ghz = cyc / ns;
            }
        }
    }

    const measured = meter.has_pmu and best_cyc < std.math.inf(f64);
    return .{
        .cyc_per_unit = if (measured) best_cyc / units_per_trial else 0,
        .ns_per_unit = best_ns / units_per_trial,
        .ipc = if (measured) best_ipc else 0,
        .ghz = if (measured) best_ghz else 0,
        .has_pmu = measured,
    };
}

// ── the three timed bodies (each: sweeps × one probe call, nothing else) ──────

const SimdCtx = struct { hay: []const u8, use_production: bool };

fn simdBody(ctx: SimdCtx) void {
    for (0..simd_sweeps) |_| {
        const hit = if (ctx.use_production)
            gist.simd.contains(ctx.hay, simd_needle)
        else
            simd_probe.portcert_simd_contains(ctx.hay.ptr, ctx.hay.len, simd_needle.ptr, simd_needle.len);
        sink +%= @intFromBool(hit);
    }
}

const DfaCtx = struct { doc: []const u8, d: *const gist.regex_dfa.Dfa };

fn dfaBody(ctx: DfaCtx) void {
    const d = ctx.d;
    for (0..dfa_sweeps) |_| {
        const hit = dfa_probe.portcert_dfa_step(
            ctx.doc.ptr,
            ctx.doc.len,
            d.trans_in.ptr,
            d.trans_fin.ptr,
            &d.class,
            d.is_match.ptr,
            d.start,
            d.dead,
            d.anchored,
            d.empty_match,
        );
        sink +%= @intFromBool(hit);
    }
}

/// Vector-loop iterations `portcert_simd_contains` runs over `hay` (mirrors its
/// `while (i + last_off + vlen <= hay.len) : (i += vlen)` header), so measured
/// cycles are attributed to exactly the bytes the marked region consumes. The
/// <(vlen+last_off) B scalar tail after the loop is included in the cycle count
/// but not the divisor (<0.3% of the working set) — a *conservative* rounding.
fn simdIters(hay_len: usize) usize {
    const vlen = simd_probe.portcert_simd_bytes_per_iter();
    const last_off = simd_needle.len - 1;
    if (hay_len < last_off + vlen) return 0;
    return (hay_len - last_off - vlen) / vlen + 1;
}

fn fmtOpt(buf: []u8, v: f64, comptime unit: []const u8, measured: bool) []const u8 {
    if (!measured) return "     —";
    return std.fmt.bufPrint(buf, "{d:>6.4}" ++ unit, .{v}) catch "?";
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io);
}

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var meter = pmu.Meter.init();
    defer meter.deinit();

    // Provenance + P-core bias — once, strictly outside every timed window.
    var brand_buf: [64]u8 = undefined;
    const brand = pmu.cpuBrand(&brand_buf);
    const qos: []const u8 = if (pmu.requestPerformanceQos())
        "USER_INTERACTIVE QoS (P-core-biased)"
    else
        "default QoS (no core bias)";

    std.debug.print("gist portbound · Layer B′ (port bound, measured) · abi v{d}\n", .{gist.abi()});
    std.debug.print("machine: {s} ({s}) · zig {s} · {s}\n", .{ brand, @tagName(builtin.target.cpu.arch), builtin.zig_version_string, qos });
    std.debug.print("meter:   {s}\n", .{meter.note});
    std.debug.print("method:  same drift-guarded probes as Layer B, best-of-{d} trials, cache-resident working sets\n\n", .{trials});

    // ── working sets ──
    const hay = try gpa.alloc(u8, simd_hay_bytes);
    defer gpa.free(hay);
    for (hay, 0..) |*b, k| b.* = 'a' + @as(u8, @intCast(k % 16)); // 'a'..'p': excludes 'Z' and '!'

    var re = try Regex.compile(gpa, dfa_pattern);
    defer re.deinit();
    const dfa = re.dfa orelse return error.PatternHasNoDfa; // fixed pattern — always compiles to a DFA

    const doc = try gpa.alloc(u8, dfa_doc_bytes);
    defer gpa.free(doc);
    var prng = std.Random.DefaultPrng.init(0xB0071D);
    const rng = prng.random();
    for (doc) |*b| {
        const r = rng.uintLessThan(u8, 36); // lowercase alnum, never '-' or '\n'
        b.* = if (r < 10) '0' + r else 'a' + (r - 10);
    }

    // ── measure ──
    const simd_bytes_per_trial: f64 = @floatFromInt(simdIters(hay.len) * simd_probe.portcert_simd_bytes_per_iter() * simd_sweeps);
    const probe_s = measure(io, &meter, simd_bytes_per_trial, SimdCtx{ .hay = hay, .use_production = false }, simdBody);
    const prod_s = measure(io, &meter, simd_bytes_per_trial, SimdCtx{ .hay = hay, .use_production = true }, simdBody);
    const dfa_steps_per_trial: f64 = @floatFromInt(doc.len * dfa_sweeps);
    const dfa_s = measure(io, &meter, dfa_steps_per_trial, DfaCtx{ .doc = doc, .d = dfa }, dfaBody);

    // ── report ──
    var b1: [24]u8 = undefined;
    var b2: [24]u8 = undefined;
    var b3: [24]u8 = undefined;
    std.debug.print("{s:<22} {s:<11} {s:>9} {s:>12} {s:>12} {s:>8} {s:>8}\n", .{ "probe", "bound", "work-set", "cyc/unit", "ns/unit", "IPC", "eff GHz" });
    std.debug.print("{s:-<22} {s:-<11} {s:->9} {s:->12} {s:->12} {s:->8} {s:->8}\n", .{ "", "", "", "", "", "", "" });
    for ([_]struct { name: []const u8, bound: []const u8, ws: usize, s: Sample }{
        .{ .name = "simd_contains", .bound = "throughput", .ws = simd_hay_bytes, .s = probe_s },
        .{ .name = "simd_contains (prod)", .bound = "throughput", .ws = simd_hay_bytes, .s = prod_s },
        .{ .name = "dfa_step", .bound = "latency", .ws = dfa_doc_bytes, .s = dfa_s },
    }) |r| {
        std.debug.print("{s:<22} {s:<11} {d:>5} KiB {s:>12} {d:>9.4} ns {s:>8} {s:>8}\n", .{
            r.name,
            r.bound,
            r.ws >> 10,
            fmtOpt(&b1, r.s.cyc_per_unit, "", r.s.has_pmu),
            r.s.ns_per_unit,
            fmtOpt(&b2, r.s.ipc, "", r.s.has_pmu),
            fmtOpt(&b3, r.s.ghz, "", r.s.has_pmu),
        });
    }

    try writeJson(gpa, io, brand, qos, meter.note, probe_s, prod_s, dfa_s);
    std.debug.print("\nwrote {s}/portbound.json — re-run bench/portcert/portcert.sh to splice Layer B′ into CERTIFICATE.md\n", .{out_dir});
    if (!meter.has_pmu) {
        std.debug.print("note: cycles NOT measured on this machine (PMU needs root) — the artifact says so.\n", .{});
        std.debug.print("      Re-run `sudo pkg/kernels/irregex/zig-out/bin/gist-portbound` from the repo root for the measured bound.\n", .{});
    }
}

fn writeJson(gpa: std.mem.Allocator, io: std.Io, brand: []const u8, qos: []const u8, meter_note: []const u8, probe_s: Sample, prod_s: Sample, dfa_s: Sample) !void {
    try std.Io.Dir.cwd().createDirPath(io, out_dir);
    var j: std.ArrayList(u8) = .empty;
    defer j.deinit(gpa);
    var line: [512]u8 = undefined;

    try j.appendSlice(gpa, "{\n");
    try j.appendSlice(gpa, "  \"layer\": \"B-measured\",\n");
    try j.appendSlice(gpa, "  \"claim\": \"port bound, measured on this machine (same drift-guarded probes as Layer B)\",\n");
    try j.appendSlice(gpa, "  \"generated_by\": \"bench/portcert/portbound.zig (gist-portbound)\",\n");
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"cpu_brand\": \"{s}\",\n", .{brand}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"arch\": \"{s}\",\n", .{@tagName(builtin.target.cpu.arch)}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"qos\": \"{s}\",\n", .{qos}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"pmu\": {},\n", .{probe_s.has_pmu}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"meter\": \"{s}\",\n", .{meter_note}));
    try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "  \"trials\": {d},\n", .{trials}));
    try j.appendSlice(gpa, "  \"results\": [\n");
    for ([_]struct { name: []const u8, bound: []const u8, unit: []const u8, ws: usize, s: Sample }{
        .{ .name = "simd_contains", .bound = "throughput", .unit = "byte", .ws = simd_hay_bytes, .s = probe_s },
        .{ .name = "simd_contains_production", .bound = "throughput", .unit = "byte", .ws = simd_hay_bytes, .s = prod_s },
        .{ .name = "dfa_step", .bound = "latency", .unit = "step", .ws = dfa_doc_bytes, .s = dfa_s },
    }, 0..) |r, i| {
        try j.appendSlice(gpa, try std.fmt.bufPrint(&line, "    {{ \"probe\": \"{s}\", \"bound\": \"{s}\", \"unit\": \"{s}\", \"working_set_bytes\": {d}, \"cyc_per_unit\": {d:.6}, \"ns_per_unit\": {d:.6}, \"ipc\": {d:.4}, \"eff_ghz\": {d:.4}, \"measured\": {} }}{s}\n", .{
            r.name, r.bound, r.unit, r.ws, r.s.cyc_per_unit, r.s.ns_per_unit, r.s.ipc, r.s.ghz, r.s.has_pmu, if (i < 2) "," else "",
        }));
    }
    try j.appendSlice(gpa, "  ]\n}\n");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_dir ++ "/portbound.json", .data = j.items });
}

// ── premise guards (ride `zig build test`) ────────────────────────────────────

test "simd haystack is a guaranteed miss (pure steady-state loop premise)" {
    var hay: [simd_hay_bytes]u8 = undefined;
    for (&hay, 0..) |*b, k| b.* = 'a' + @as(u8, @intCast(k % 16));
    for (hay) |b| {
        try std.testing.expect(b != simd_needle[0]);
        try std.testing.expect(b != simd_needle[simd_needle.len - 1]);
    }
    try std.testing.expect(!simd_probe.portcert_simd_contains(&hay, hay.len, simd_needle.ptr, simd_needle.len));
    try std.testing.expect(simdIters(hay.len) > 0);
}

test "dfa document is match-free and newline-free (one step per byte premise)" {
    const gpa = std.testing.allocator;
    var re = try Regex.compile(gpa, dfa_pattern);
    defer re.deinit();
    const d = re.dfa orelse return error.PatternHasNoDfa;
    try std.testing.expect(!d.anchored);

    var doc: [4096]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xB0071D);
    const rng = prng.random();
    for (&doc) |*b| {
        const r = rng.uintLessThan(u8, 36);
        b.* = if (r < 10) '0' + r else 'a' + (r - 10);
    }
    for (doc) |b| try std.testing.expect(b != '\n' and b != '-');
    try std.testing.expect(!dfa_probe.portcert_dfa_step(
        &doc,
        doc.len,
        d.trans_in.ptr,
        d.trans_fin.ptr,
        &d.class,
        d.is_match.ptr,
        d.start,
        d.dead,
        d.anchored,
        d.empty_match,
    ));
}
