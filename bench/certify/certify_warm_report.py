#!/usr/bin/env python3
"""gist certify — warm-tier report (ADR-352 rung 2.5, resident daemon).

Reads the `certify_warm.csv` emitted by `certify_warm.sh` (one row per probe
class: warm gist, cold gist, and each rival's mean ms over the same corpus) and
splices a self-contained **warm tier** section into CERTIFICATE.md between stable
sentinel markers, so it is idempotent across re-mints and survives beside the
cold macroscopic section rather than replacing it.

The warm tier is the regime an agent actually drives: the resident `gist serve`
daemon holds the corpus + trigram index in RAM and, on a quiescent tree, elides
the freshness walk (`seqlock.skip()`). Its honest oracle is COLD gist over the
same default walk (warm == cold, byte-for-byte — the elision-parity invariant),
with csearch/zoekt/rg as timing rivals over the near-identical corpus.

stdlib only.
"""

import argparse
import csv
import math
from pathlib import Path

START = "<!-- WARM-TIER-START -->"
END = "<!-- WARM-TIER-END -->"
HEADER = "## Layer A — warm tier (resident daemon)"


def _f(s: str) -> float | None:
    try:
        return float(s)
    except TypeError, ValueError:
        return None


def _geomean(vals: list[float]) -> float:
    xs = [v for v in vals if v and v > 0]
    return math.exp(sum(map(math.log, xs)) / len(xs)) if xs else 0.0


def render(rows: list[dict], runs: str, warmup: str, roots: str) -> str:
    """Render the warm-tier markdown section from the CSV rows."""
    lines = [
        START,
        HEADER,
        "",
        (
            "_The regime an agent drives: the resident `gist serve` daemon, scoped to the "
            f"same roots ({roots}), answers from a warm in-RAM corpus + trigram index. On a "
            "quiescent tree its FSEvents/inotify watcher stays armed and `seqlock.skip()` "
            "elides the freshness walk; a live edit falls to a scoped reconcile — never stale. "
            f"hyperfine: {runs} runs (+{warmup} warmup). Warm gist is equivalence-checked "
            "against `gist --no-index` over the same default walk — the certified live-scan "
            "ground truth of the elision-parity invariant (`index == --no-index == rg`), so "
            "`warm == --no-index` proves `warm == cold` transitively; the `cold gist` column "
            "separately times index-backed cold. csearch/zoekt/rg are timing rivals over the "
            "near-identical corpus._"
        ),
        "",
        "| class | warm gist ms | cold gist ms | csearch ms | zoekt ms | rg ms | vs cold | vs csearch |",
        "|---|--:|--:|--:|--:|--:|--:|--:|",
    ]

    # Paired speedups: a rival contributes to its geomean ONLY on rows where warm
    # itself was measured, so the ratio compares the same class set (honest even
    # when the equivalence gate excludes a class).
    pairs: dict[str, list[tuple[float, float]]] = {"cold gist": [], "csearch": [], "ripgrep": []}
    warm_vals: list[float] = []
    for r in rows:
        warm, cold = _f(r["warm_ms"]), _f(r["cold_ms"])
        cs, zk, rg = _f(r["csearch_ms"]), _f(r["zoekt_ms"]), _f(r["rg_ms"])

        def cell(v: float | None) -> str:
            return f"{v:.1f}" if v else "—"

        lines.append(
            f"| `{r['class']}` | {cell(warm)} | {cell(cold)} | {cell(cs)} | {cell(zk)} "
            f"| {cell(rg)} | {r['vs_cold']} | {r['vs_csearch']} |"
        )
        if not warm:
            continue
        warm_vals.append(warm)
        for label, rival in (("cold gist", cold), ("csearch", cs), ("ripgrep", rg)):
            if rival:
                pairs[label].append((warm, rival))

    parts = []
    for label, ps in pairs.items():
        gw, gr = _geomean([w for w, _ in ps]), _geomean([r for _, r in ps])
        if gw > 0 and gr > 0:
            parts.append(f"**{gr / gw:.1f}× faster than {label}**")
    measured = f" ({len(warm_vals)}/{len(rows)} classes cleared the equivalence gate)"
    lines += ["", ("Warm geomean" + measured + ": " + " · ".join(parts) + ".") if parts else ""]
    lines += [
        "",
        (
            "> The warm win rests on quiescence: an armed watcher lets the daemon skip the "
            "walk csearch/zoekt discard freshness to avoid — but warm gist re-derives the "
            "authoritative set on any edit, so it stays byte-identical to `gist --no-index` "
            "and ripgrep where those indexed rivals go silently stale (proven in "
            "`bench/gates/index_elision_parity.sh`). On a live, actively-edited tree the "
            "scoped reconcile keeps warm correct at a modest cost above the skip-path figures "
            "here; the cold macroscopic tier above is the freshness-paying floor."
        ),
        END,
    ]
    return "\n".join(lines) + "\n"


def splice(cert: Path, section: str) -> None:
    """Replace the marked warm block if present, else append it at EOF."""
    text = cert.read_text() if cert.exists() else "# gist — Certificate of Optimality\n\n"
    lo, hi = text.find(START), text.find(END)
    if lo != -1 and hi != -1 and hi > lo:
        text = text[:lo] + section + text[hi + len(END) :].lstrip("\n")
        if not text.endswith("\n"):
            text += "\n"
    else:
        text = text.rstrip() + "\n\n" + section
    cert.write_text(text)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist warm-tier certificate report")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--runs", default="?")
    ap.add_argument("--warmup", default="?")
    ap.add_argument("--roots", default="?")
    args = ap.parse_args()

    with args.csv.open() as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        print("certify_warm_report: empty CSV — nothing to splice")
        return 1

    splice(args.certificate, render(rows, args.runs, args.warmup, args.roots))
    print(f"wrote warm tier → {args.certificate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
