#!/usr/bin/env python3
"""Apples-to-apples index-size accounting.

The README/dossier "30.1 MiB, smaller than csearch's 31.1 MiB" claim compares
gist's posting blob (`index.gist`) against csearch's WHOLE index — gist's
separate `paths.list` (and any freshness sidecars) aren't counted. This gate
measures what's actually on disk and emits a machine-readable
`index-sizes.json`, so any size comparison can cite gist's TOTAL cache (or say
"posting blob only") instead of an unstated blob-vs-total mismatch.

It measures, never estimates; missing artifacts are reported, not guessed.

Usage: index_size_accounting.py [--index-dir DIR] [--csearch PATH] [--zoekt DIR]
                                [--assert-total-under-csearch]
Env: GIST_INDEX_DIR, CSEARCHINDEX.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[4]  # gates -> bench -> gist -> kernels -> libs -> repo
POSTING_BLOB = "index.gist"
PATH_TABLE = "paths.list"


def dir_bytes(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def mib(n: int) -> str:
    return f"{n / (1024 * 1024):.1f} MiB"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--index-dir", type=Path, default=Path(os.environ.get("GIST_INDEX_DIR", REPO_ROOT / ".local" / "gist-verify")))
    ap.add_argument("--csearch", type=Path, default=Path(os.environ.get("CSEARCHINDEX", Path.home() / ".csearchindex")))
    ap.add_argument("--zoekt", type=Path, default=None)
    ap.add_argument("--assert-total-under-csearch", action="store_true", help="exit 1 unless gist TOTAL cache < csearch index (fail-closed for the 'smaller than csearch' claim)")
    args = ap.parse_args()

    idir: Path = args.index_dir
    if not idir.is_dir():
        print(f"no index dir at {idir} — run `gist index` first (writes .local/gist-verify/)", file=sys.stderr)
        return 2

    gist_files: dict[str, int] = {}
    for f in sorted(idir.iterdir()):
        if f.is_file():
            gist_files[f.name] = f.stat().st_size
    if POSTING_BLOB not in gist_files:
        print(f"no {POSTING_BLOB} in {idir}", file=sys.stderr)
        return 2

    posting_blob = gist_files[POSTING_BLOB]
    path_table = gist_files.get(PATH_TABLE, 0)
    total_cache = sum(gist_files.values())

    report: dict[str, object] = {
        "gist": {
            "index_dir": str(idir),
            "files": gist_files,
            "posting_blob_bytes": posting_blob,
            "path_table_bytes": path_table,
            "total_cache_bytes": total_cache,
        },
        "csearch": None,
        "zoekt": None,
        "note": "Size comparisons must cite gist's total_cache_bytes, or explicitly say 'posting blob only'. posting_blob_bytes alone is NOT apples-to-apples vs csearch/zoekt whole-index sizes.",
    }
    if args.csearch.exists():
        report["csearch"] = {"path": str(args.csearch), "bytes": dir_bytes(args.csearch)}
    if args.zoekt and args.zoekt.exists():
        report["zoekt"] = {"path": str(args.zoekt), "bytes": dir_bytes(args.zoekt)}

    out = idir / "index-sizes.json"
    out.write_text(json.dumps(report, indent=2) + "\n")

    print(f"gist index dir: {idir}")
    for name, n in gist_files.items():
        print(f"  {name:<16} {mib(n)}")
    print(f"  {'posting blob':<16} {mib(posting_blob)}   (the '30.1 MiB' figure)")
    print(f"  {'TOTAL cache':<16} {mib(total_cache)}   (the apples-to-apples figure)")
    cs = report["csearch"]
    if cs:
        print(f"csearch index: {mib(cs['bytes'])}  ({cs['path']})")
    zk = report["zoekt"]
    if zk:
        print(f"zoekt index:   {mib(zk['bytes'])}  ({zk['path']})")
    print(f"wrote {out}")

    if args.assert_total_under_csearch:
        if not cs:
            print("FAIL: --assert-total-under-csearch but no csearch index found", file=sys.stderr)
            return 1
        if total_cache >= cs["bytes"]:
            print(f"FAIL: gist total cache {mib(total_cache)} is NOT < csearch {mib(cs['bytes'])}", file=sys.stderr)
            return 1
        print(f"OK: gist total cache {mib(total_cache)} < csearch {mib(cs['bytes'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
