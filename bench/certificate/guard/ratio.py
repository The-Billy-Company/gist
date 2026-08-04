#!/usr/bin/env python3
"""Gist cold speedup regression gate (principia-style ratios).

Two modes, with floors from `ratio_baseline.json`:

  --committed (default)
      Read the published `certify_macro.csv` medians and assert every class's
      gist/rg speedup plus any configured indexed-rival guards clear their
      floors. Hermetic — no hyperfine, no wall-clock jitter. Exit 2 if the
      committed certificate is still pending regeneration.

  --live
      Re-measure a slim cold slate (gist + rg only, hyperfine min-of-N) on this
      machine and assert the same floors. Hardware cancels because both tools
      run back-to-back. Opt-in via ``GIST_BENCH=1`` / ``python3 bench/certificate/guard/ratio.py``.

Floors sit below the published certificate with noise margin. A real cold-path
regression drops a ratio under its floor and fails; refreshing floors after a
deliberate certify republish is the intentional escape hatch.

Usage:
  python3 bench/certificate/guard/ratio.py
  python3 bench/certificate/guard/ratio.py --live --force
  GIST_BENCH=1 python3 bench/certificate/guard/ratio.py
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import tempfile
from pathlib import Path
from shutil import which

HERE = Path(__file__).resolve().parent
ARTIFACT = HERE.parent / "artifact"
BASELINE = HERE / "ratio_baseline.json"
KERNEL = HERE.parents[2]  # guard → certificate → bench → package root
MACRO = ARTIFACT / "certify_macro.csv"
COMPETE = HERE.parents[1] / "dominance" / "races" / "field.sh"

# Byte-identical to certify.sh / certify.zig probe classes.
PROBES: tuple[tuple[str, str, str], ...] = (
    ("literal-rare", "literal", "pgxpool"),
    ("literal-dotted", "literal", "context.Context"),
    ("literal-common", "literal", "func"),
    ("literal-punct2", "literal", "})"),
    ("regex-decl", "regex", r"func\s+\w+\("),
    ("regex-dotted", "regex", r"pgxpool\.\w+"),
    ("regex-anchored", "regex", r"^func\s"),
    ("regex-classcount", "regex", r"[0-9a-f]{8}-[0-9a-f]{4}"),
    ("regex-alternation", "regex", r"return|continue|break"),
    ("regex-dense-scan", "regex", r"\w{3,8}"),
    ("regex-eol", "regex", r";$"),
    ("regex-litalt", "regex", r"panic|0x"),
)


def _load_floors() -> dict[str, float]:
    doc = json.loads(BASELINE.read_text())
    return {k: float(v) for k, v in doc.items() if not k.startswith("_")}


def _load_rival_floors() -> dict[str, dict[str, float]]:
    doc = json.loads(BASELINE.read_text())
    rivals = doc.get("_rivals", {})
    return {
        rival: {cls: float(floor) for cls, floor in floors.items()}
        for rival, floors in rivals.items()
    }


def _speedups_from_macro(
    path: Path, rival: str = "rg", classes: set[str] | None = None
) -> dict[str, float]:
    """Derive gist-faster ratios from committed medians (rival_ms / gist_ms)."""
    by_class: dict[str, dict[str, float]] = {}
    with path.open(newline="") as source:
        for row in csv.DictReader(source, delimiter="\t"):
            cls, tool = row.get("class", ""), row.get("tool", "")
            if (classes is not None and cls not in classes) or tool not in ("gist", rival):
                continue
            try:
                by_class.setdefault(cls, {})[tool] = float(row["median_ms"])
            except (KeyError, ValueError) as error:
                raise SystemExit(f"{path.name}: bad median for {cls}/{tool}: {error}") from error
    out: dict[str, float] = {}
    for cls, tools in by_class.items():
        if "gist" not in tools or rival not in tools:
            raise SystemExit(f"{path.name}: class {cls!r} missing gist or {rival} median")
        gist_ms, rival_ms = tools["gist"], tools[rival]
        if gist_ms <= 0:
            raise SystemExit(f"{path.name}: non-positive gist median for {cls}")
        out[cls] = rival_ms / gist_ms
    return out


def _assert_floors(speedups: dict[str, float], floors: dict[str, float]) -> list[str]:
    failures: list[str] = []
    for cls, floor in floors.items():
        got = speedups.get(cls)
        if got is None:
            failures.append(f"{cls}: missing speedup (no gist/rg cell)")
        elif got < floor:
            failures.append(f"{cls}: ratio {got:.2f}x < floor {floor:.2f}x")
    return failures


def _report(speedups: dict[str, float], floors: dict[str, float], title: str) -> list[str]:
    print(title)
    for cls, _, _ in PROBES:
        if cls not in floors:
            continue
        floor = floors[cls]
        got = speedups.get(cls, 0.0)
        mark = "ok" if got >= floor else "REGRESSION"
        print(f"  {cls:22s} {got:5.2f}x  (floor {floor:.2f}x)  [{mark}]")
    return _assert_floors(speedups, floors)


def check_committed() -> int:
    """Validate published macro CSV against committed floors."""
    if (ARTIFACT / "REGENERATE.md").is_file() and not MACRO.is_file():
        print(f"  (certificate pending regeneration at {ARTIFACT} — see REGENERATE.md)")
        return 2
    if not MACRO.is_file():
        print(f"  (no certify_macro.csv at {MACRO} — run certify.sh first)")
        return 2
    floors = _load_floors()
    speedups = _speedups_from_macro(MACRO)
    expected = {cls for cls, _, _ in PROBES}
    if set(speedups) != expected:
        print(f"  FAIL: macro class set {sorted(speedups)} != certificate classes")
        return 1
    failures = _report(
        speedups, floors, "[ratio] committed certify_macro.csv vs ratio_baseline.json"
    )
    for rival, rival_floors in _load_rival_floors().items():
        rival_speedups = _speedups_from_macro(MACRO, rival, set(rival_floors))
        failures.extend(
            _report(
                rival_speedups,
                rival_floors,
                f"[ratio] committed gist vs {rival}",
            )
        )
    if failures:
        print("  FAIL: gist cold speedup regression:\n    " + "\n    ".join(failures))
        return 1
    print("  ok: every class clears its committed floor.")
    return 0


def _hf_min_ms(cmd: str, out_json: Path, *, warmup: int, runs: int) -> float:
    proc = subprocess.run(
        [
            "hyperfine",
            "--style",
            "none",
            "--warmup",
            str(warmup),
            "--runs",
            str(runs),
            "--ignore-failure",
            "--export-json",
            str(out_json),
            cmd,
        ],
        check=False,
        capture_output=True,
        text=True,
        cwd=str(KERNEL),
    )
    if proc.returncode != 0 or not out_json.is_file():
        raise SystemExit(
            f"hyperfine failed ({proc.returncode}): {cmd}\n{proc.stderr or proc.stdout}"
        )
    doc = json.loads(out_json.read_text())
    results = doc.get("results") or []
    if len(results) != 1:
        raise SystemExit(f"expected one hyperfine result for {cmd}")
    times = results[0].get("times") or []
    if not times:
        raise SystemExit(f"no timing samples for {cmd}")
    return min(times) * 1000.0


def _shell_cmd(kind: str, tool: str, pattern: str) -> str:
    helper = "compete_lit_cmd" if kind == "literal" else "compete_rgx_cmd"
    # Patterns are shell-single-quoted; the slate has no embedded single quotes.
    script = f"""
set -euo pipefail
source "{COMPETE}"
cmd="$({helper} {tool} '{pattern}')"
[[ -n "$cmd" && "$cmd" != false ]] || exit 3
printf '%s\\n' "$cmd"
"""
    proc = subprocess.run(
        ["bash", "-c", script],
        check=False,
        capture_output=True,
        text=True,
        cwd=str(KERNEL),
    )
    if proc.returncode != 0:
        raise SystemExit(f"resolve {tool}/{pattern} failed: {proc.stderr or proc.stdout}")
    return proc.stdout.strip()


def check_live(*, warmup: int, runs: int, force: bool) -> int:
    """Re-measure gist vs rg cold and assert floors."""
    if os.environ.get("GIST_BENCH") != "1" and not force:
        print("  skip: set GIST_BENCH=1 (or pass --force) to run live timing")
        return 0
    for binary in ("hyperfine", "rg", "zig"):
        if which(binary) is None:
            print(f"  FAIL: {binary} not on PATH")
            return 1
    floors = _load_floors()
    print("building gist (ReleaseFast) + index…")
    build = subprocess.run(
        ["bash", "-c", f'source "{COMPETE}" && compete_build_gist_index'],
        check=False,
        cwd=str(KERNEL),
    )
    if build.returncode != 0:
        print("  FAIL: compete_build_gist_index")
        return 1

    speedups: dict[str, float] = {}
    print(f"[ratio] live cold gist vs rg (warmup={warmup} runs={runs})")
    with tempfile.TemporaryDirectory(prefix="gist-ratio-") as tmp:
        work = Path(tmp)
        for cls, kind, pattern in PROBES:
            gcmd = _shell_cmd(kind, "gist", pattern)
            rcmd = _shell_cmd(kind, "rg", pattern)
            gist_ms = _hf_min_ms(gcmd, work / f"{cls}__gist.json", warmup=warmup, runs=runs)
            rg_ms = _hf_min_ms(rcmd, work / f"{cls}__rg.json", warmup=warmup, runs=runs)
            speedups[cls] = rg_ms / gist_ms if gist_ms > 0 else 0.0
            print(
                f"  {cls:22s} gist={gist_ms:7.1f}ms  rg={rg_ms:7.1f}ms  "
                f"{speedups[cls]:5.2f}x  (floor {floors[cls]:.2f}x)"
            )

    failures = _report(speedups, floors, "[ratio] live vs ratio_baseline.json")
    if failures:
        print("  FAIL: gist cold speedup regression:\n    " + "\n    ".join(failures))
        return 1
    print("  ok: every live class clears its committed floor.")
    return 0


def main() -> int:
    """CLI entry: committed and/or live ratio regression."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--committed",
        action="store_true",
        help="assert floors against published certify_macro.csv (default if neither flag)",
    )
    ap.add_argument(
        "--live",
        action="store_true",
        help="re-measure cold gist vs rg and assert floors (needs GIST_BENCH=1)",
    )
    ap.add_argument("--force", action="store_true", help="run --live without GIST_BENCH=1")
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--runs", type=int, default=8)
    args = ap.parse_args()
    run_committed = args.committed or not args.live
    rc = 0
    if run_committed:
        rc = max(rc, check_committed())
    if args.live:
        live_rc = check_live(warmup=args.warmup, runs=args.runs, force=args.force)
        if live_rc or args.force or os.environ.get("GIST_BENCH") == "1":
            rc = max(rc, live_rc)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
