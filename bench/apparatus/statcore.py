#!/usr/bin/env python3
"""Shared measurement statistics — bootstrap CIs and a fail-closed dominance verdict.

VENDORED, BYTE-IDENTICAL. This file is the one statistical story the whole
ecosystem tells, and every package that mints a certificate carries its own copy
at `bench/apparatus/statcore.py`. The copies are held byte-identical by a pinned
digest (`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`), because
four independently releasable packages cannot import Python across repository
boundaries and a verdict that means different things in different repos is worse
than no verdict at all. Edit it in one place, run the gate, paste the new digest
into every copy in the same change.

The bodies mirror `bench/apparatus/harness/stats.zig`, so the macroscopic
(process-vs-process) and microscopic (in-process) halves agree by construction.
Fail-closed: a class is a WIN only when the median is lower AND the difference is
significant. Overlap is PARITY; significantly slower is a LOSS. Nothing is
averaged into a win.

Pure math only — no ingestion, no rendering, no argv. A package's own splicer
imports these names and adds its own. stdlib only, and deterministic: the caller
owns the seeded RNG.
"""

import math
import random
from dataclasses import dataclass

ALPHA = 0.05
BOOTSTRAP = 10_000


def quantile(sorted_xs: list[float], p: float) -> float:
    """Type-7 (R/numpy default) linear-interpolated quantile — matches stats.zig."""
    n = len(sorted_xs)
    if n == 0:
        return 0.0
    if n == 1:
        return sorted_xs[0]
    h = p * (n - 1)
    lo = math.floor(h)
    hi = min(lo + 1, n - 1)
    return sorted_xs[lo] + (h - lo) * (sorted_xs[hi] - sorted_xs[lo])


def median_ci(xs: list[float], rng: random.Random) -> tuple[float, float, float]:
    """Median + 95% bootstrap CI (10k resamples) — the precision of the estimate."""
    s = sorted(xs)
    med = quantile(s, 0.50)
    n = len(s)
    meds = []
    for _ in range(BOOTSTRAP):
        resample = sorted(s[rng.randrange(n)] for _ in range(n))
        meds.append(quantile(resample, 0.50))
    meds.sort()
    return med, quantile(meds, 0.025), quantile(meds, 0.975)


def _normal_cdf(x: float) -> float:
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


@dataclass
class Dominance:
    """Dominance value object."""

    verdict: str  # "win" | "parity" | "loss"
    speedup: float  # median(b) / median(a) — >1 means A faster
    p: float
    a_median: float
    b_median: float


def dominance(a: list[float], b: list[float], alpha: float = ALPHA) -> Dominance:
    """Tie-corrected Mann-Whitney U (normal approx, continuity-corrected), then a fail-closed verdict.

    `a`,`b` are costs (lower = faster); a = this engine, b = the rival.

    """
    a_med = quantile(sorted(a), 0.50)
    b_med = quantile(sorted(b), 0.50)
    n1, n2 = len(a), len(b)

    pool = sorted([(v, 0) for v in a] + [(v, 1) for v in b], key=lambda t: t[0])
    total = n1 + n2
    r1 = 0.0
    tie_sum = 0.0
    i = 0
    while i < total:
        j = i + 1
        while j < total and pool[j][0] == pool[i][0]:
            j += 1
        avg_rank = (i + 1 + j) / 2.0  # 1-based average rank for the tie group
        group = j - i
        tie_sum += group**3 - group
        for k in range(i, j):
            if pool[k][1] == 0:
                r1 += avg_rank
        i = j

    u1 = r1 - n1 * (n1 + 1) / 2.0
    mu = n1 * n2 / 2.0
    nn = n1 + n2
    sigma2 = (n1 * n2 / 12.0) * ((nn + 1) - tie_sum / (nn * (nn - 1)))
    sigma = math.sqrt(sigma2) if sigma2 > 0 else 1e-9
    diff = u1 - mu
    cc = diff - 0.5 if diff > 0 else (diff + 0.5 if diff < 0 else 0.0)  # continuity
    z = cc / sigma
    p = min(2.0 * (1.0 - _normal_cdf(abs(z))), 1.0)

    verdict = "parity"
    if p < alpha:
        verdict = "win" if a_med < b_med else "loss"
    speedup = (b_med / a_med) if a_med > 0 else 0.0
    return Dominance(verdict, speedup, p, a_med, b_med)
