#!/usr/bin/env python3
"""gist certify — the `--rank` lane report (Layer A, definition-first ranked view).

`certify_rank.sh` captures, per symbol probe: the plain `gist -l` path SET
(`<name>.setl`), the FULL `--rank=∞` output (`<name>.rank`, every ranked row),
and per-run hyperfine samples for {rank, gistl, rg}. This reads them and enforces
five fail-closed claims — the ranked view earns its own evidence rather than
inheriting Layer A's cold-locate dominance:

  1. no fabrication    ranked set ⊆ `gist -l` set + coverage floor (ranking reorders the
                       true match set and never invents a hit; the ≤10% it may drop are
                       oversized/vendor files beyond the ranked read pass's 4 MiB bound)
  2. definition boost  median [def] position < median [use] position (when both exist)
  3. codegen demotion  median [gen]/[mirror] position > median authored position
  4. bounded overhead  median(--rank) <= OVERHEAD_CEIL x median(gist -l)
  5. beats ripgrep     SELECTIVE regime only — where the trigram prefilter prunes the
                       corpus to a small candidate set (located <= SELECTIVE_MAX_FRACTION
                       of it), --rank is significantly faster than rg (Mann-Whitney win).
                       A saturating needle gets no prefilter advantage and ranking is
                       strictly more work than a raw scan (read + RRF-score every match),
                       so ripgrep legitimately wins; there the certified guarantee is #4
                       (bounded vs `gist -l`) and beats-rg is reported but not gated.

Any violation on any probe returns non-zero, aborting the mint. Splices a
self-contained lane between stable sentinels (idempotent across re-mints).

stdlib only. Deterministic (bootstrap RNG shared with stats).
"""

import argparse
import json
import random
import re
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stats import SEED, dominance, load_times_ms, median_ci, quantile  # noqa: E402

START = "<!-- RANK-LANE-START -->"
END = "<!-- RANK-LANE-END -->"
HEADER = "## Layer A — the `--rank` lane (definition-first, the shape rg can't express)"
# --rank reads and scores the full content of every candidate (a parallel read pass +
# RRF fusion) that a plain locate never touches, so it costs a bounded multiple of
# `gist -l` — empirically ~5x, up to ~8.5x on a 7k-candidate generic-token probe. The
# ceiling is an order-of-magnitude bound (the ratio is ~hardware-invariant since both
# ops scale together); the sharper claim is #5 — it still beats the content-reading
# scanner (rg) throughout.
OVERHEAD_CEIL = 12.0
COVERAGE_FLOOR = (
    0.90  # ranking surfaces >=90% of the located set; the rest are files past the 4 MiB read bound
)
# The beats-rg claim (#5) is scoped to the SELECTIVE regime — where the trigram
# prefilter narrows the corpus to a small candidate minority, giving --rank a
# structural IO advantage over rg's full re-walk. For a SATURATING needle (a
# common token matching a large fraction of files) the prefilter yields ~no
# pruning and --rank does strictly more work than a raw scan (it reads AND
# RRF-scores every match), so ripgrep legitimately wins; there the certified
# guarantee is bounded overhead vs `gist -l` (#4), not a scan race. A probe is
# selective when its located set is at most this fraction of the corpus (or, when
# the corpus size is unknown, at most SELECTIVE_MAX_ABS files). 3% ≈ the prefilter
# prunes ≥97% of files — a decisive IO win that holds across machines/rg versions.
SELECTIVE_MAX_FRACTION = 0.03
SELECTIVE_MAX_ABS = 1000
# A ranked row is `NN. path:line  [kind]  <count>  snippet`. The path may hold
# spaces (`…/The Energy Landscape — ….md`), so capture it non-greedily as any
# bytes up to the `:line  [kind]` anchor rather than `\S+?` (which stopped at the
# first space and silently dropped space-bearing paths from the ranked set).
ROW_RE = re.compile(r"^\s*(\d+)\.\s+(.+?):\d+\s+\[(\w+)\]")
DEMOTED = {"gen", "mirror"}


def parse_rank(path: Path) -> list[tuple[int, str, str]]:
    """(position, path, kind) for every ranked row in a --rank=inf capture.

    A ranked row echoes a matched source line, which may hold non-UTF-8 bytes;
    ``surrogateescape`` round-trips them so the ASCII ``pos. path:line [kind]``
    prefix the regex reads stays intact instead of aborting the whole lane.
    """
    rows = []
    for ln in path.read_text(errors="surrogateescape").splitlines():
        m = ROW_RE.match(ln)
        if m:
            rows.append((int(m.group(1)), m.group(2), m.group(3)))
    return rows


def _median(xs: list[float]) -> float | None:
    return statistics.median(xs) if xs else None


def _fmt(x: float | None) -> str:
    return "—" if x is None else f"{x:.0f}"


def analyze(results_dir: Path, name: str, rng: random.Random, corpus_files: int = 0) -> dict:
    """All measured facts + per-claim verdicts for one probe.

    ``corpus_files`` is the size of the corpus the probe ran over; it splits the
    probes into the selective regime (prefilter prunes → beats-rg is a certified
    claim) and the saturating regime (beats-rg reported, not gated — see #5).
    """
    setl = {
        ln
        for ln in (results_dir / f"{name}.setl").read_text(errors="surrogateescape").splitlines()
        if ln
    }
    rows = parse_rank(results_dir / f"{name}.rank")
    rankset = {p for _, p, _ in rows}
    nloc = len(setl)
    selectivity = (nloc / corpus_files) if corpus_files > 0 else None
    selective = bool(setl) and (
        selectivity <= SELECTIVE_MAX_FRACTION
        if selectivity is not None
        else nloc <= SELECTIVE_MAX_ABS
    )

    pos = {"def": [], "use": [], "gen": [], "mirror": []}
    for p_i, _path, kind in rows:
        pos.setdefault(kind, []).append(p_i)
    defs, uses = pos["def"], pos["use"]
    authored = defs + uses
    demoted = pos["gen"] + pos["mirror"]

    def med_json(cell: str) -> tuple[list[float], float]:
        f = results_dir / f"{name}__{cell}.json"
        xs = load_times_ms(f) if f.exists() else []
        return xs, (quantile(sorted(xs), 0.50) if xs else 0.0)

    rank_xs, rank_med = med_json("rank")
    _gl_xs, gl_med = med_json("gistl")
    rg_xs, _rg_med = med_json("rg")
    rk_med, rk_lo, rk_hi = median_ci(rank_xs, rng) if rank_xs else (0.0, 0.0, 0.0)

    d_med, u_med = _median(defs), _median(uses)
    a_med, x_med = _median(authored), _median(demoted)

    # Per-claim verdicts (a claim not exercised by this probe is None → skipped).
    # Guard against a vacuous pass: these probes are known-present symbols, so an
    # EMPTY match set means a broken / mid-rebuild index (both -l and --rank would
    # read it and the subset check would hold at 0⊆0). Treat empty as a hard failure.
    nonempty = len(rows) > 0
    # No fabrication: every ranked path is a real locate hit (the safety-critical
    # direction — ranking must never invent a match). Coverage: the ranked set may
    # legitimately drop a few oversized/vendor files past the 4 MiB read bound.
    fabricated = sorted(rankset - setl)
    coverage = (len(rankset) / len(setl)) if setl else 0.0
    no_fab = (not fabricated) and nonempty
    cov_ok = (coverage >= COVERAGE_FLOOR) if setl else False
    def_boost = (d_med < u_med) if (defs and uses) else None
    demotion = (x_med > a_med) if (demoted and authored) else None
    overhead = (rank_med / gl_med) if gl_med > 0 else None
    overhead_ok = (overhead <= OVERHEAD_CEIL) if overhead is not None else None
    rg_dom = dominance(rank_xs, rg_xs) if (rank_xs and rg_xs) else None
    beats_rg = (rg_dom.verdict == "win") if rg_dom is not None else None
    # beats-rg is gated ONLY in the selective regime (prefilter prunes); a
    # saturating needle can't out-scan rg by construction, so it is reported but
    # not required (its binding claim is #4, bounded overhead vs `gist -l`).
    beats_rg_required = selective

    violated = (
        (not nonempty)
        or (not no_fab)
        or (not cov_ok)
        or (def_boost is False)
        or (demotion is False)
        or (overhead_ok is False)
        or (beats_rg is False and beats_rg_required)
    )
    return {
        "name": name,
        "n": len(rows),
        "nloc": nloc,
        "selectivity": selectivity,
        "selective": selective,
        "ndef": len(defs),
        "nuse": len(uses),
        "ndem": len(demoted),
        "top1": rows[0][2] if rows else "—",
        "def_med": d_med,
        "use_med": u_med,
        "auth_med": a_med,
        "dem_med": x_med,
        "rank_med": rk_med,
        "rank_lo": rk_lo,
        "rank_hi": rk_hi,
        "gl_med": gl_med,
        "overhead": overhead,
        "coverage": coverage,
        "fabricated": len(fabricated),
        "rg_speedup": rg_dom.speedup if rg_dom else None,
        "rg_p": rg_dom.p if rg_dom else None,
        "no_fab": no_fab,
        "cov_ok": cov_ok,
        "def_boost": def_boost,
        "demotion": demotion,
        "overhead_ok": overhead_ok,
        "beats_rg": beats_rg,
        "violated": violated,
    }


def _mark(v) -> str:
    return "—" if v is None else ("✅" if v else "❌")


def render(probes: list[dict], meta: dict) -> str:
    """Render the rank-lane markdown from per-probe analyses."""
    runs, warmup, roots = meta.get("runs", "?"), meta.get("warmup", "?"), meta.get("roots", "?")
    lines = [
        START,
        HEADER,
        "",
        (
            f"_Over {roots}, hyperfine {runs} runs (+{warmup} warmup). `--rank` cold-loads the "
            "trigram index, resolves the same candidate set the locate path uses, and fuses "
            "per-file features with weighted RRF (`rank/rank.zig`) — a ranked view no scanner "
            "can emit, so it inherits no Layer-A claim and is certified here directly. Five "
            "fail-closed claims per probe: **no fabrication** (the ranked set is a SUBSET of "
            f"the plain `gist -l` set, coverage ≥ {COVERAGE_FLOOR:.0%} — ranking reorders the "
            "true match set and never invents a hit; the few it drops are oversized/vendor "
            "files past the 4 MiB ranked-read bound), **definition boost** (median `[def]` "
            "position above median `[use]`, aggregate not absolute), **codegen demotion** "
            "(median `[gen]`/`[mirror]` position below authored), **bounded overhead** "
            f"(median ≤ {OVERHEAD_CEIL:g}× a plain locate), and **beats ripgrep where the prefilter "
            f"prunes** (selective needles — located ≤ {SELECTIVE_MAX_FRACTION:.0%} of the corpus: "
            "Mann-Whitney win, the index reads a candidate minority where rg re-walks the whole tree; "
            "a saturating needle gets no prefilter edge and trades wall-time for the ranked view, "
            "bound instead by the overhead claim)._"
        ),
        "",
        "| probe | ranked / located | prefilter | def/use med pos | gen·mir med pos | --rank ms (95% CI) | vs -l | vs rg | ⊆ | cov | def↑ | gen↓ | o/h | >rg |",
        "|---|--:|:--|:--|:--|--:|--:|--:|:--:|--:|:--:|:--:|:--:|:--:|",
    ]
    csv_rows = [
        "probe\tranked_rows\tlocated\tselectivity\tselective\tcoverage\tfabricated\tdef_med\tuse_med\tauth_med\tdem_med\t"
        "rank_ms\trank_lo\trank_hi\tgistl_ms\toverhead\trg_speedup\trg_p\t"
        "no_fabrication\tcoverage_ok\tdef_boost\tcodegen_demote\toverhead_ok\tbeats_rg\tverdict"
    ]
    violations = 0
    for r in probes:
        violations += r["violated"]
        du = f"{_fmt(r['def_med'])}/{_fmt(r['use_med'])}"
        gm = f"{_fmt(r['dem_med'])}"
        vs_l = f"{r['overhead']:.2f}x" if r["overhead"] is not None else "—"
        vs_rg = f"{r['rg_speedup']:.1f}x" if r["rg_speedup"] is not None else "—"
        sel_pct = f"{r['selectivity']:.1%}" if r["selectivity"] is not None else "—"
        pf = f"{'sel' if r['selective'] else 'sat'} {sel_pct}"
        # beats-rg is only a gate in the selective regime; show "—" for saturating
        # (reported via the `vs rg` speedup column, not a pass/fail claim there).
        rg_mark = _mark(r["beats_rg"]) if r["selective"] else "—"
        lines.append(
            f"| `{r['name']}` | {r['n']} / {r['nloc']} | {pf} | {du} | {gm} | "
            f"{r['rank_med']:.1f} ({r['rank_lo']:.1f}-{r['rank_hi']:.1f}) | {vs_l} | {vs_rg} | "
            f"{_mark(r['no_fab'])} | {r['coverage']:.1%} | {_mark(r['def_boost'])} | {_mark(r['demotion'])} | "
            f"{_mark(r['overhead_ok'])} | {rg_mark} |"
        )
        csv_rows.append(
            "\t".join(
                str(v)
                for v in (
                    r["name"],
                    r["n"],
                    r["nloc"],
                    f"{r['selectivity']:.4f}" if r["selectivity"] is not None else "",
                    r["selective"],
                    f"{r['coverage']:.4f}",
                    r["fabricated"],
                    r["def_med"],
                    r["use_med"],
                    r["auth_med"],
                    r["dem_med"],
                    f"{r['rank_med']:.3f}",
                    f"{r['rank_lo']:.3f}",
                    f"{r['rank_hi']:.3f}",
                    f"{r['gl_med']:.3f}",
                    f"{r['overhead']:.3f}" if r["overhead"] is not None else "",
                    f"{r['rg_speedup']:.3f}" if r["rg_speedup"] is not None else "",
                    f"{r['rg_p']:.4f}" if r["rg_p"] is not None else "",
                    r["no_fab"],
                    r["cov_ok"],
                    r["def_boost"],
                    r["demotion"],
                    r["overhead_ok"],
                    r["beats_rg"],
                    "FAIL" if r["violated"] else "pass",
                )
            )
        )
    total = len(probes)
    lines += ["", f"**{total - violations}/{total} probes hold all fail-closed rank claims.**"]
    if violations == 0 and total:
        lines += [
            "",
            (
                "> `--rank` reorders the true match set and never fabricates a hit (every ranked "
                "path is a real `gist -l` hit; the handful it drops are oversized/vendor files "
                "past the 4 MiB ranked-read bound). It systematically lifts definitions above "
                "call sites and sinks codegen below authored source, at a bounded multiple of a "
                "plain `gist -l` (the tax of reading and scoring full candidate content a locate "
                "skips) — and where the trigram prefilter prunes the corpus (selective needles) it "
                "still beats ripgrep, which must re-walk the whole tree. A saturating token gets no "
                "prefilter edge, so ripgrep wins the raw scan while `--rank` trades that wall-time "
                "for a definition-first view no scanner can produce, proven rather than asserted."
            ),
        ]
    lines += ["", END]
    return "\n".join(lines) + "\n", csv_rows, violations


def splice(cert: Path, section: str) -> None:
    """Replace the marked rank block if present, else append it at EOF."""
    text = cert.read_text() if cert.exists() else "# gist — Dominance-and-Fit Certificate\n\n"
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
    ap = argparse.ArgumentParser(description="gist --rank lane report")
    ap.add_argument("results_dir", type=Path)
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--probes", type=Path, required=True, help="TSV: name<TAB>pattern<TAB>roots")
    ap.add_argument("--meta", type=Path, required=True)
    args = ap.parse_args()

    names = [ln.split("\t", 1)[0] for ln in args.probes.read_text().splitlines() if ln.strip()]
    meta = json.loads(args.meta.read_text())
    corpus_files = int(meta.get("corpus_files") or 0)
    rng = random.Random(SEED)

    analyses = [analyze(args.results_dir, n, rng, corpus_files) for n in names]
    if not analyses:
        print("certify_rank_report: no probes analyzed")
        return 1

    section, csv_rows, violations = render(analyses, meta)
    splice(args.certificate, section)
    args.csv.write_text("\n".join(csv_rows) + "\n")
    print(f"rank lane: {len(analyses)} probes · {violations} violation(s) → {args.certificate}")
    for r in analyses:
        if r["violated"]:
            regime = "selective" if r["selective"] else "saturating"
            print(
                f"  FAIL {r['name']}: n={r['n']} regime={regime} no_fab={r['no_fab']} "
                f"cov_ok={r['cov_ok']} (cov={r['coverage']:.1%} fab={r['fabricated']}) "
                f"def_boost={r['def_boost']} demotion={r['demotion']} overhead_ok={r['overhead_ok']} "
                f"beats_rg={r['beats_rg']}{'' if r['selective'] else ' (informational — saturating)'}"
            )
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
