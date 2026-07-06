#!/usr/bin/env python3
"""Certificate reproducibility gate.

The "9 win / 2 loss" macro certificate is only a *claim* until a third party can
regenerate it from committed bytes. Today `certify.sh` writes a couple of files to
gitignored `.local/` and the figures are transcribed by hand. This gate defines
what a REPRODUCIBLE certificate must contain and fails until it does — two checks:

  --artifacts : a certificate output dir holds every required file, and its
                machine/tool metadata carries every key a reviewer needs to
                reproduce the run (CPU, RAM, OS, filesystem, tool versions, git
                commit, corpus size).
  --dataviz   : the figure scripts are generated FROM that committed data, not
                transcribed — fail if any `gist_*.py` still says "transcribe" /
                "hardcoded" / "manual" or never actually reads its source CSV.

Usage: check_artifacts.py [--artifacts-dir DIR] [--dataviz-dir DIR]
                          [--artifacts] [--dataviz]   (default: run both)
Exit 0 iff every requested check passes; 2 if a certificate dir is simply absent.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CRATE = HERE.parents[1]  # certify -> bench -> gist
REPO = HERE.parents[4]  # ... -> repo root

REQUIRED_FILES = (
    "CERTIFICATE.md",
    "certify_macro.csv",
    "machine.json",
    "tool-versions.txt",
    "corpus-manifest.tsv",
    "command-log.txt",
)
REQUIRED_MACHINE_KEYS = (
    "cpu_model", "cpu_count", "ram_bytes", "os", "kernel", "filesystem",
    "git_commit", "corpus_file_count", "corpus_total_bytes",
)
REQUIRED_TOOLS = ("zig", "rg", "csearch", "zoekt", "hyperfine")
TRANSCRIBE_MARKERS = re.compile(r"transcrib|hardcod|\bmanual\b|hand-wave|paste (?:it|the)", re.I)
CSV_READ = re.compile(r"read_csv|DictReader|loadtxt|genfromtxt|csv\.reader|json\.load|open\([^)]*\.(csv|json)")


def check_artifacts(d: Path) -> list[str]:
    if not d.is_dir():
        print(f"  (no certificate dir at {d} — run `bench/certify/certify.sh` first)")
        return ["__ABSENT__"]
    problems: list[str] = []
    for f in REQUIRED_FILES:
        if not (d / f).is_file():
            problems.append(f"missing required artifact: {f}")
    # at least one raw hyperfine JSON (per-cell timing evidence, under raw/)
    if not list(d.glob("raw/*.json")) and not list(d.glob("*.json")):
        problems.append("no raw hyperfine JSON export found (per-cell timing evidence under raw/)")
    mj = d / "machine.json"
    if mj.is_file():
        try:
            meta = json.loads(mj.read_text())
            for k in REQUIRED_MACHINE_KEYS:
                if k not in meta:
                    problems.append(f"machine.json missing key: {k}")
        except json.JSONDecodeError as e:
            problems.append(f"machine.json is not valid JSON: {e}")
    tv = d / "tool-versions.txt"
    if tv.is_file():
        text = tv.read_text().lower()
        for t in REQUIRED_TOOLS:
            if t not in text:
                problems.append(f"tool-versions.txt missing a version line for: {t}")
    return problems


def check_dataviz(d: Path) -> list[str]:
    scripts = sorted(d.glob("gist_*.py"))
    if not scripts:
        return [f"no gist_*.py figure scripts under {d}"]
    problems: list[str] = []
    for s in scripts:
        text = s.read_text()
        m = TRANSCRIBE_MARKERS.search(text)
        if m:
            line = text[: m.start()].count("\n") + 1
            problems.append(f"{s.name}: transcribed figure — says {m.group(0)!r} at line {line} (generate from committed CSV instead)")
        elif not CSV_READ.search(text):
            problems.append(f"{s.name}: does not read a committed .csv/.json (figures must be generated from raw data, not inlined)")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts-dir", type=Path, default=REPO / ".local" / "gist-verify")
    ap.add_argument("--dataviz-dir", type=Path, default=REPO / "scripts" / "act" / "workspace" / "dataviz" / "figures")
    ap.add_argument("--artifacts", action="store_true", help="run only the artifacts check")
    ap.add_argument("--dataviz", action="store_true", help="run only the dataviz check")
    args = ap.parse_args()
    run_art = args.artifacts or not args.dataviz
    run_dv = args.dataviz or not args.artifacts

    rc = 0
    if run_art:
        print(f"[artifacts] {args.artifacts_dir}")
        probs = check_artifacts(args.artifacts_dir)
        if probs == ["__ABSENT__"]:
            rc = max(rc, 2)
        elif probs:
            for p in probs:
                print(f"  - {p}")
            print("  FAIL: certificate is not reproducible from committed bytes.")
            rc = max(rc, 1)
        else:
            print("  ok: all required artifacts + metadata present.")
    if run_dv:
        print(f"[dataviz] {args.dataviz_dir}")
        probs = check_dataviz(args.dataviz_dir)
        if probs:
            for p in probs:
                print(f"  - {p}")
            print("  FAIL: figures are transcribed, not generated from committed raw data.")
            rc = max(rc, 1)
        else:
            print("  ok: every figure script is generated from committed raw data.")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
