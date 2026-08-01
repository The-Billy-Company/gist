#!/usr/bin/env python3
"""rgsuite anti-staleness + complete-accounting gate.

The rgsuite README is a human-written summary of `results.json`; the two drifted
once already (README claimed 0 FAIL / 100% while the committed results held 4
FAIL). This gate makes that drift a hard failure — AND enforces that every one of
the mined obligations is accounted for exactly once, so the denominator can never
silently shrink and no `SKIP`/`FAIL` hides as an unexplained gap.

`run.py` replays what it can and buckets each case in `results.json`
(PASS/ORDER/FAIL/NA/SKIP). `coverage_manifest.toml` accounts for the rest:

  * every SKIP is claimed by exactly one `[[companion]]`/`[[boundary]]`/
    `[[irreplayable]]` entry (a passing sibling proof, a documented design
    boundary, or a case the mining format can't represent) — no orphan SKIP;
  * every FAIL is claimed by exactly one `[[deferred]]` entry (an explained
    divergence tracked to the deferred entry that owns its fix) — no unexplained FAIL;
  * no case is double-credited across manifest entries, and no entry names a
    case `results.json` doesn't contain (no dangling reference);
  * the README's PASS/ORDER/FAIL/NA/SKIP counts equal the counts in results.json;
  * the README's "supported-surface parity" fraction/percent is arithmetically
    consistent with those counts ((PASS+ORDER)/(PASS+ORDER+FAIL));
  * every FAIL and NA row carries a non-empty `detail` (a documented divergence,
    not a silent `null`).

Without `--allow-fail`, the gate additionally requires the `[[deferred]]` list to
be EMPTY (FAIL == 0 — the final zero-gap target). With it, deferred FAILs are
tolerated, but an UNdeferred FAIL is always an error.

Usage: check_results.py [--allow-fail] [--results PATH] [--readme PATH] [--manifest PATH]
Exit 0 iff every rule holds.
"""

import argparse
import json
from pathlib import Path
import re
import sys
import tomllib


BUCKETS = ("PASS", "ORDER", "FAIL", "NA", "SKIP")
HERE = Path(__file__).resolve().parent


def load_counts(results_path: Path) -> tuple[dict[str, int], list[dict]]:
    """Bucket-count the replayed cases and return (counts, rows)."""
    rows = json.loads(results_path.read_text())
    counts = dict.fromkeys(BUCKETS, 0)
    for r in rows:
        b = r.get("bucket")
        if b not in counts:
            sys.exit(f"results.json: unknown bucket {b!r} in case {r.get('name')!r}")
        counts[b] += 1
    return counts, rows


def readme_counts(readme_path: Path) -> tuple[dict[str, int], tuple[int, int, float] | None]:
    """Parse the README's bucket table + parity line back out for a drift check."""
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


def manifest_claims(manifest_path: Path) -> tuple[dict[str, list[str]], list[str]]:
    """Return ({case: [entry-labels claiming it]}, [deferred case names]).

    Every case listed under any `[[companion]]`/`[[boundary]]`/`[[irreplayable]]`/
    `[[deferred]]` entry is recorded with a human label naming the claiming entry,
    so a double-credit surfaces as a case with >1 label.
    """
    data = tomllib.loads(manifest_path.read_text())
    claims: dict[str, list[str]] = {}
    deferred: list[str] = []
    for kind, key in (("companion", "proof"), ("boundary", "reason"), ("irreplayable", "reason")):
        for entry in data.get(kind, []):
            label = f"{kind}:{str(entry.get(key, ''))[:40]}"
            for c in entry["cases"]:
                claims.setdefault(c, []).append(label)
    for entry in data.get("deferred", []):
        label = f"deferred:{entry.get('phase', '?')}"
        for c in entry["cases"]:
            claims.setdefault(c, []).append(label)
            deferred.append(c)
    return claims, deferred


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--allow-fail",
        action="store_true",
        help="tolerate deferred FAILs (still requires every FAIL to be manifest-deferred)",
    )
    ap.add_argument("--results", type=Path, default=HERE / "results.json")
    ap.add_argument("--readme", type=Path, default=HERE / "README.md")
    ap.add_argument("--manifest", type=Path, default=HERE / "coverage_manifest.toml")
    args = ap.parse_args()

    counts, rows = load_counts(args.results)
    total = sum(counts.values())
    supported = counts["PASS"] + counts["ORDER"]
    denom = supported + counts["FAIL"]
    pct = round(100.0 * supported / denom, 1) if denom else 0.0

    print("results.json: " + " · ".join(f"{b} {counts[b]}" for b in BUCKETS) + f"  (total {total})")
    print(f"supported-surface parity = {supported}/{denom} = {pct}%")

    problems: list[str] = []
    by_name = {r["name"]: r for r in rows}
    skips = {r["name"] for r in rows if r["bucket"] == "SKIP"}
    fails = {r["name"] for r in rows if r["bucket"] == "FAIL"}

    # ── manifest accounting ──
    claims, deferred = manifest_claims(args.manifest)
    deferred_set = set(deferred)

    dangling = [c for c in claims if c not in by_name]
    if dangling:
        problems.append(f"manifest names {len(dangling)} case(s) absent from results.json: {', '.join(sorted(dangling))}")
    double = {c: labels for c, labels in claims.items() if len(labels) > 1}
    if double:
        problems.append(
            "manifest double-credits case(s): "
            + "; ".join(f"{c} → {labels}" for c, labels in sorted(double.items()))
        )

    non_deferred_claim = {c for c, labels in claims.items() if any(not l.startswith("deferred:") for l in labels)}
    orphan_skips = sorted(skips - non_deferred_claim)
    if orphan_skips:
        problems.append(
            f"{len(orphan_skips)} SKIP(s) unclaimed by any companion/boundary/irreplayable entry: {', '.join(orphan_skips)}"
        )
    # A companion/boundary/irreplayable entry must claim a real SKIP, not a replayed case.
    mis_claimed = sorted(c for c in non_deferred_claim if c in by_name and by_name[c]["bucket"] != "SKIP")
    if mis_claimed:
        problems.append(
            f"{len(mis_claimed)} non-SKIP case(s) claimed as companion/boundary/irreplayable (should be replayed): {', '.join(mis_claimed)}"
        )

    undeferred_fails = sorted(fails - deferred_set)
    if undeferred_fails:
        problems.append(
            f"{len(undeferred_fails)} FAIL(s) not recorded in a [[deferred]] manifest entry (explain + phase-track, fix, or reclassify NA): {', '.join(undeferred_fails)}"
        )
    stale_deferred = sorted(deferred_set - fails)
    if stale_deferred:
        problems.append(
            f"{len(stale_deferred)} [[deferred]] case(s) no longer FAIL (fixed — drop them from the manifest): {', '.join(stale_deferred)}"
        )

    # ── README drift ──
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

    # ── every FAIL/NA row documents its divergence ──
    undocumented = [
        r["name"]
        for r in rows
        if r.get("bucket") in ("FAIL", "NA") and not (r.get("detail") or "").strip()
    ]
    if undocumented:
        problems.append(
            f"{len(undocumented)} FAIL/NA case(s) have an empty/null detail (document the divergence): {', '.join(undocumented)}"
        )

    if counts["FAIL"] > 0 and not args.allow_fail:
        problems.append(
            f"{counts['FAIL']} FAIL case(s) present — the [[deferred]] list is non-empty. "
            "Fix/reclassify, or pass --allow-fail to accept phase-tracked deferrals."
        )

    if problems:
        print("\nFAIL:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(
        f"\nPASS: {len(skips)} SKIP + {len(fails)} FAIL fully accounted for; "
        "README and results.json agree; parity consistent; every FAIL/NA documented."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
