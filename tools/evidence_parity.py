#!/usr/bin/env python3
"""One scoreable-case total, many manifests — prove they still agree.

`bench/conformance/rgsuite/results.json` is the mined ripgrep replay's single
authority: PASS + ORDER + FAIL is the "scoreable" universe this repository's
prose keeps restating in sentences no table-parser can read — `check_results.py`
already guards the one README shaped like its own bucket table, but a reader
also meets the same number spelled out in `README.md`, `TESTING.md`, and
`CLAIM.md`. Those four copies drifted once already: three had already grown to
411 while the fourth still claimed 409, and nothing failed.

Discovery is a marker, not a list — the same shape `version_parity.py` uses for
`x-release-please-version`. Any line carrying `x-rgsuite-total` immediately
after a number is a mirror, so a fifth document that states the count is
covered the day someone marks it, not the day someone remembers this file.

Run it with no arguments from anywhere; `--json` for a machine.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

MARKER_RE = re.compile(r"(\d+)\s*<!--\s*x-rgsuite-total\s*-->")
RESULTS = "bench/conformance/rgsuite/results.json"
BUCKETS = ("PASS", "ORDER", "FAIL", "NA", "SKIP")

# Same exclusions as `version_parity.py`: build output, vendored trees, and
# caches hold stale copies of our own files, which turns a parity gate into a
# scavenger hunt rather than a review of authored prose.
SKIP = {
    ".git",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "zig-pkg",
    ".local",
    "target",
    "vendor",
    "node_modules",
    "__pycache__",
    ".venv",
    ".pytest_cache",
    ".ruff_cache",
    "testdata",
    "changelog.d",
}
SUFFIXES = {".md"}


def repo_root(start: pathlib.Path) -> pathlib.Path:
    """The nearest ancestor holding a `build.zig.zon` — the package boundary."""
    for candidate in (start, *start.parents):
        if (candidate / "build.zig.zon").is_file():
            return candidate
    raise SystemExit("evidence_parity: no build.zig.zon in any parent — not a package tree")


def canonical_total(root: pathlib.Path) -> int:
    """The scoreable universe the mined replay actually produced: PASS + ORDER + FAIL.

    Not `len(rows)` — `results.json` also carries NA and SKIP, which are
    deliberate exclusions from the ripgrep-comparable surface, never part of
    what "scoreable" means.
    """
    path = root / RESULTS
    rows = json.loads(path.read_text(encoding="utf-8"))
    counts = dict.fromkeys(BUCKETS, 0)
    for r in rows:
        b = r.get("bucket")
        if b in counts:
            counts[b] += 1
    return counts["PASS"] + counts["ORDER"] + counts["FAIL"]


def marked_claims(root: pathlib.Path) -> list[tuple[pathlib.Path, int, int]]:
    """Every `(path, line, claimed total)` mirror in the tree, in walk order."""
    out: list[tuple[pathlib.Path, int, int]] = []
    for path in sorted(root.rglob("*.md")):
        if SKIP & set(path.relative_to(root).parts):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if "x-rgsuite-total" not in text:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            for m in MARKER_RE.finditer(line):
                out.append((path.relative_to(root), number, int(m.group(1))))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    args = parser.parse_args()

    root = repo_root(pathlib.Path.cwd().resolve())
    want = canonical_total(root)
    claims = marked_claims(root)

    faults: list[str] = []
    rows = [{"path": str(p), "line": n, "total": got} for p, n, got in claims]
    for path, number, got in claims:
        if got != want:
            faults.append(f"{path}:{number}: claims {got} scoreable cases, {RESULTS} says {want}")
    if not rows:
        faults.append("no x-rgsuite-total mirrors found — evidence_parity has nothing to guard")

    if args.json:
        print(json.dumps({"total": want, "mirrors": rows, "faults": faults}, indent=2))
    elif faults:
        print(
            f"evidence_parity: {len(faults)} fault(s) against {RESULTS} total {want}\n",
            file=sys.stderr,
        )
        for fault in faults:
            print(f"  {fault}", file=sys.stderr)
        print(
            "\nEither the doc drifted (update the marked line to match) or the mined "
            "replay's own scoreable total moved and every marked line needs the new number.",
            file=sys.stderr,
        )
    else:
        print(f"evidence_parity: {len(rows)} mirror(s) agree at {want} scoreable cases")
    return 1 if faults else 0


if __name__ == "__main__":
    raise SystemExit(main())
