#!/usr/bin/env python3
"""Apples-to-apples index-size accounting.

The README/dossier "30.1 MiB, smaller than csearch's 31.1 MiB" claim compares
gist's posting blob (`index.gist`) against csearch's WHOLE index — gist's
separate `paths.list` (and any freshness sidecars) aren't counted. This gate
measures what's actually on disk and emits a machine-readable
`index-sizes.json` (schema_version 2), so any size comparison can cite gist's
**required** runtime cache (posting + path table + freshness) rather than an
unstated blob-vs-total mismatch, and keeps certificate/workspace files out of
the cache total.

Usage: index_size_accounting.py [--index-dir DIR] [--csearch PATH] [--zoekt DIR]
                                [--assert-total-under-csearch]
Env: GIST_INDEX_DIR, CSEARCHINDEX.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[3]  # oracle → gates → conformance → bench → repo
POSTING_BLOB = "index.gist"
PATH_TABLE = "paths.list"
FRESHNESS = "built.ns"
REQUIRED = (POSTING_BLOB, PATH_TABLE, FRESHNESS)


def dir_bytes(p: Path) -> int:
    """Return total bytes for a file or directory tree."""
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def mib(n: int) -> str:
    """Format bytes as MiB."""
    return f"{n / (1024 * 1024):.1f} MiB"


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--index-dir",
        type=Path,
        default=Path(os.environ.get("GIST_INDEX_DIR", REPO_ROOT / ".local" / "gist-verify")),
    )
    ap.add_argument(
        "--csearch",
        type=Path,
        default=Path(os.environ.get("CSEARCHINDEX", Path.home() / ".csearchindex")),
    )
    ap.add_argument("--zoekt", type=Path, default=None)
    ap.add_argument(
        "--assert-total-under-csearch",
        action="store_true",
        help="exit 1 unless gist required cache < csearch index",
    )
    args = ap.parse_args()

    idir: Path = args.index_dir
    if not idir.is_dir():
        print(
            f"no index dir at {idir} — run `gist index` first (writes .local/gist-verify/)",
            file=sys.stderr,
        )
        return 2

    all_files: dict[str, int] = {}
    for f in sorted(idir.iterdir()):
        if f.is_file():
            all_files[f.name] = f.stat().st_size
    if POSTING_BLOB not in all_files:
        print(f"no {POSTING_BLOB} in {idir}", file=sys.stderr)
        return 2

    posting = all_files[POSTING_BLOB]
    path_bytes = all_files.get(PATH_TABLE, 0)
    freshness = all_files.get(FRESHNESS, 0)
    required = posting + path_bytes + freshness
    required_files = {
        POSTING_BLOB: posting,
        PATH_TABLE: path_bytes,
        FRESHNESS: freshness,
    }
    workspace = sum(n for name, n in all_files.items() if name not in REQUIRED)

    report: dict[str, object] = {
        "schema_version": 2,
        "gist": {
            "index_dir": str(idir),
            "posting_bytes": posting,
            "path_bytes": path_bytes,
            "freshness_bytes": freshness,
            "required_bytes": required,
            "workspace_bytes": workspace,
            "required_files": required_files,
            "files": all_files,
        },
        "csearch": None,
        "zoekt": None,
        "note": (
            "Size comparisons must cite gist's required_bytes (posting + path + "
            "freshness), or explicitly say 'posting blob only'. workspace_bytes "
            "holds certificate/verification outputs and must not be counted as cache."
        ),
    }
    if args.csearch.exists():
        report["csearch"] = {"path": str(args.csearch), "bytes": dir_bytes(args.csearch)}
    if args.zoekt and args.zoekt.exists():
        report["zoekt"] = {"path": str(args.zoekt), "bytes": dir_bytes(args.zoekt)}

    out = idir / "index-sizes.json"
    out.write_text(json.dumps(report, indent=2) + "\n")

    print(f"gist index dir: {idir}")
    for name in REQUIRED:
        print(f"  {name:<16} {mib(all_files.get(name, 0))}")
    print(f"  {'required cache':<16} {mib(required)}   (apples-to-apples)")
    print(f"  {'workspace':<16} {mib(workspace)}   (certificate / verify outputs)")
    cs = report["csearch"]
    if isinstance(cs, dict):
        print(f"csearch index: {mib(int(cs['bytes']))}  ({cs['path']})")
    zk = report["zoekt"]
    if isinstance(zk, dict):
        print(f"zoekt index:   {mib(int(zk['bytes']))}  ({zk['path']})")
    print(f"wrote {out}")

    if args.assert_total_under_csearch:
        if not isinstance(cs, dict):
            print("FAIL: --assert-total-under-csearch but no csearch index found", file=sys.stderr)
            return 1
        if required >= int(cs["bytes"]):
            print(
                f"FAIL: gist required cache {mib(required)} is NOT < csearch {mib(int(cs['bytes']))}",
                file=sys.stderr,
            )
            return 1
        print(f"OK: gist required cache {mib(required)} < csearch {mib(int(cs['bytes']))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
