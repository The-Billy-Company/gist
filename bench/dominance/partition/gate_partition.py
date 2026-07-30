#!/usr/bin/env python3
"""Corpus-partition regression gate — `--docs` vs a hand-assembled `-t` union.

`certify_partition.sh` measures three arms per needle and writes medians only.
This gate turns those medians into a fail-closed floor, and gates the half of
the claim that is not about speed at all.

What is gated, and why each one can rot on its own:

* **Speed.** The geomean of `rg_union_ms / gist_ms`, cold and warm, must clear
  its floor. Deriving the ratios here rather than storing them keeps one source
  of truth for every published number.
* **Precision and recall, on the hermetic fixture.** The mint builds a tree
  holding exactly the shapes where a basename-blind type glob and a genus must
  disagree: build recipes wearing `*.txt`, documents with no extension to name,
  and controls on both sides. Its counts are the same on every machine, so they
  are asserted **exactly** against `fixture_expected.json` — a hand-written
  contract — rather than against a floor. Equality is the right relation here:
  the over-claim going *up* is as much a change of behavior as it going down.
* **A comparable population, on the live tree.** The two walks must still see
  substantially the same corpus, or the classification columns beside them are
  comparing different trees. The live tree's own classification counts are
  reported but NOT floored: the rival union is derived from gist's own docs type
  roster, so on this population the two rosters nearly coincide by construction,
  and the honest claim here is latency and ergonomics. The mechanism is proven on
  the fixture, where the answer cannot drift with the repository.

Not gated here: totality, disjointness, complement, and warm≡cold parity. Those
are set invariants over the live tree and belong to
`bench/conformance/gates/parity/partition_parity.sh`, which asserts them without
timing anything. A latency lane is the wrong place to prove a set identity — and
`certify_partition.sh` already refuses to publish a timing when cold and warm
disagree, so a violation cannot reach these floors in the first place.

Modes:
  --committed (default)  Read the published macro CSV + meta and assert. Hermetic:
                         no hyperfine, no daemon, no tree walk. Exit 2 if the lane
                         was never minted on this machine.
  --live                 Re-mint via certify_partition.sh, then assert. Opt-in
                         behind GIST_BENCH=1 (or --force), because absolute
                         wall-clock is box-specific.

Usage:
  python3 bench/dominance/partition/gate_partition.py
  GIST_BENCH=1 python3 bench/dominance/partition/gate_partition.py --live
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
from pathlib import Path
from shutil import which
import subprocess


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]
MACRO = HERE / "partition_macro.csv"
META = HERE / "partition_meta.json"
BASELINE = HERE / "partition_baseline.json"
EXPECTED = HERE / "fixture_expected.json"
DRIVER = HERE / "certify_partition.sh"

FIELDS = ("needle", "gist_files", "rg_files", "cold_ms", "warm_ms", "rg_ms")


def _rows() -> list[dict[str, str]]:
    with MACRO.open(newline="") as source:
        return [r for r in csv.DictReader(source, delimiter="\t", fieldnames=FIELDS) if r["needle"]]


def _geomean(values: list[float]) -> float:
    return math.exp(sum(map(math.log, values)) / len(values)) if values else 0.0


def _speedups(rows: list[dict[str, str]], arm: str) -> list[float]:
    """rival_ms / gist_ms for one arm, per needle."""
    out: list[float] = []
    for row in rows:
        gist_ms, rg_ms = float(row[arm]), float(row["rg_ms"])
        if gist_ms <= 0:
            raise SystemExit(f"non-positive {arm} for needle {row['needle']!r}")
        out.append(rg_ms / gist_ms)
    return out


def _assert_published() -> int:
    if not MACRO.is_file() or not META.is_file() or not EXPECTED.is_file():
        print(f"  (partition lane never minted here — run {DRIVER.name})")
        return 2
    rows = _rows()
    if not rows:
        print("  FAIL: empty partition_macro.csv")
        return 1
    floors = json.loads(BASELINE.read_text())
    meta = json.loads(META.read_text())
    failures: list[str] = []

    if not meta.get("keep_disabled", False):
        failures.append(
            "the mint did not disable the answer keep — a warm arm timed with it "
            "armed measures a memoized recall, not a search"
        )

    cold = _geomean(_speedups(rows, "cold_ms"))
    warm = _geomean(_speedups(rows, "warm_ms"))
    print(
        f"[partition] {len(rows)} needles · {meta.get('platform', '?')} · "
        f"rival = {meta['rival']['union_types']} rg type names"
    )
    for label, got, key in (
        ("cold vs rg union", cold, "cold_geomean_floor"),
        ("warm vs rg union", warm, "warm_geomean_floor"),
    ):
        floor = float(floors[key])
        mark = "ok" if got >= floor else "REGRESSION"
        print(f"  {label:22s} {got:6.2f}x  (floor {floor:.2f}x)  [{mark}]")
        if got < floor:
            failures.append(f"{label}: {got:.2f}x < floor {floor:.2f}x")

    pops = meta["populations"]
    # The fixture is asserted by EQUALITY against a written-down contract: it is
    # the same tree on every machine, so any movement is a behavior change and
    # deserves a reader, not a floor that absorbs it.
    want = {k: v for k, v in json.loads(EXPECTED.read_text()).items() if k != "note"}
    got_cls = pops["fixture"]["classification"]
    for key, expect in want.items():
        got = got_cls[key]
        mark = "ok" if got == expect else "CHANGED"
        print(f"  fixture {key:30s} {got!s:>16}  (contract {expect})  [{mark}]")
        if got != expect:
            failures.append(f"fixture {key}: {got!r} != contract {expect!r}")

    # The live tree gets the weaker, and only meaningful, assertion: the two tools
    # walked substantially the same files. Without this the columns beside it would
    # be a diff of two different corpora wearing one heading.
    walks = pops["tracked"]["walks"]
    agree = walks["shared"] / max(walks["gist"], walks["rg"])
    floor = float(floors["min_walk_agreement"])
    mark = "ok" if agree >= floor else "DIVERGED"
    print(f"  tracked walk agreement {agree:16.4f}  (floor {floor})  [{mark}]")
    if agree < floor:
        failures.append(f"tracked walk agreement {agree:.4f} < floor {floor}")
    live = pops["tracked"]["classification"]
    print(
        f"  tracked (reported, not floored): over-claim "
        f"{live['over_claimed_by_union']} · rescued {live['rescued_by_genus']}"
    )

    if failures:
        print("  FAIL: the partition's published claim no longer holds:")
        print("    " + "\n    ".join(failures))
        return 1
    print("  ok: every published partition claim clears its floor.")
    return 0


def _run_live(*, force: bool) -> int:
    if os.environ.get("GIST_BENCH") != "1" and not force:
        print("  skip: set GIST_BENCH=1 (or --force) to re-mint the partition lane")
        return 0
    for binary in ("hyperfine", "rg", "zig"):
        if which(binary) is None:
            print(f"  FAIL: {binary} not on PATH")
            return 1
    print("running certify_partition.sh (build + private daemon + slate)…")
    if subprocess.run(["bash", str(DRIVER)], check=False, cwd=str(KERNEL)).returncode != 0:
        print("  FAIL: certify_partition.sh")
        return 1
    return _assert_published()


def main() -> int:
    """CLI entry: committed and/or live partition regression."""
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--committed", action="store_true", help="assert the published lane (default)")
    ap.add_argument("--live", action="store_true", help="re-mint then assert (needs GIST_BENCH=1)")
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
