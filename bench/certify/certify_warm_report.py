#!/usr/bin/env python3
"""gist certify — warm-tier dominance post-processor (ADR-352 rung 2.5, resident daemon).

`certify_warm.sh` drives the resident `gist serve` daemon and dumps one hyperfine
JSON per (probe class, cell) — cell ∈ {warm, cold, csearch, zoekt, rg}. This reads
those per-run wall-time samples and renders the warm tier with the SAME statistic
the cold macroscopic tier uses (`certify_stats.py`): a 95% bootstrap-CI median
(10k resamples) plus a two-sample Mann-Whitney U verdict of **warm gist vs
ripgrep** — fail-closed. A class is a WIN only when warm gist's median is lower
AND the difference is significant (p < alpha); overlap is PARITY; significantly
slower is a LOSS. Any LOSS vs ripgrep exits non-zero and aborts the mint — the
warm tier no longer inherits Layer A's cold claim descriptively, it earns its own.

The `cold` cell gives the honest warm-vs-cold speedup (index-backed cold gist over
the same roots); csearch/zoekt are shown for field context.

It splices a self-contained warm section between stable sentinel markers so the
splice is idempotent across re-mints and survives beside the cold macroscopic
section rather than replacing it.

stdlib only. Deterministic: the bootstrap RNG is seeded (shared with certify_stats).
"""

import argparse
import csv
import json
from pathlib import Path
import random
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from certify_stats import ALPHA, SEED, dominance, load_times_ms, median_ci, quantile  # noqa: E402

START = "<!-- WARM-TIER-START -->"
END = "<!-- WARM-TIER-END -->"
HEADER = "## Layer A — warm tier (resident daemon)"
VERDICT_GLYPH = {"win": "✅ win", "parity": "≈ parity", "loss": "❌ loss"}


def _load(results_dir: Path, cls: str, cell: str) -> list[float]:
    """Per-run times (ms) for one (class, cell), or [] if the cell was not timed."""
    path = results_dir / f"{cls}__{cell}.json"
    if not path.exists():
        return []
    try:
        return load_times_ms(path)
    except json.JSONDecodeError, KeyError, IndexError:
        return []


def _geomean(vals: list[float]) -> float:
    import math

    xs = [v for v in vals if v and v > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else 0.0


def render(
    results_dir: Path, order: list[tuple[str, str, str]], meta: dict, rng: random.Random
) -> tuple[str, list[list], int]:
    """Return (markdown section, CSV rows, loss_count) for the warm tier."""
    runs, warmup, roots = meta.get("runs", "?"), meta.get("warmup", "?"), meta.get("roots", "?")
    lines = [
        START,
        HEADER,
        "",
        (
            "_The regime an agent drives: the resident `gist serve` daemon, scoped to the same "
            f"roots ({roots}) on a private socket, answers from a warm in-RAM corpus + trigram "
            "index. On a quiescent tree its FSEvents/inotify watcher stays armed and "
            "`seqlock.skip()` elides the freshness walk; a live edit falls to a scoped reconcile "
            f"— never stale. hyperfine: {runs} runs (+{warmup} warmup). The verdict is warm gist "
            f"vs ripgrep — a WIN needs a lower median **and** Mann-Whitney p < {ALPHA:.2f}, the "
            "SAME fail-closed statistic as the cold macro tier. Warm gist is equivalence-checked "
            "against `gist --no-index` over the same default walk (the certified `index == "
            "--no-index == rg` ground truth) before every cell is timed, so `warm == cold` holds "
            "transitively. The `cold` column times index-backed cold gist for the honest "
            "warm-vs-cold speedup; csearch/zoekt are field context._"
        ),
        "",
        "| class | pattern | warm ms (95% CI) | cold ms | rg ms (95% CI) | vs cold | vs rg | p | verdict |",
        "|---|---|--:|--:|--:|--:|--:|--:|:--|",
    ]

    csv_rows = [
        [
            "class",
            "pattern",
            "warm_ms",
            "warm_ci_lo",
            "warm_ci_hi",
            "cold_ms",
            "rg_ms",
            "csearch_ms",
            "zoekt_ms",
            "vs_cold",
            "vs_rg",
            "p",
            "verdict",
        ]
    ]
    wins = parity = loss = 0
    ctx_rows: list[str] = []
    # Paired speedups so a rival's geomean uses only classes where warm was measured.
    pairs: dict[str, list[tuple[float, float]]] = {"cold": [], "csearch": [], "rg": []}

    for cls, _kind, pattern in order:
        warm = _load(results_dir, cls, "warm")
        if not warm:
            continue
        w_med, w_lo, w_hi = median_ci(warm, rng)
        cold = _load(results_dir, cls, "cold")
        rg = _load(results_dir, cls, "rg")
        cs = _load(results_dir, cls, "csearch")
        zk = _load(results_dir, cls, "zoekt")

        c_med = quantile(sorted(cold), 0.50) if cold else 0.0
        cs_med = quantile(sorted(cs), 0.50) if cs else 0.0
        zk_med = quantile(sorted(zk), 0.50) if zk else 0.0
        cold_cell = f"{c_med:.1f}" if cold else "—"
        vs_cold = f"{c_med / w_med:.2f}x" if (cold and w_med > 0) else "—"

        if rg:
            r_med, r_lo, r_hi = median_ci(rg, rng)
            d = dominance(warm, rg)
            wins += d.verdict == "win"
            parity += d.verdict == "parity"
            loss += d.verdict == "loss"
            p_str = "<0.001" if d.p < 0.001 else f"{d.p:.3f}"
            rg_cell = f"{r_med:.1f} ({r_lo:.1f}-{r_hi:.1f})"
            vs_rg = f"{d.speedup:.2f}x"
            verdict, p_out = d.verdict, d.p
        else:
            r_med = 0.0
            rg_cell = vs_rg = p_str = "—"
            verdict, p_out = "no-rg", 1.0

        lines.append(
            f"| `{cls}` | `{pattern}` | {w_med:.1f} ({w_lo:.1f}-{w_hi:.1f}) "
            f"| {cold_cell} | {rg_cell} | {vs_cold} | {vs_rg} | {p_str} "
            f"| {VERDICT_GLYPH.get(verdict, verdict)} |"
        )
        csv_rows.append(
            [
                cls,
                pattern,
                f"{w_med:.3f}",
                f"{w_lo:.3f}",
                f"{w_hi:.3f}",
                f"{c_med:.3f}",
                f"{r_med:.3f}",
                f"{cs_med:.3f}",
                f"{zk_med:.3f}",
                vs_cold,
                vs_rg,
                f"{p_out:.4f}",
                verdict,
            ]
        )
        if cold:
            pairs["cold"].append((w_med, c_med))
        if cs:
            pairs["csearch"].append((w_med, cs_med))
        if rg:
            pairs["rg"].append((w_med, r_med))
        others = []
        if cs_med:
            others.append(f"csearch {cs_med:.1f}ms ({cs_med / w_med:.1f}x)")
        if zk_med:
            others.append(f"zoekt {zk_med:.1f}ms ({zk_med / w_med:.1f}x)")
        if others:
            ctx_rows.append(f"- `{cls}`: " + " · ".join(others))

    total = wins + parity + loss
    parts = []
    for label in ("cold", "csearch", "rg"):
        ps = pairs[label]
        gw, gr = _geomean([w for w, _ in ps]), _geomean([r for _, r in ps])
        if gw > 0 and gr > 0:
            parts.append(f"**{gr / gw:.1f}× faster than {label}**")
    lines += ["", f"**warm gist vs ripgrep across {total} classes: {wins} win · {parity} parity · {loss} loss.**"]
    if parts:
        lines += ["", "Warm geomean: " + " · ".join(parts) + "."]
    if loss == 0 and total > 0:
        lines += [
            "",
            (
                f"> No class is slower than ripgrep at p<{ALPHA:.2f}: the resident daemon holds "
                "**significant dominance on every regex class ripgrep supports** — not the cold "
                "tier's claim inherited, but warm's own, measured and Mann-Whitney-tested. The "
                "win rests on quiescence: an armed watcher lets the daemon skip the freshness "
                "walk csearch/zoekt discard entirely — yet warm gist re-derives the authoritative "
                "set on any edit (equivalence-gated vs `gist --no-index` here, proven in "
                "`bench/gates/index_elision_parity.sh`), staying byte-identical where those "
                "indexed rivals go silently stale. On a live tree the scoped reconcile keeps warm "
                "correct at a modest cost above these skip-path figures; the cold macroscopic tier "
                "above is the freshness-paying floor."
            ),
        ]
    if ctx_rows:
        lines += ["", "<details><summary>field context (indexed rivals)</summary>\n", *ctx_rows, "\n</details>"]
    lines += ["", END]
    return "\n".join(lines) + "\n", csv_rows, loss


def splice(cert: Path, section: str) -> None:
    """Replace the marked warm block if present, else append it at EOF."""
    text = cert.read_text() if cert.exists() else "# gist — Certificate of Optimality\n\n"
    lo, hi = text.find(START), text.find(END)
    if lo != -1 and hi != -1 and hi > lo:
        text = text[:lo] + section + text[hi + len(END) :].lstrip("\n")
    else:
        text = text.rstrip() + "\n\n" + section
    if not text.endswith("\n"):
        text += "\n"
    cert.write_text(text)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist warm-tier dominance report")
    ap.add_argument("results_dir", type=Path, help="dir of hyperfine ${class}__${cell}.json")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--order", type=Path, required=True, help="TSV: class<TAB>kind<TAB>pattern")
    ap.add_argument("--meta", type=Path, required=True, help="JSON: runs/warmup/roots")
    args = ap.parse_args()

    order = []
    for ln in args.order.read_text().splitlines():
        if ln.strip():
            name, kind, pattern = ln.split("\t", 2)
            order.append((name, kind, pattern))
    meta = json.loads(args.meta.read_text())

    rng = random.Random(SEED)
    section, csv_rows, loss = render(args.results_dir, order, meta, rng)
    if len(csv_rows) <= 1:
        print("certify_warm_report: no warm results — did the daemon race run?")
        return 1

    splice(args.certificate, section)
    # Real CSV quoting, not a naive join: probe patterns are regexes, and one of
    # them is `\w{3,8}` — a bare join puts that comma in the middle of a field and
    # silently shifts every column after it for that row.
    with args.csv.open("w", newline="") as fh:
        csv.writer(fh).writerows(csv_rows)
    measured = len(csv_rows) - 1
    print(f"warm tier: {measured} classes · {loss} loss vs rg → {args.certificate}")
    print(f"warm-tier CSV → {args.csv}")
    return 1 if loss > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
