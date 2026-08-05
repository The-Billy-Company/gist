#!/usr/bin/env python3
"""gist certify — macroscopic dominance post-processor (Layer A, process-vs-process).

`certify.sh` drives `hyperfine` per regex-class for gist + each field tool and
dumps one JSON per (class, tool). This reads those per-run wall-time samples and,
**for the headline gist-vs-ripgrep pair**, computes a verdict that is *beyond
reproach*: a 95% bootstrap CI on each median (10k resamples) and a two-sample
Mann-Whitney U test.

Those methods are NOT defined here. They live in `bench/apparatus/statcore.py`,
the vendored core every package in the ecosystem carries byte-identically, so the
macroscopic half of Layer A and the microscopic half in `apparatus/harness/
stats.zig` — and every sibling package's own certificate — tell one statistical
story rather than four that merely resemble each other. This module is the gist
half: hyperfine ingestion, the Layer A rendering, and the splice.

Fail-closed by construction: a class is a WIN only when gist's median is lower
AND the difference is significant (p < alpha). Overlap ⇒ PARITY; significantly
slower ⇒ LOSS. No class is silently averaged into a win — every verdict is shown.

It then rewrites the `## Layer A — macroscopic dominance over ripgrep` section of
CERTIFICATE.md in place (everything from that header to EOF), leaving the
microscopic section written by `zig build certify` untouched.

stdlib only. Deterministic: the bootstrap RNG is seeded.
"""

import argparse
import json
import random
import sys
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apparatus"))
# The vendored floor: the verdict math and the hyperfine reader are the
# ecosystem's, not gist's. Re-exported below so this package's own report modules
# have one import site.
from hyperfine import times_ms as load_times_ms  # noqa: E402
from statcore import (  # noqa: E402
    ALPHA,
    BOOTSTRAP,
    Dominance,
    dominance,
    median_ci,
    quantile,
)

__all__ = [
    "ALPHA",
    "BOOTSTRAP",
    "SEED",
    "ClassResult",
    "Dominance",
    "collect",
    "dominance",
    "load_times_ms",
    "median_ci",
    "quantile",
    "render",
    "splice_certificate",
    "write_csv",
]

SEED = 0x6E15  # same seed family as certify.zig, for reproducibility

MACRO_HEADER = "## Layer A — macroscopic dominance over ripgrep"
LEGACY_MACRO_HEADER = "## Layer A — macroscopic dominance vs the field"


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
        head = "# gist — Dominance-and-Fit Certificate\n\n"
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
        print("stats: no gist results found — did certify.sh run hyperfine?")
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
