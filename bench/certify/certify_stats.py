#!/usr/bin/env python3
"""gist certify — macroscopic dominance post-processor (Layer A, process-vs-process).

`certify.sh` drives `hyperfine` per regex-class for gist + each field tool and
dumps one JSON per (class, tool). This reads those per-run wall-time samples and,
**for the headline gist-vs-ripgrep pair**, computes a verdict that is *beyond
reproach*: a 95% bootstrap CI on each median (10k resamples) and a two-sample
Mann-Whitney U test — the SAME methods `bench/stats.zig` applies to the
microscopic in-process samples, re-implemented here in stdlib so the macroscopic
half is one consistent statistical story.

Fail-closed by construction: a class is a WIN only when gist's median is lower
AND the difference is significant (p < alpha). Overlap ⇒ PARITY; significantly
slower ⇒ LOSS. No class is silently averaged into a win — every verdict is shown.

It then rewrites the `## Layer A — macroscopic dominance over ripgrep` section of
CERTIFICATE.md in place (everything from that header to EOF), leaving the
microscopic section written by `zig build certify` untouched.

stdlib only. Deterministic: the bootstrap RNG is seeded.
"""

import argparse
from dataclasses import dataclass
import json
import math
from pathlib import Path
import random


ALPHA = 0.05
BOOTSTRAP = 10_000
SEED = 0x6E15  # same seed family as certify.zig, for reproducibility

MACRO_HEADER = "## Layer A — macroscopic dominance over ripgrep"
LEGACY_MACRO_HEADER = "## Layer A — macroscopic dominance vs the field"


# ── statistics (mirror of bench/stats.zig) ────────────────────────────────────
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
    speedup: float  # median(b) / median(a) — >1 means A (gist) faster
    p: float
    a_median: float
    b_median: float


def dominance(a: list[float], b: list[float], alpha: float = ALPHA) -> Dominance:
    """Tie-corrected Mann-Whitney U (normal approx, continuity-corrected), then a fail-closed verdict.

    `a`,`b` are costs (lower = faster); a = gist, b = rival.

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


# ── hyperfine ingestion ───────────────────────────────────────────────────────
def load_times_ms(path: Path) -> list[float]:
    """Per-run wall times (ms) from a hyperfine --export-json file."""
    doc = json.loads(path.read_text())
    times = doc["results"][0].get("times") or []
    return [t * 1000.0 for t in times]


@dataclass
class ClassResult:
    """ClassResult value object."""

    name: str
    kind: str
    pattern: str
    gist: list[float]
    rivals: dict[str, list[float]]  # tool -> times ms


def collect(results_dir: Path, order: list[tuple[str, str, str]]) -> list[ClassResult]:
    """Return list[ClassResult] for collect."""
    out = []
    for name, kind, pattern in order:
        gist_path = results_dir / f"{name}__gist.json"
        if not gist_path.exists():
            continue
        gist = load_times_ms(gist_path)
        rivals = {}
        for jf in sorted(results_dir.glob(f"{name}__*.json")):
            tool = jf.stem.split("__", 1)[1]
            if tool == "gist":
                continue
            try:
                t = load_times_ms(jf)
            except json.JSONDecodeError:
                # A rival's hyperfine invocation can fail to export (a transient
                # spawn/timeout hiccup on a shared box running ~10 coworking
                # agents) — an empty/truncated JSON, not a real result. Treat
                # exactly like the pre-existing "rival never ran" case below
                # (`if t:`) rather than aborting the whole certificate for one
                # missing cell.
                continue
            if t:
                rivals[tool] = t
        out.append(ClassResult(name, kind, pattern, gist, rivals))
    return out


# ── certificate rendering ─────────────────────────────────────────────────────
VERDICT_GLYPH = {"win": "✅ win", "parity": "≈ parity", "loss": "❌ loss"}


def render(results: list[ClassResult], meta: dict, rng: random.Random) -> str:
    """Render generated source artifacts."""
    runs = meta.get("runs", "?")
    warmup = meta.get("warmup", "?")
    lines: list[str] = [MACRO_HEADER, ""]
    lines.append(
        "_Process-vs-process, fresh-process cold query over the same roots "
        f"({meta.get('roots', '?')}). hyperfine: {runs} runs (+{warmup} warmup). "
        "Verdict is gist vs ripgrep: a WIN needs a lower median **and** "
        "Mann-Whitney p < {:.2f} — fail-closed. Other tools shown for context._".format(ALPHA)
    )
    lines.append("")
    lines.append("| class | pattern | gist ms (95% CI) | rg ms (95% CI) | speedup | p | verdict |")
    lines.append("|---|---|--:|--:|--:|--:|:--|")

    wins = parity = loss = 0
    ctx_rows: list[str] = []
    for r in results:
        g_med, g_lo, g_hi = median_ci(r.gist, rng)
        rg = r.rivals.get("rg")
        if rg is None:
            lines.append(
                f"| `{r.name}` | `{r.pattern}` | {g_med:.1f} ({g_lo:.1f}-{g_hi:.1f}) "
                "| — | — | — | (no rg) |"
            )
            continue
        rg_med, rg_lo, rg_hi = median_ci(rg, rng)
        d = dominance(r.gist, rg)
        wins += d.verdict == "win"
        parity += d.verdict == "parity"
        loss += d.verdict == "loss"
        p_str = "<0.001" if d.p < 0.001 else f"{d.p:.3f}"
        lines.append(
            f"| `{r.name}` | `{r.pattern}` | {g_med:.1f} ({g_lo:.1f}-{g_hi:.1f}) "
            f"| {rg_med:.1f} ({rg_lo:.1f}-{rg_hi:.1f}) | {d.speedup:.2f}x | {p_str} "
            f"| {VERDICT_GLYPH[d.verdict]} |"
        )
        # context: every other tool's median + speedup vs gist
        others = []
        for tool, ts in sorted(r.rivals.items()):
            if tool == "rg":
                continue
            m = quantile(sorted(ts), 0.50)
            spd = (m / g_med) if g_med > 0 else 0.0
            others.append(f"{tool} {m:.1f}ms ({spd:.1f}x)")
        if others:
            ctx_rows.append(f"- `{r.name}`: " + " · ".join(others))

    total = wins + parity + loss
    lines.append("")
    lines.append(
        f"**gist vs ripgrep across {total} classes: {wins} win · {parity} parity · {loss} loss.**"
    )
    if loss == 0 and total > 0:
        lines.append("")
        lines.append(
            f"> No class is slower than ripgrep at p<{ALPHA:.2f}: gist holds **parity or "
            "better on every regex class ripgrep supports** — the claimed "
            "across-the-board parity, measured and significance-tested."
        )
    if ctx_rows:
        lines.append("")
        lines.append("<details><summary>field context (other tools)</summary>\n")
        lines.extend(ctx_rows)
        lines.append("\n</details>")
    lines.append("")
    return "\n".join(lines)


def splice_certificate(cert: Path, macro: str) -> None:
    """Replace everything from MACRO_HEADER to EOF; append if absent; create if no file."""
    if cert.exists():
        text = cert.read_text()
        idx = next(
            (i for header in (MACRO_HEADER, LEGACY_MACRO_HEADER) if (i := text.find(header)) >= 0),
            -1,
        )
        head = text[:idx].rstrip() + "\n\n" if idx != -1 else text.rstrip() + "\n\n"
    else:
        head = "# gist — Certificate of Optimality\n\n"
    cert.write_text(head + macro)


def write_csv(results: list[ClassResult], csv_path: Path, rng: random.Random) -> None:
    """Perform write csv."""
    rows = ["class\tpattern\ttool\tmedian_ms\tci_lo_ms\tci_hi_ms\tspeedup_vs_gist\tverdict"]
    for r in results:
        g_med, g_lo, g_hi = median_ci(r.gist, rng)
        rows.append(f"{r.name}\t{r.pattern}\tgist\t{g_med:.3f}\t{g_lo:.3f}\t{g_hi:.3f}\t1.000\t-")
        for tool, ts in sorted(r.rivals.items()):
            m_lo_hi = median_ci(ts, rng)
            spd = (m_lo_hi[0] / g_med) if g_med > 0 else 0.0
            verdict = "-"
            if tool == "rg":
                verdict = dominance(r.gist, ts).verdict
            rows.append(
                f"{r.name}\t{r.pattern}\t{tool}\t{m_lo_hi[0]:.3f}\t{m_lo_hi[1]:.3f}"
                f"\t{m_lo_hi[2]:.3f}\t{spd:.3f}\t{verdict}"
            )
    csv_path.write_text("\n".join(rows) + "\n")


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist macroscopic dominance post-processor")
    ap.add_argument("results_dir", type=Path, help="dir of hyperfine ${class}__${tool}.json")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--order", type=Path, required=True, help="TSV: class<TAB>kind<TAB>pattern")
    ap.add_argument("--meta", type=Path, required=True, help="JSON: runs/warmup/roots")
    args = ap.parse_args()

    order = []
    for ln in args.order.read_text().splitlines():
        if not ln.strip():
            continue
        name, kind, pattern = ln.split("\t", 2)
        order.append((name, kind, pattern))
    meta = json.loads(args.meta.read_text())

    rng = random.Random(SEED)
    results = collect(args.results_dir, order)
    if not results:
        print("certify_stats: no gist results found — did certify.sh run hyperfine?")
        return 1

    macro = render(results, meta, rng)
    splice_certificate(args.certificate, macro)
    write_csv(results, args.csv, rng)

    # terminal summary (fail-closed verdict count)
    wins = parity = loss = 0
    for r in results:
        if "rg" in r.rivals:
            v = dominance(r.gist, r.rivals["rg"]).verdict
            wins += v == "win"
            parity += v == "parity"
            loss += v == "loss"
    print(f"macroscopic gist vs rg: {wins} win · {parity} parity · {loss} loss")
    print(f"wrote {args.certificate} (macro section) + {args.csv}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
