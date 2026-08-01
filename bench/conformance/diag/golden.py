#!/usr/bin/env python3
"""Diagnostic-template golden harness — the safety net for the assay migration.

Every diagnostic gist/relate/irregex writes to **stderr** (verb-summary lines,
timing, phase traces) is a format template with a few volatile values punched
in: elapsed `ms`, live counts, and the `atlas,`/`live,` provenance tag. This
harness runs each read-only verb, captures its stderr, and **normalizes those
volatile values away** — every run of digits becomes ``N`` and the provenance
tag becomes ``SRC`` — leaving the template's exact words, punctuation, and units.

The normalized template is deterministic even over the live, concurrently-edited
repo (counts vary run to run, but they all collapse to ``N``), so it can be
committed as a golden and diffed in CI. A format-string typo introduced while
routing a line through ``assay`` (``sketches`` → ``sketch``, a dropped `` · ``,
a changed unit) breaks the diff; a changed count or timing does not. That is
precisely the invariant the assay migration must preserve: the *shape* of every
diagnostic line is unchanged, only the plumbing beneath it moved.

Usage:
    golden.py check            # diff live templates against committed goldens (CI)
    golden.py update           # regenerate the committed goldens (after a deliberate change)
    golden.py show <name>      # print one verb's normalized template

Binaries are taken from ``zig-out/bin`` under the kernel; build them first with
``zig build -Doptimize=ReleaseFast`` (library check) or the sibling ``gist`` package binaries. Read-only verbs
only — nothing here mutates the shared machine-local index/atlas.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

KERNEL = Path(__file__).resolve().parents[3]  # diag → conformance → bench → repo root
REPO = KERNEL
BIN = KERNEL / "zig-out" / "bin"
GOLDEN_DIR = Path(__file__).resolve().parent / "golden"

# Volatile → placeholder. Order matters: collapse the provenance tag before the
# digit pass so `atlas, 5 refreshed` and `live, 0 refreshed` both become
# `SRCN refreshed`.
_PROVENANCE = re.compile(r"(?:atlas, |live, )")
_DIGITS = re.compile(r"\d+(?:\.\d+)?")


def normalize(stderr: str) -> str:
    out = _PROVENANCE.sub("SRC", stderr)
    out = _DIGITS.sub("N", out)
    return out


# Each case: a name, the face binary, and argv. Read-only verbs chosen to emit
# their summary line over the repo without touching shared index/atlas state.
# `--no-index` forces gist's deterministic live path. A needle known to exist in
# this repo keeps the ranked/composed verbs productive.
NEEDLE = "WalletService"
CASES: list[tuple[str, str, list[str]]] = [
    ("gist-rank-live", "gist", [NEEDLE, "--rank", "--no-index", "libs"]),
    ("relate-similar", "relate", ["similar", "src/root.zig", "--no-index", "--top", "3"]),
    ("relate-dups", "relate", ["dups", "src", "--no-index"]),
    ("relate-clusters", "relate", ["clusters", "src", "--no-index"]),
    ("relate-echoes", "relate", ["echoes", "src", "--no-index", "--top", "5"]),
    ("relate-patterns", "relate", ["patterns", "-e", "Span", "-e", "Tally", "src"]),
    ("relate-search", "relate", ["search", "monotonic clock reading", "src"]),
    ("relate-pack", "relate", ["pack", "diagnostic channel sink", "src", "--top", "3"]),
    ("irregex-context", "irregex", ["context", "diagnostic sink", "-e", "Sink", "src", "--top", "3"]),
    ("irregex-family", "irregex", ["family", "Tally", "src", "--echo-min", "0.15"]),
    ("irregex-blast", "irregex", ["blast", "Duration", "src"]),
    ("irregex-provenance", "irregex", ["provenance", "the monotonic-awake clock"]),
]

# `GIST_NO_AUTOSERVE` forces gist's cold path so the index-backed `--rank`
# template is deterministic (the warm daemon path is exercised separately).
ENV = {**os.environ, "GIST_UNCAP": "1", "GIST_HINTS": "0", "GIST_NO_AUTOSERVE": "1"}


def run_case(binary: str, argv: list[str]) -> str:
    exe = BIN / binary
    if not exe.exists():
        sys.exit(f"missing binary {exe} — build with `zig build -Doptimize=ReleaseFast` first")
    proc = subprocess.run(
        [str(exe), *argv],
        cwd=REPO,
        env=ENV,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=120,
    )
    return normalize(proc.stderr)


def cmd_update() -> int:
    GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
    for name, binary, argv in CASES:
        (GOLDEN_DIR / f"{name}.txt").write_text(run_case(binary, argv))
        print(f"  updated {name}")
    return 0


def cmd_check() -> int:
    fails = 0
    for name, binary, argv in CASES:
        got = run_case(binary, argv)
        golden = GOLDEN_DIR / f"{name}.txt"
        want = golden.read_text() if golden.exists() else "<missing golden>"
        if got == want:
            print(f"  ok    {name}")
        else:
            fails += 1
            print(f"  FAIL  {name}")
            print(f"    want: {want!r}")
            print(f"    got:  {got!r}")
    if fails:
        print(f"\nFAILED: {fails} diagnostic template(s) drifted — a summary format changed.")
        return 1
    print("\nPROVEN: every diagnostic template is byte-identical to its committed golden.")
    return 0


def cmd_show(name: str) -> int:
    for cname, binary, argv in CASES:
        if cname == name:
            sys.stdout.write(run_case(binary, argv))
            return 0
    sys.exit(f"unknown case {name!r}; known: {', '.join(c[0] for c in CASES)}")


def main() -> int:
    ap = argparse.ArgumentParser(description="diagnostic-template golden harness")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="diff live templates vs committed goldens")
    sub.add_parser("update", help="regenerate the committed goldens")
    show = sub.add_parser("show", help="print one verb's normalized template")
    show.add_argument("name")
    args = ap.parse_args()
    if args.cmd == "check":
        return cmd_check()
    if args.cmd == "update":
        return cmd_update()
    if args.cmd == "show":
        return cmd_show(args.name)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
