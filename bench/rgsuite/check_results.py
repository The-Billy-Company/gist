#!/usr/bin/env python3
"""rgsuite anti-staleness gate.

The rgsuite README is a human-written summary of `results.json`; the two drifted
once already (README claimed 0 FAIL / 100% while the committed results held 4
FAIL). This gate makes that drift a hard failure and pins the rules a reviewer
would otherwise check by hand:

  * the README's PASS/ORDER/FAIL/NA/SKIP counts equal the counts in results.json;
  * the README's "supported-surface parity" fraction/percent is arithmetically
    consistent with those counts ((PASS+ORDER)/(PASS+ORDER+FAIL));
  * every FAIL row carries a non-empty `detail` (a documented divergence, not a
    silent `null`);
  * FAIL == 0 unless `--allow-fail` is passed (so a not-yet-clean suite is
    explicit, never accidental).

Usage: check_results.py [--allow-fail] [--results PATH] [--readme PATH]
Exit 0 iff every rule holds (and, without --allow-fail, FAIL == 0).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BUCKETS = ("PASS", "ORDER", "FAIL", "NA", "SKIP")
HERE = Path(__file__).resolve().parent


def load_counts(results_path: Path) -> tuple[dict[str, int], list[dict]]:
    rows = json.loads(results_path.read_text())
    counts = {b: 0 for b in BUCKETS}
    for r in rows:
        b = r.get("bucket")
        if b not in counts:
            sys.exit(f"results.json: unknown bucket {b!r} in case {r.get('name')!r}")
        counts[b] += 1
    return counts, rows


def readme_counts(readme_path: Path) -> tuple[dict[str, int], tuple[int, int, float] | None]:
    text = readme_path.read_text()
    counts: dict[str, int] = {}
    for b in BUCKETS:
        # Match a table row naming the bucket (optionally **bolded**) then its int.
        m = re.search(rf"\|\s*\*{{0,2}}{b}\*{{0,2}}\s*\|\s*(\d+)", text)
        if m:
            counts[b] = int(m.group(1))
    parity = None
    m = re.search(r"=\s*(\d+)\s*/\s*(\d+)\s*=\s*([\d.]+)\s*%", text)
    if m:
        parity = (int(m.group(1)), int(m.group(2)), float(m.group(3)))
    return counts, parity


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--allow-fail", action="store_true", help="tolerate FAIL > 0 (still requires every FAIL to be documented)")
    ap.add_argument("--results", type=Path, default=HERE / "results.json")
    ap.add_argument("--readme", type=Path, default=HERE / "README.md")
    args = ap.parse_args()

    counts, rows = load_counts(args.results)
    total = sum(counts.values())
    supported = counts["PASS"] + counts["ORDER"]
    denom = supported + counts["FAIL"]
    pct = round(100.0 * supported / denom, 1) if denom else 0.0

    print(f"results.json: " + " · ".join(f"{b} {counts[b]}" for b in BUCKETS) + f"  (total {total})")
    print(f"supported-surface parity = {supported}/{denom} = {pct}%")

    problems: list[str] = []

    rc, rparity = readme_counts(args.readme)
    for b in BUCKETS:
        if b not in rc:
            problems.append(f"README is missing a count row for {b}")
        elif rc[b] != counts[b]:
            problems.append(f"README {b}={rc[b]} disagrees with results.json {b}={counts[b]}")
    if rparity is None:
        problems.append("README has no parseable 'X/Y = Z%' supported-surface parity line")
    else:
        rnum, rden, rpct = rparity
        if (rnum, rden) != (supported, denom):
            problems.append(f"README parity fraction {rnum}/{rden} != computed {supported}/{denom}")
        if abs(rpct - pct) > 0.1:
            problems.append(f"README parity {rpct}% != computed {pct}%")

    undocumented = [r["name"] for r in rows if r.get("bucket") == "FAIL" and not (r.get("detail") or "").strip()]
    if undocumented:
        problems.append(f"{len(undocumented)} FAIL case(s) have an empty/null detail (document the divergence or reclassify NA): {', '.join(undocumented)}")

    if counts["FAIL"] > 0 and not args.allow_fail:
        problems.append(f"{counts['FAIL']} FAIL case(s) present (supported-surface is not zero-FAIL) — fix, reclassify NA, or pass --allow-fail")

    if problems:
        print("\nFAIL:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("\nPASS: README and results.json agree; parity consistent; every FAIL documented.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
