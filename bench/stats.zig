//! gist bench — the statistics that make a speed claim *beyond reproach* instead
//! of a point estimate. A single mean is uninterpretable (criterion.rs's whole
//! thesis): you need a confidence interval to know the estimate's precision and
//! a significance test to know a difference is real, not box noise.
//!
//! Provided:
//!   * `summary` — min / median / p95 / p99 / mean over a sample, with a
//!     **95% bootstrap CI on the median** (10k resamples, seeded ⇒ reproducible;
//!     a CI needs no distributional assumption, unlike mean±stddev).
//!   * `tukeyOutliers` — count mild/severe outliers via Tukey's fences
//!     (q1−1.5·IQR / q3+3·IQR), the same classifier criterion.rs uses, so a
//!     noisy run is *flagged*, not silently averaged in.
//!   * `dominance` — a two-sample **Mann-Whitney U** test (normal approx) that
//!     asks "is A stochastically faster than B?" and returns a verdict that is
//!     **fail-closed**: a WIN requires a lower median AND a real effect
//!     (p < α). Overlap ⇒ PARITY; significantly slower ⇒ LOSS. No vibes.
//!
//! Inputs are `f64` samples (ns or cycles per query). Lower is better
//! throughout (these are costs).

const std = @import("std");

pub const Summary = struct {
    n: usize,
    min: f64,
    median: f64,
    p95: f64,
    p99: f64,
    mean: f64,
    ci_lo: f64, // 95% bootstrap CI on the median
    ci_hi: f64,
    outliers_mild: usize,
    outliers_severe: usize,
};

pub const Verdict = enum { win, parity, loss };

pub const Dominance = struct {
    verdict: Verdict,
    speedup: f64, // median(b) / median(a) — >1 means A faster
    p: f64, // two-sided Mann-Whitney p-value
    a_median: f64,
    b_median: f64,
};

/// p-quantile of an ascending sample via linear interpolation (type-7, R/numpy
/// default) — the estimator criterion.rs reports.
pub fn quantile(sorted: []const f64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const h = p * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(h));
    const hi: usize = @min(lo + 1, sorted.len - 1);
    const frac = h - @floor(h);
    return sorted[lo] + frac * (sorted[hi] - sorted[lo]);
}

fn mean(xs: []const f64) f64 {
    var s: f64 = 0;
    for (xs) |x| s += x;
    return s / @as(f64, @floatFromInt(xs.len));
}

/// Full summary + 95% bootstrap CI on the median. `scratch` must hold ≥
/// `samples.len` f64 (one resample buffer, reused across iterations).
pub fn summarize(samples: []f64, scratch: []f64, rng: std.Random) Summary {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    const med = quantile(samples, 0.50);
    const q1 = quantile(samples, 0.25);
    const q3 = quantile(samples, 0.75);
    const iqr = q3 - q1;
    const f_mild_lo = q1 - 1.5 * iqr;
    const f_mild_hi = q3 + 1.5 * iqr;
    const f_sev_lo = q1 - 3.0 * iqr;
    const f_sev_hi = q3 + 3.0 * iqr;
    var mild: usize = 0;
    var severe: usize = 0;
    for (samples) |x| {
        if (x < f_sev_lo or x > f_sev_hi) {
            severe += 1;
        } else if (x < f_mild_lo or x > f_mild_hi) {
            mild += 1;
        }
    }

    // Bootstrap the median: resample-with-replacement B times, collect medians,
    // take the central 95%. Reuses `scratch` for each resample.
    const B = 10_000;
    var meds: [B]f64 = undefined;
    const n = samples.len;
    for (0..B) |b| {
        for (0..n) |i| scratch[i] = samples[rng.uintLessThan(usize, n)];
        std.mem.sort(f64, scratch[0..n], {}, std.sort.asc(f64));
        meds[b] = quantile(scratch[0..n], 0.50);
    }
    std.mem.sort(f64, meds[0..], {}, std.sort.asc(f64));

    return .{
        .n = n,
        .min = samples[0],
        .median = med,
        .p95 = quantile(samples, 0.95),
        .p99 = quantile(samples, 0.99),
        .mean = mean(samples),
        .ci_lo = quantile(meds[0..], 0.025),
        .ci_hi = quantile(meds[0..], 0.975),
        .outliers_mild = mild,
        .outliers_severe = severe,
    };
}

/// Mann-Whitney U (rank-sum) with tie-corrected normal approximation, then a
/// fail-closed verdict at significance `alpha`. `a` and `b` are cost samples
/// (lower = faster); both are sorted in place. `ranks` scratch ≥ a.len+b.len.
pub fn dominance(a: []f64, b: []f64, ranks: []f64, alpha: f64) Dominance {
    std.mem.sort(f64, a, {}, std.sort.asc(f64));
    std.mem.sort(f64, b, {}, std.sort.asc(f64));
    const a_med = quantile(a, 0.50);
    const b_med = quantile(b, 0.50);

    const n1: f64 = @floatFromInt(a.len);
    const n2: f64 = @floatFromInt(b.len);
    const r1 = rankSumA(a, b, ranks);
    const u_a = r1 - n1 * (n1 + 1.0) / 2.0;
    const mu = n1 * n2 / 2.0;
    const tie = tieCorrection(ranks[0 .. a.len + b.len]);
    const nn = n1 + n2;
    var sigma2 = (n1 * n2 / 12.0) * ((nn + 1.0) - tie / (nn * (nn - 1.0)));
    if (sigma2 <= 0) sigma2 = 1e-9;
    const sigma = @sqrt(sigma2);
    // continuity-corrected z toward the mean
    const diff = u_a - mu;
    const cc = if (diff > 0) diff - 0.5 else if (diff < 0) diff + 0.5 else 0;
    const z = cc / sigma;
    const p = 2.0 * (1.0 - normalCdf(@abs(z)));

    var verdict: Verdict = .parity;
    if (p < alpha) verdict = if (a_med < b_med) .win else .loss;
    return .{
        .verdict = verdict,
        .speedup = if (a_med > 0) b_med / a_med else 0,
        .p = if (p > 1.0) 1.0 else p,
        .a_median = a_med,
        .b_median = b_med,
    };
}

/// Sum of A's ranks in the pooled, sorted sample, assigning **average ranks** to
/// ties. Writes the pooled rank vector into `ranks` (used for tie correction).
fn rankSumA(a: []const f64, b: []const f64, ranks: []f64) f64 {
    const Tagged = struct { v: f64, from_a: bool };
    var pool: [4096]Tagged = undefined;
    const total = a.len + b.len;
    std.debug.assert(total <= pool.len);
    var k: usize = 0;
    for (a) |v| {
        pool[k] = .{ .v = v, .from_a = true };
        k += 1;
    }
    for (b) |v| {
        pool[k] = .{ .v = v, .from_a = false };
        k += 1;
    }
    std.mem.sort(Tagged, pool[0..total], {}, struct {
        fn lt(_: void, x: Tagged, y: Tagged) bool {
            return x.v < y.v;
        }
    }.lt);

    var r1: f64 = 0;
    var i: usize = 0;
    while (i < total) {
        var j = i + 1;
        while (j < total and pool[j].v == pool[i].v) j += 1;
        // ranks i..j (1-based) share the average rank
        const avg = (@as(f64, @floatFromInt(i + 1)) + @as(f64, @floatFromInt(j))) / 2.0;
        for (i..j) |t| {
            ranks[t] = @as(f64, @floatFromInt(j - i)); // group size, for tie corr
            if (pool[t].from_a) r1 += avg;
        }
        i = j;
    }
    return r1;
}

/// Σ(tᵢ³ − tᵢ) over tie groups, from the group-size vector left by rankSumA.
fn tieCorrection(group_sizes: []const f64) f64 {
    var sum: f64 = 0;
    var i: usize = 0;
    while (i < group_sizes.len) {
        const t = group_sizes[i];
        sum += t * t * t - t;
        i += @intFromFloat(t);
    }
    return sum;
}

/// Standard-normal CDF via erfc (Abramowitz & Stegun 7.1.26) — accurate to
/// ~1e-7, far tighter than any p-value threshold we test against.
fn normalCdf(x: f64) f64 {
    return 1.0 - 0.5 * erfc(x / std.math.sqrt2);
}

fn erfc(x: f64) f64 {
    const z = @abs(x);
    const t = 1.0 / (1.0 + 0.5 * z);
    const ans = t * @exp(-z * z - 1.26551223 + t * (1.00002368 + t * (0.37409196 +
        t * (0.09678418 + t * (-0.18628806 + t * (0.27886807 + t * (-1.13520398 +
            t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))));
    return if (x >= 0) ans else 2.0 - ans;
}

// ── tests ────────────────────────────────────────────────────────────────────

test "quantile interpolates" {
    var s = [_]f64{ 1, 2, 3, 4 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), quantile(&s, 0.5), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), quantile(&s, 0.0), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), quantile(&s, 1.0), 1e-9);
}

test "summary CI brackets the median" {
    var prng = std.Random.DefaultPrng.init(7);
    var s: [64]f64 = undefined;
    for (&s, 0..) |*x, i| x.* = @floatFromInt(i + 1);
    var scratch: [64]f64 = undefined;
    const r = summarize(&s, &scratch, prng.random());
    try std.testing.expect(r.ci_lo <= r.median and r.median <= r.ci_hi);
    try std.testing.expectEqual(@as(usize, 64), r.n);
}

test "dominance: clearly faster A wins, identical is parity" {
    var ranks: [256]f64 = undefined;
    var fast = [_]f64{ 10, 11, 9, 10, 12, 11, 10, 9, 11, 10 };
    var slow = [_]f64{ 50, 52, 49, 51, 53, 50, 48, 51, 52, 50 };
    const d = dominance(&fast, &slow, &ranks, 0.05);
    try std.testing.expectEqual(Verdict.win, d.verdict);
    try std.testing.expect(d.speedup > 4.0);

    var a2 = [_]f64{ 10, 11, 9, 10, 12, 11, 10, 9, 11, 10 };
    var b2 = [_]f64{ 10, 11, 9, 10, 12, 11, 10, 9, 11, 10 };
    const d2 = dominance(&a2, &b2, &ranks, 0.05);
    try std.testing.expectEqual(Verdict.parity, d2.verdict);
}

test "dominance: slower A is a loss, not hidden" {
    var ranks: [256]f64 = undefined;
    var slow = [_]f64{ 50, 52, 49, 51, 53, 50, 48, 51, 52, 50 };
    var fast = [_]f64{ 10, 11, 9, 10, 12, 11, 10, 9, 11, 10 };
    const d = dominance(&slow, &fast, &ranks, 0.05);
    try std.testing.expectEqual(Verdict.loss, d.verdict);
}
