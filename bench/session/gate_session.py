#!/usr/bin/env python3
"""gist resident-session latency gate (ADR-352 rung 2.5).

The warm certificate (`certify_session.sh`) times the honest product path — a
persistent client dialing a `gist serve` daemon once and replaying a slate over
that single connection. This gate turns the published certificate into a
fail-closed regression check, with one principled asymmetry:

  * **Correctness** is NOT gated here. Exact warm==cold==oracle parity is proven
    hermetically by the Zig suite (`serve_test`, `resident_test`,
    `freshness_test`); a live-tree file-count race is the wrong place to assert it.
  * **Latency** is gated — but only on the *armed* fast path. Where a filesystem
    watcher arms the microsecond path (Linux inotify today; macOS FSEvents is the
    next rung), the geomean warm speedup vs ripgrep-cold must clear the committed
    floor. Where no watcher exists, every query reconciles (the freshness tax):
    the certificate reports that number honestly and the gate is report-only,
    because gating a platform's freshness tax against an armed-path floor would be
    a lie, not a regression.

Modes:
  --committed (default)  Read the published `session_macro.csv` + `session_meta.json`
                         and assert the floor if the certificate was armed.
                         Hermetic — no daemon, no timing. Exit 2 if unpublished.
  --live                 Run `certify_session.sh` on THIS machine, then assert.
                         Opt-in via GIST_BENCH=1 (or --force); absolute latency is
                         box-specific, so it never gates CI implicitly.

Usage:
  python3 bench/session/gate_session.py
  GIST_BENCH=1 python3 bench/session/gate_session.py --live
"""

from __future__ import annotations

import argparse
import csv
import json
import os
from pathlib import Path
from shutil import which
import subprocess


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[1]
MACRO = HERE / "session_macro.csv"
META = HERE / "session_meta.json"
BASELINE = HERE / "session_baseline.json"
DRIVER = HERE / "certify_session.sh"


def _floor() -> float:
    return float(json.loads(BASELINE.read_text())["armed_geomean_floor"])


def _rows() -> list[dict[str, str]]:
    fields = ("needle", "d_files", "rg_files", "warm_ms", "rg_ms", "speedup")
    with MACRO.open(newline="") as source:
        return list(csv.DictReader(source, delimiter="\t", fieldnames=fields))


def _geomean(rows: list[dict[str, str]]) -> float:
    import math

    logs: list[float] = []
    for row in rows:
        warm, rgm = float(row["warm_ms"]), float(row["rg_ms"])
        if warm <= 0:
            raise SystemExit(f"non-positive warm p50 for {row['needle']!r}")
        logs.append(math.log(rgm / warm))
    return math.exp(sum(logs) / len(logs)) if logs else 0.0


def _assert_published() -> int:
    if not MACRO.is_file() or not META.is_file():
        print(f"  (no published session certificate at {HERE} — run certify_session.sh)")
        return 2
    rows = _rows()
    if not rows:
        print("  FAIL: empty session_macro.csv")
        return 1
    meta = json.loads(META.read_text())
    geo = _geomean(rows)
    floor = _floor()
    plat, watcher = meta.get("platform", "?"), meta.get("watcher", "?")
    print(f"[session] {len(rows)} needles · geomean warm speedup {geo:.1f}x · {plat} · {watcher}")
    if not meta.get("armed", False):
        print(
            f"  report-only: unarmed platform (freshness tax) — floor {floor:.1f}x not enforced.\n"
            "  The armed-path headline is certified where a watcher arms the fast path (Linux CI)."
        )
        return 0
    if geo < floor:
        print(f"  FAIL: armed geomean {geo:.2f}x < floor {floor:.2f}x")
        return 1
    print(f"  ok: armed geomean {geo:.2f}x clears floor {floor:.2f}x")
    return 0


def _run_live(*, force: bool) -> int:
    if os.environ.get("GIST_BENCH") != "1" and not force:
        print("  skip: set GIST_BENCH=1 (or --force) to run the live session certificate")
        return 0
    for binary in ("hyperfine", "rg", "bash"):
        if which(binary) is None:
            print(f"  FAIL: {binary} not on PATH")
            return 1
    print("running certify_session.sh (build + daemon + slate)…")
    proc = subprocess.run(["bash", str(DRIVER)], check=False, cwd=str(KERNEL))
    if proc.returncode != 0:
        print("  FAIL: certify_session.sh")
        return 1
    return _assert_published()


def main() -> int:
    """CLI entry: committed and/or live session-latency regression."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--committed", action="store_true", help="assert the published certificate (default)")
    ap.add_argument("--live", action="store_true", help="re-run certify_session.sh then assert (needs GIST_BENCH=1)")
    ap.add_argument("--force", action="store_true", help="run --live without GIST_BENCH=1")
    args = ap.parse_args()
    rc = 0
    if args.committed or not args.live:
        rc = max(rc, _assert_published())
    if args.live:
        live_rc = _run_live(force=args.force)
        if live_rc or args.force or os.environ.get("GIST_BENCH") == "1":
            rc = max(rc, live_rc)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
