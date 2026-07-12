#!/usr/bin/env python3
"""Separate gist's required runtime cache from benchmark workspace bytes.

The apples-to-apples number is exactly `index.gist + paths.list + built.ns`.
Everything else under `.local/gist-verify` is verification/certificate
workspace, not runtime cache. This gate measures both without ever comparing
the whole workspace to a rival's index.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[4]  # gates -> bench -> gist -> kernels -> libs -> repo
POSTING_BLOB = "index.gist"
PATH_TABLE = "paths.list"
FRESHNESS_ANCHOR = "built.ns"
REPORT = "index-sizes.json"
REQUIRED = (POSTING_BLOB, PATH_TABLE, FRESHNESS_ANCHOR)


def dir_bytes(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())


def mib(n: int) -> str:
    return f"{n / (1024 * 1024):.1f} MiB"


def main() -> int:
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
    ap.add_argument("--output", type=Path, default=None)
    ap.add_argument(
        "--assert-required-under-csearch",
        action="store_true",
        help="exit 1 unless gist's required runtime cache < the whole csearch index",
    )
    ap.add_argument("--assert-total-under-csearch", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    idir: Path = args.index_dir
    if not idir.is_dir():
        print(
            f"no index dir at {idir} — run `gist index` first (writes .local/gist-verify/)",
            file=sys.stderr,
        )
        return 2

    missing = [name for name in REQUIRED if not (idir / name).is_file()]
    if missing:
        print(
            f"missing required runtime cache file(s) in {idir}: {', '.join(missing)}",
            file=sys.stderr,
        )
        return 2

    sizes = {name: (idir / name).stat().st_size for name in REQUIRED}
    posting = sizes[POSTING_BLOB]
    path = sizes[PATH_TABLE]
    freshness = sizes[FRESHNESS_ANCHOR]
    required = sum(sizes.values())
    required_paths = {idir / name for name in REQUIRED}
    out = args.output or idir / REPORT
    workspace_files = [
        f for f in idir.rglob("*") if f.is_file() and f not in required_paths and f != out
    ]
    workspace = sum(f.stat().st_size for f in workspace_files)

    report: dict[str, object] = {
        "schema_version": 2,
        "gist": {
            "index_dir": str(idir),
            "posting_bytes": posting,
            "path_bytes": path,
            "freshness_bytes": freshness,
            "required_bytes": required,
            "workspace_bytes": workspace,
            "workspace_file_count": len(workspace_files),
            "required_files": sizes,
            "workspace_excludes": [REPORT],
        },
        "csearch": None,
        "zoekt": None,
        "note": (
            "Compare required_bytes (index.gist + paths.list + built.ns) with rival "
            "whole-index bytes. workspace_bytes is verification/certificate evidence, "
            "excludes index-sizes.json itself, and is never an apples-to-apples index figure."
        ),
    }
    if args.csearch.exists():
        report["csearch"] = {"path": str(args.csearch), "bytes": dir_bytes(args.csearch)}
    if args.zoekt and args.zoekt.exists():
        report["zoekt"] = {"path": str(args.zoekt), "bytes": dir_bytes(args.zoekt)}

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n")

    print(f"gist index dir: {idir}")
    print(f"  {'posting':<16} {mib(posting)}  ({POSTING_BLOB})")
    print(f"  {'path table':<16} {mib(path)}  ({PATH_TABLE})")
    print(f"  {'freshness':<16} {mib(freshness)}  ({FRESHNESS_ANCHOR})")
    print(f"  {'REQUIRED runtime':<16} {mib(required)}  (apples-to-apples)")
    print(
        f"  {'workspace':<16} {mib(workspace)}  "
        f"({len(workspace_files)} evidence files; not runtime cache)"
    )
    cs = report["csearch"]
    if cs:
        print(f"csearch index: {mib(cs['bytes'])}  ({cs['path']})")
    zk = report["zoekt"]
    if zk:
        print(f"zoekt index:   {mib(zk['bytes'])}  ({zk['path']})")
    print(f"wrote {out}")

    if args.assert_required_under_csearch or args.assert_total_under_csearch:
        if not cs:
            print("FAIL: requested csearch comparison but no csearch index found", file=sys.stderr)
            return 1
        if required >= cs["bytes"]:
            print(
                f"FAIL: gist required cache {mib(required)} is NOT < csearch {mib(cs['bytes'])}",
                file=sys.stderr,
            )
            return 1
        print(f"OK: gist required cache {mib(required)} < csearch {mib(cs['bytes'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
