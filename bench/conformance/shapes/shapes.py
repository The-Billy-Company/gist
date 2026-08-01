#!/usr/bin/env python3
"""gist CLI-shape admission matrix — parity-first, statistically-gated.

`matrix.toml` declares one row per supported CLI shape across the dimensions a
locator's behavior turns on (mode / flags / walk-scope / emit / selectivity /
pattern-kind). This driver lowers each row into a REAL argv and drives it through
three paths so eligibility and index-elision are measured, not asserted:

  gist cold-indexed   the product default — persisted trigram index + candidate IO
  gist cold-unindexed  `--no-index` live scan (the soundness twin)
  ripgrep              the correctness oracle AND the performance baseline

Three subcommands, one discipline (correctness before speed):

  parity   assert gist-idx == gist-noidx == rg at each row's `bar`
           (set / lines / count) and exit-class parity. Fail-closed: any
           unexpected divergence is a hard error. This is a CI gate.

  bench    time gist-idx vs rg with the certificate's own bootstrap-CI +
           Mann-Whitney verdict (`certificate/report/stats.py`, imported — the
           stats are defined once). `--publish` refreshes baseline.json
           (per-shape floors) + shapes.csv (measured rows) + CERTIFICATE_MATRIX.md.

  gate     assert the committed per-shape floors hermetically (no re-timing),
           mirroring `session/gate_session.py`. One honest asymmetry: a row
           declared `expect="loss"` is report-only (a declared hole lives in
           its own row on purpose, so no aggregate can bury it — currently
           none: every shape is declared win/parity), while any win/parity
           row below its floor is a hard failure. `--live` re-benches first.

Usage:
  matrix.py parity                 # correctness gate (all three paths agree)
  GIST_BENCH=1 matrix.py bench --publish
  matrix.py gate                   # committed floors (hermetic)
  GIST_BENCH=1 matrix.py gate --live
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import random
import shlex
from shutil import which
import subprocess
import sys
import tomllib

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]  # shapes → conformance → bench → repo
REPO = KERNEL
MATRIX = HERE / "shapes.toml"
BASELINE = HERE / "baseline.json"
CSV = HERE / "shapes.csv"
CERT = HERE / "CERTIFICATE_MATRIX.md"

sys.path.insert(0, str(KERNEL / "bench" / "certificate" / "report"))
import stats as S  # noqa: E402 — bootstrap-CI + Mann-Whitney, defined once

# A shape's measured verdict is "off-expect" only when it is WORSE than declared
# (a regression, or a loss hiding under a parity/win label) — never when it beats
# its declaration. A `parity`-declared row measuring `win` is over-delivery, fine;
# a `loss`-declared borderline row measuring `parity` is fine (over-delivery).
# This makes the near-1.0x rows (a literal-less backref does the same full
# PCRE2 scan as rg) robust to which side of the significance line a run lands on.
_RANK = {"loss": 0, "parity": 1, "win": 2}

# Appended to every rendered CERTIFICATE_MATRIX.md. This is prose, not measurement,
# and it lives HERE rather than being hand-written into the .md because `_publish`
# rewrites that file wholesale — a standing requirement kept only in the artifact
# would be silently deleted by the next `bench --publish`, which is exactly the kind
# of quiet erasure it exists to prevent.
STANDING_REQUIREMENT = (
    "",
    "## Standing requirement — the literal set must span the needle space",
    "",
    "`select` names the **prefilter's signal**, not the match count: `selective` (a",
    "discriminating rare byte exists, so a healthy offset selector finds a good pair),",
    "`degenerate` (every byte ties on corpus rarity, so a marginal-rarity selector has",
    "no signal at all), `head-rare` / `tail-rare` (exactly one rare byte, at a known",
    "end). `rare` / `common` are the legacy match-volume labels, kept because committed",
    "floors key on those ids.",
    "",
    "This dimension exists because **the suite could not distinguish prefilter failure",
    "from true-match volume.** The literal kernel picks two byte offsets of the needle",
    "to filter 64-byte blocks on, and that selection collapsed to the adjacent pair",
    "`(0,1)` for any needle whose bytes all tied on rarity — which is most lowercase",
    "identifiers. Measured cost: **18.1 GB/s literal scan where 35.5 GB/s was",
    "achievable** on code, **13.1 vs 33.4 GB/s** on prose; in the shipped binary",
    "`stepSec` (7 B, 464 true matches) ran **41% slower** than `pgxpool` (7 B, 8856",
    "true matches) — vastly more real work, less time. Every literal probe was labelled",
    "`rare` or `common`, so two things went unseen: **`pgxpool` was an",
    "unrepresentatively lucky needle** for the rare class (`pg` is a genuinely rare",
    "digraph, so it selects well and looks fast) and stood in for the whole class; and",
    "the degenerate needles that *were* present (`error` here, `func` in the scanner",
    "lane) had their slowness charged to having many true matches rather than to the",
    "prefilter collapsing.",
    "",
    "**Therefore the literal probe set must always contain a degenerate, low-match",
    "case** (`literal-degenerate-files`, needle `stepSec`) paired with a length-matched",
    "well-selecting control (`literal-selective-control-files`, needle `pgxpool`), plus",
    "the same-class runs over the classes that tie (lower / upper / digit /",
    "punctuation) and the `head-rare` / `tail-rare` pair that exposes end bias. A",
    "degenerate low-match needle is the only probe whose slowness has a single possible",
    "cause: there is no true work to blame it on. **A future edit that drops these rows",
    "is a coverage regression, not a cleanup.**",
    "",
    "One honest limit: the cold-indexed lane above **cannot see the timing defect** —",
    "the trigram index elides most of the corpus for a low-match needle, so the scan",
    "kernel barely runs (trap/control measured 1.04 indexed vs 1.00 un-indexed). The",
    "timing isolation runs in the no-index scanner lane (`races/scanner.sh`,",
    "`SELECTOR_PROBES`); what these rows earn here is **parity**, because a selector",
    "that picks the wrong offset pair is a correctness bug before it is a speed bug.",
    "",
)


def _off_expect(verdict: str, expect: str) -> bool:
    """True when the measured verdict ranks below the declared expectation."""
    return _RANK[verdict] < _RANK[expect]

GIST = Path(os.environ.get("GIST_MATRIX_BIN", KERNEL / "zig-out" / "bin" / "gist"))
RG = os.environ.get("RG", "rg")
# Scope every tool to the same logical corpus (mirrors _compete.sh fairness): no
# VCS walker, the repo root .gitignore as the one shared ignore, unsorted walk.
BASE = ["--no-ignore-vcs", "--ignore-file", str(REPO / ".gitignore"), "--sort", "none"]
# gist's default ~25k-token agent-context output budget would clip a repo-wide
# result and perturb the rg oracle (a product feature, not a search difference);
# every race/gate here compares against rg's uncapped output, so lift the soft cap
# process-wide exactly as _compete.sh does. The hard OOM ceiling stays on.
ENV = {**os.environ, "GIST_UNCAP": "1"}


def load_matrix() -> tuple[list[dict], list[str]]:
    """Return (shapes, default_roots) from matrix.toml."""
    data = tomllib.loads(MATRIX.read_text())
    return data["shape"], data["default_roots"]


def _cmd(binary: str, shape: dict, roots: list[str], *, extra: list[str]) -> list[str]:
    """gist/rg argv: `<bin> <pattern> <flags> <base> <extra> -- <roots>`."""
    flags = shape["gist"] if binary == "gist" else shape["rg"]
    exe = [str(GIST)] if binary == "gist" else [RG]
    return [*exe, shape["pattern"], *flags, *BASE, *extra, "--", *roots]


def _run(cmd: list[str]) -> tuple[int, str]:
    """Run one argv at REPO root; return (exit_code, stdout_text)."""
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=str(REPO), env=ENV)
    return p.returncode, p.stdout


def _canon(bar: str, out: str) -> object:
    """Order-insensitive canonical form of stdout at the row's parity bar."""
    lines = out.splitlines()
    if bar == "count":
        # `path:N` rows → {path: N}, order-independent.
        d: dict[str, str] = {}
        for ln in lines:
            path, _, n = ln.rpartition(":")
            d[path] = n
        return d
    if bar in ("set", "lines"):
        return sorted(lines)
    raise SystemExit(f"unknown bar {bar!r}")


def _exit_class(rc: int) -> int:
    """Rg exit taxonomy collapsed to its class: 0 match / 1 no-match / 2+ error."""
    return rc if rc in (0, 1) else 2


# ── parity ────────────────────────────────────────────────────────────────────
def cmd_parity(shapes: list[dict], default_roots: list[str]) -> int:
    """Assert gist-idx == gist-noidx == rg at each row's bar. Fail-closed gate."""
    if not GIST.exists():
        sys.exit(f"gist not built at {GIST} — run `zig build` in {KERNEL}")
    fails = 0
    for sh in shapes:
        roots = sh.get("roots", default_roots)
        bar = sh["bar"]
        rc_i, out_i = _run(_cmd("gist", sh, roots, extra=[]))
        rc_n, out_n = _run(_cmd("gist", sh, roots, extra=["--no-index"]))
        rc_g, out_g = _run(_cmd("rg", sh, roots, extra=[]))
        ci, cn, cg = (_canon(bar, o) for o in (out_i, out_n, out_g))
        ec = tuple(_exit_class(r) for r in (rc_i, rc_n, rc_g))
        problems = []
        if ci != cn:
            problems.append("gist-idx != gist-noidx (index elision unsound)")
        if ci != cg:
            problems.append(f"gist != rg at bar={bar}")
        if ec[0] != ec[2] or ec[1] != ec[2]:
            problems.append(f"exit class {ec} (idx,noidx,rg) diverges")
        if problems:
            fails += 1
            print(f"  FAIL {sh['id']:34} {' · '.join(problems)}")
        else:
            n = len(ci) if hasattr(ci, "__len__") else "?"
            print(f"  ok   {sh['id']:34} bar={bar:5} agree ({n} rows)")
    print(f"\n{'FAIL' if fails else 'PASS'}: {len(shapes) - fails}/{len(shapes)} shapes agree "
          "(gist-idx == gist-noidx == rg)")
    return 1 if fails else 0


# ── bench ─────────────────────────────────────────────────────────────────────
def _hyperfine(cmd: list[str], warmup: int, runs: int) -> list[float]:
    """Times (ms) for one argv via hyperfine --export-json. [] on failure."""
    import tempfile

    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tf:
        js = Path(tf.name)
    try:
        proc = subprocess.run(
            ["hyperfine", "--output=pipe", "--ignore-failure=1",
             "--warmup", str(warmup), "--runs", str(runs),
             "--export-json", str(js), shlex.join(cmd)],
            capture_output=True, cwd=str(REPO), env=ENV,
        )
        if proc.returncode != 0 or not js.stat().st_size:
            return []
        return S.load_times_ms(js)
    finally:
        js.unlink(missing_ok=True)


def cmd_bench(shapes: list[dict], default_roots: list[str], *, publish: bool, warmup: int,
              runs: int, only: list[str] | None = None) -> int:
    """Time gist-idx vs rg per shape; fail-closed dominance verdict + optional publish."""
    for b in ("hyperfine", RG):
        if which(b) is None:
            sys.exit(f"  need {b} on PATH")
    if not GIST.exists():
        sys.exit(f"gist not built at {GIST}")
    if only:
        shapes = [s for s in shapes if s["id"] in set(only)]
        if not shapes:
            sys.exit(f"  no matrix shape matched --only {only}")
    rng = random.Random(S.SEED)
    rows: list[dict] = []
    print(f"benching {len(shapes)} shapes · gist-idx vs rg · {runs} runs (+{warmup} warmup)\n")
    print(f"{'shape':34} {'gist ms':>9} {'rg ms':>9} {'speedup':>8} {'p':>7}  verdict / expect")
    for sh in shapes:
        roots = sh.get("roots", default_roots)
        g = _hyperfine(_cmd("gist", sh, roots, extra=[]), warmup, runs)
        r = _hyperfine(_cmd("rg", sh, roots, extra=[]), warmup, runs)
        if not g or not r:
            print(f"  {sh['id']:34} (timing failed — skipped)")
            continue
        d = S.dominance(g, r)
        g_med = S.median_ci(g, rng)[0]
        r_med = S.median_ci(r, rng)[0]
        flag = "  ⚠ off-expect" if _off_expect(d.verdict, sh["expect"]) else ""
        p_str = "<0.001" if d.p < 0.001 else f"{d.p:.3f}"
        print(f"  {sh['id']:34} {g_med:9.1f} {r_med:9.1f} {d.speedup:7.2f}x {p_str:>7}  "
              f"{d.verdict}/{sh['expect']}{flag}")
        rows.append({"id": sh["id"], "expect": sh["expect"], "verdict": d.verdict,
                     "speedup": round(d.speedup, 3), "p": round(d.p, 4),
                     "gist_ms": round(g_med, 3), "rg_ms": round(r_med, 3),
                     "dims": sh["dims"]})
    wins = sum(x["verdict"] == "win" for x in rows)
    par = sum(x["verdict"] == "parity" for x in rows)
    loss = sum(x["verdict"] == "loss" for x in rows)
    print(f"\ngist vs rg across {len(rows)} shapes: {wins} win · {par} parity · {loss} loss")
    off = [x["id"] for x in rows if _off_expect(x["verdict"], x["expect"])]
    if off:
        print(f"  OFF-EXPECT ({len(off)}): {', '.join(off)} — a shape measured WORSE than "
              "declared; fix the regression or (if intended) lower matrix.toml `expect`")
    upgrades = [x["id"] for x in rows if _RANK[x["verdict"]] > _RANK[x["expect"]]]
    if upgrades:
        print(f"  upgrade candidates ({len(upgrades)}): {', '.join(upgrades)} — beat their "
              "declared `expect`; raise it after a second clean run")
    if publish:
        _publish(rows, warmup, runs)
    return 1 if off else 0


def _floor(row: dict) -> float:
    """Conservative committed floor for a matrix row.

    0.75× the measured win (≥1.0); a fixed 0.75 parity band; loss rows record
    the measured speedup but are never enforced.
    """
    if row["expect"] == "loss":
        return round(row["speedup"], 3)
    if row["expect"] == "win":
        return max(1.0, round(row["speedup"] * 0.75, 2))
    return 0.75  # parity: gist may be up to 25% slower than rg and still hold the band


def _publish(rows: list[dict], warmup: int, runs: int) -> None:
    """Write matrix_baseline.json (floors) + matrix.csv (rows) + CERTIFICATE_MATRIX.md."""
    floors = {r["id"]: {"expect": r["expect"], "floor": _floor(r), "measured": r["speedup"]} for r in rows}
    BASELINE.write_text(json.dumps(
        {"_comment": "Per-shape committed floors for `matrix.py gate`. win → 0.75× the "
                     "measured speedup (≥1.0); parity → a fixed 0.75× band; loss → recorded, "
                     "report-only (currently none declared). Refresh with "
                     "`GIST_BENCH=1 matrix.py bench --publish` after a deliberate change.",
         "warmup": warmup, "runs": runs, "floors": floors}, indent=2) + "\n")
    hdr = "id\texpect\tverdict\tspeedup\tp\tgist_ms\trg_ms\tfloor"
    lines = [hdr] + [
        f"{r['id']}\t{r['expect']}\t{r['verdict']}\t{r['speedup']}\t{r['p']}"
        f"\t{r['gist_ms']}\t{r['rg_ms']}\t{_floor(r)}" for r in rows
    ]
    CSV.write_text("\n".join(lines) + "\n")
    _render_cert(rows)
    print(f"\npublished → {BASELINE.name} · {CSV.name} · {CERT.name}")


def _render_cert(rows: list[dict]) -> None:
    """Human-readable per-shape certificate (measured wins + the declared loss)."""
    g = {"win": "✅ win", "parity": "≈ parity", "loss": "❌ loss"}
    out = ["# gist CLI-shape admission matrix — measured", "",
           "_gist cold-indexed vs ripgrep over the six host source roots. A WIN needs "
           f"a lower median **and** Mann-Whitney p < {S.ALPHA:.2f} (fail-closed). Parity is "
           "correctness-proven separately (`matrix.py parity`: gist-idx == gist-noidx == rg). "
           "Every shape is a declared win — the former `-U` losses fell to the parallel "
           "multiline DFA and the former backref parity to the PCRE2 shadow gate; a future "
           "declared `loss` would stay report-only in its own row so no aggregate can bury it._", "",
           "| shape | dims | gist ms | rg ms | speedup | p | verdict |",
           "|---|---|--:|--:|--:|--:|:--|"]
    for r in rows:
        d = r["dims"]
        dim = f"{d['mode']}·{d['flags']}·{d['scope']}·{d['emit']}·{d['select']}"
        p_str = "<0.001" if r["p"] < 0.001 else f"{r['p']:.3f}"
        out.append(f"| `{r['id']}` | {dim} | {r['gist_ms']:.1f} | {r['rg_ms']:.1f} "
                   f"| {r['speedup']:.2f}x | {p_str} | {g[r['verdict']]} |")
    wins = sum(x["verdict"] == "win" for x in rows)
    par = sum(x["verdict"] == "parity" for x in rows)
    loss = sum(x["verdict"] == "loss" for x in rows)
    out += ["", f"**{wins} win · {par} parity · {loss} loss** across {len(rows)} shapes.", ""]
    out += STANDING_REQUIREMENT
    CERT.write_text("\n".join(out))


# ── gate ────────────────────────────────────────────────────────────────────
def cmd_gate(shapes: list[dict], default_roots: list[str], *, live: bool, force: bool,
             warmup: int, runs: int) -> int:
    """Assert committed per-shape floors (hermetic), or re-bench first with --live."""
    if live:
        if os.environ.get("GIST_BENCH") != "1" and not force:
            print("  skip: set GIST_BENCH=1 (or --force) to re-bench for --live")
            return 0
        cmd_bench(shapes, default_roots, publish=True, warmup=warmup, runs=runs)
    if not BASELINE.is_file() or not CSV.is_file():
        print(f"  (no committed matrix certificate — run `matrix.py bench --publish`)")
        return 2
    floors = json.loads(BASELINE.read_text())["floors"]
    measured = {}
    for ln in CSV.read_text().splitlines()[1:]:
        f = ln.split("\t")
        measured[f[0]] = {"expect": f[1], "verdict": f[2], "speedup": float(f[3])}
    fails = 0
    print(f"[matrix] {len(measured)} shapes · committed floors")
    for sid, m in measured.items():
        fl = floors.get(sid)
        if fl is None:
            print(f"  FAIL {sid:34} in matrix.csv but absent from matrix_baseline.json")
            fails += 1
            continue
        if m["expect"] == "loss":
            print(f"  note {sid:34} declared loss — report-only ({m['speedup']:.2f}x vs rg)")
            continue
        if m["speedup"] < fl["floor"]:
            print(f"  FAIL {sid:34} {m['speedup']:.2f}x < floor {fl['floor']:.2f}x")
            fails += 1
        else:
            print(f"  ok   {sid:34} {m['speedup']:.2f}x clears floor {fl['floor']:.2f}x")
    print(f"\n{'FAIL' if fails else 'PASS'}: {len(measured) - fails}/{len(measured)} shapes clear their committed floor")
    return 1 if fails else 0


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("parity")
    b = sub.add_parser("bench")
    b.add_argument("--publish", action="store_true")
    b.add_argument("--only", action="append", help="re-measure only this shape id (repeatable; disables --publish)")
    b.add_argument("--warmup", type=int, default=int(os.environ.get("WARMUP", 2)))
    b.add_argument("--runs", type=int, default=int(os.environ.get("RUNS", 8)))
    gt = sub.add_parser("gate")
    gt.add_argument("--live", action="store_true")
    gt.add_argument("--force", action="store_true")
    gt.add_argument("--warmup", type=int, default=int(os.environ.get("WARMUP", 2)))
    gt.add_argument("--runs", type=int, default=int(os.environ.get("RUNS", 8)))
    args = ap.parse_args()
    shapes, roots = load_matrix()
    if args.cmd == "parity":
        return cmd_parity(shapes, roots)
    if args.cmd == "bench":
        publish = args.publish and not args.only
        if args.publish and args.only:
            print("  note: --only re-measures a subset; refusing to overwrite the full baseline (publish skipped)")
        return cmd_bench(shapes, roots, publish=publish, warmup=args.warmup, runs=args.runs, only=args.only)
    return cmd_gate(shapes, roots, live=args.live, force=args.force, warmup=args.warmup, runs=args.runs)


if __name__ == "__main__":
    raise SystemExit(main())
