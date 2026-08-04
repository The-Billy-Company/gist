#!/usr/bin/env python3
"""gist evaluation matrix — one comprehensive, machine-labeled evaluator.

Replaces the single-machine/single-corpus performance story with a reproducible
matrix, then verifies and publishes it. A closed verb set:

  run       measure the regimes on THIS machine → raw + bundle.json + report.md
            (``--publish`` commits a verified, clean-tree bundle under artifact/)
  verify    hermetically check committed bundles + claim freshness (CI-safe)
  compare   two machines under the cross-machine policy (ratios/shape, not ms)
  brief     short markdown digest of committed bundles

The measurement lanes live in ``regimes.py``; verification/aggregation in
``report.py``; provenance capture in ``provenance.py``. This file only
orchestrates them and owns the on-disk bundle schema. stdlib only.

Live timing is opt-in and box-specific — ``run`` refuses to publish from a dirty
tree; ``verify`` never times anything and is the path CI takes.
"""

# ruff: noqa: S603, S607 — a benchmark orchestrator: it spawns the tools under test
# (gist serve / gist queries) and PATH-resolved host tools (rsync for the corpus
# snapshot) with computed argv; inputs are the fixed probe registry, never user text.

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import provenance  # noqa: E402
import regimes  # noqa: E402
import report  # noqa: E402

KERNEL = HERE.parents[2]  # evaluate → dominance → bench → package root
RAW_ROOT = KERNEL / ".local" / "gist-evaluation"
ARTIFACT = HERE / "artifact"

# The scoped corpus + heavy-dir excludes mirror `bench/races/_compete.sh` (its ROOTS
# fallback set + XDIRS) so the frozen snapshot is the SAME logical corpus the tools
# would otherwise search live — the evaluator just measures it where it can't churn.
# Historical monorepo slices when present; else the whole package (mirrors field.sh).
_MONOREPO_ROOTS = ("services", "libs", "clients", "contracts", "scripts", "quality")
CORPUS_ROOTS = _MONOREPO_ROOTS if all((KERNEL / r).is_dir() for r in _MONOREPO_ROOTS) else (".",)
CORPUS_EXCLUDES = (
    "node_modules",
    "target",
    ".venv",
    "venv",
    "__pycache__",
    ".zig-cache",
    "zig-out",
    "dist",
    "dist-types",
    "build",
    ".build",
    "out",
    ".next",
    "coverage",
    ".turbo",
    ".mypy_cache",
    ".ruff_cache",
    ".pytest_cache",
    "Pods",
    "DerivedData",
    ".swiftpm",
    "vendor",
    ".local",
    ".cache",
    ".parcel-cache",
    "storybook-static",
    "xcuserdata",
    "graphify-out",
    ".pnpm-store",
    ".git",
    ".hg",
    ".svn",
)


def _freeze_corpus(dst: Path) -> Path:
    """Snapshot the scoped corpus into an immutable copy so a live coworking tree
    can't churn under a parity/timing capture (the plan's noise control).

    A real same-volume copy — NOT a hardlink: independent inodes make the snapshot
    invariant to concurrent edits of the source, which a shared inode would leak
    straight back in. `rsync --delete` makes the re-freeze incremental across runs.
    The heavy/ignored subtrees `_compete.sh` never searches are excluded so the copy
    is the code corpus, not gigabytes of build output.
    """
    dst.mkdir(parents=True, exist_ok=True)
    gitignore = KERNEL / ".gitignore"
    if gitignore.exists():
        shutil.copy2(gitignore, dst / ".gitignore")
    excludes = [arg for e in CORPUS_EXCLUDES for arg in ("--exclude", e)]
    for root in CORPUS_ROOTS:
        src = KERNEL / root
        if not src.is_dir():
            continue
        subprocess.run(
            ["rsync", "-a", "--delete", *excludes, f"{src}/", f"{dst / root}/"],
            check=True,
            capture_output=True,
        )
    return dst


def _methodology(contract: dict, runs: int | None, warmup: int | None) -> dict:
    m = contract["methodology"]
    return {
        "runs": runs if runs is not None else m["runs"],
        "warmup": warmup if warmup is not None else m["warmup"],
        "bootstrap_resamples": m["bootstrap_resamples"],
        "bootstrap_seed": m["bootstrap_seed"],
        "alpha": m["alpha"],
        "quantiles": m["quantiles"],
    }


def _start_daemon(bridge: regimes.Bridge) -> subprocess.Popen | None:
    """Arm a resident `gist serve` daemon; warm it with one query. None on failure."""
    corpus_root = regimes._corpus_root()
    try:
        proc = subprocess.Popen(
            [str(bridge.gist_bin), "serve"],
            cwd=str(corpus_root),
            env=bridge.env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return None
    time.sleep(1.5)
    if proc.poll() is not None:
        return None
    subprocess.run(
        [str(bridge.gist_bin), "pgxpool", "-l", "--", "libs"],
        check=False,
        capture_output=True,
        cwd=str(corpus_root),
        env=bridge.env,
    )
    return proc


def _stop_daemon(proc: subprocess.Popen | None) -> None:
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def _measure(args, contract: dict) -> dict:
    """Drive every requested regime on this machine and assemble the bundle."""
    method = _methodology(contract, args.runs, args.warmup)
    runs, warmup = method["runs"], method["warmup"]
    machine = provenance.machine(KERNEL, KERNEL / ".local" / "gist-bin")
    mid = machine["machine_id"]
    raw_dir = RAW_ROOT / mid
    gist_dir = raw_dir / "gist-index"
    raw_dir.mkdir(parents=True, exist_ok=True)

    print(f"[evaluate] machine={mid} dirty={machine['git_dirty']} runs={runs} warmup={warmup}")
    print("[evaluate] freezing immutable corpus snapshot…")
    corpus_root = _freeze_corpus(raw_dir / "corpus")
    os.environ["GIST_CORPUS_ROOT"] = str(corpus_root)
    print(f"[evaluate] corpus frozen → {corpus_root}")
    bridge = regimes.Bridge(gist_dir)

    print("[evaluate] building gist + index…")
    if not bridge.build_gist():
        msg = "evaluate: gist build/index failed — cannot measure"
        raise SystemExit(msg)

    # The operational lanes exercise gist alone; rg is the parity oracle. Record
    # both identities for provenance — no csearch/zoekt field (the certificate's).
    tool_ids: dict[str, str] = {}
    for tool in ("gist", "rg"):
        exe = str(bridge.gist_bin) if tool == "gist" else tool
        resolved = shutil.which(exe) or (str(bridge.gist_bin) if tool == "gist" else None)
        if resolved and Path(resolved).exists():
            tool_ids[tool] = provenance.tool_identity(tool, resolved)

    corpus = provenance.corpus_manifest(
        gist_dir / "paths.list", corpus_root, raw_dir / "corpus-manifest.tsv"
    )
    regime_out: dict[str, object] = {}

    want = set(args.regimes)
    print("[evaluate] parity precondition (both engines) before any timing…")
    parity = regimes.parity_lane(bridge)
    regime_out["parity"] = parity
    if any(r.get("status") == "failed" for r in parity):
        print("  parity FAILED — recording failure; timed lanes will be marked accordingly")

    if "lifecycle" in want:
        print("[evaluate] lifecycle (build + first query + incremental refresh)…")
        regime_out["lifecycle"] = regimes.lifecycle_lane(bridge, gist_dir)
    if "resource" in want:
        print("[evaluate] resource (rss + index/corpus ratio + throughput)…")
        regime_out["resource"] = regimes.resource_lane(bridge, gist_dir, corpus["total_bytes"])
    if "scale" in want and args.foreign:
        print("[evaluate] scale curves over foreign corpora…")
        corpora_dir = KERNEL / ".local" / "gist-corpora"
        regime_out["scale"] = regimes.scale_lane(bridge, corpora_dir, warmup=warmup, runs=runs)
    if "concurrency" in want:
        print("[evaluate] concurrency (many-agent load against the resident daemon)…")
        daemon = _start_daemon(bridge)
        regime_out["concurrency"] = regimes.concurrency_lane(bridge) if daemon else []
        _stop_daemon(daemon)

    return {
        "schema_version": contract["meta"]["schema_version"],
        "exploratory": bool(machine["git_dirty"]),
        "machine": machine,
        "corpora": {"billy": corpus},
        "tools": tool_ids,
        "methodology": method,
        "regimes": regime_out,
    }


def cmd_run(args) -> int:
    """Measure this machine, write the bundle + report, optionally publish."""
    contract = report.load_contract()
    bundle = _measure(args, contract)
    mid = bundle["machine"]["machine_id"]
    raw_dir = RAW_ROOT / mid
    (raw_dir / "bundle.json").write_text(json.dumps(bundle, indent=2) + "\n")

    problems = report.verify_bundle(bundle, contract, require_clean=False)
    agg = report.aggregate([bundle])
    _, claims = report.verify_claims(contract)
    (raw_dir / "report.md").write_text(report.render_report(agg, claims))
    print(f"[evaluate] wrote {raw_dir / 'bundle.json'} + report.md")
    if problems:
        print("[evaluate] bundle has contract issues (see below); not publishable as-is:")
        for p in problems:
            print(f"  - {p}")

    if args.publish:
        if bundle["exploratory"] or bundle["machine"]["git_dirty"]:
            print("[evaluate] refusing to publish: dirty tree (exploratory bundle). Commit first.")
            return 1
        pub_problems = report.verify_bundle(bundle, contract, require_clean=True)
        if pub_problems:
            print("[evaluate] refusing to publish: bundle fails contract:")
            for p in pub_problems:
                print(f"  - {p}")
            return 1
        pub = ARTIFACT / mid
        pub.mkdir(parents=True, exist_ok=True)
        shutil.copy2(raw_dir / "bundle.json", pub / "bundle.json")
        shutil.copy2(raw_dir / "corpus-manifest.tsv", pub / "corpus-manifest.tsv")
        _regenerate_aggregate(contract)
        print(f"[evaluate] published verified bundle → {pub}")
    return 1 if problems and not args.allow_dirty else 0


def _load_committed(contract: dict) -> list[dict]:
    if not ARTIFACT.is_dir():
        return []
    return [json.loads(path.read_text()) for path in sorted(ARTIFACT.glob("*/bundle.json"))]


def _regenerate_aggregate(contract: dict) -> None:
    bundles = _load_committed(contract)
    if not bundles:
        return
    agg = report.aggregate(bundles)
    _, claims = report.verify_claims(contract)
    (ARTIFACT / "REPORT.md").write_text(report.render_report(agg, claims))


def cmd_verify(args) -> int:
    """Hermetically verify committed bundles + claim freshness (the CI path)."""
    contract = report.load_contract()
    rc = 0
    bundles = []
    paths = [Path(args.bundle)] if args.bundle else sorted(ARTIFACT.glob("*/bundle.json"))
    if not paths:
        print("[verify] no committed bundles yet (artifact/ empty) — claims-only")
    for path in paths:
        bundle = json.loads(path.read_text())
        bundles.append(bundle)
        problems = report.verify_bundle(bundle, contract, require_clean=args.require_clean)
        label = bundle.get("machine", {}).get("machine_id", path.parent.name)
        if problems:
            rc = 1
            print(f"[verify] {label}: FAIL")
            for p in problems:
                print(f"  - {p}")
        else:
            print(f"[verify] {label}: ok")
    claim_problems, values = report.verify_claims(contract)
    if claim_problems:
        rc = 1
        print("[verify] claim freshness: FAIL")
        for p in claim_problems:
            print(f"  - {p}")
    else:
        print(f"[verify] claim freshness: ok ({len(values)} claims resolve)")
        for cid, value in sorted(values.items()):
            print(f"    {cid} = {value}")
    return rc


def cmd_compare(args) -> int:
    """Compare two bundles under the cross-machine policy."""
    a = json.loads(Path(args.a).read_text())
    b = json.loads(Path(args.b).read_text())
    print(json.dumps(report.compare(a, b), indent=2))
    return 0


def cmd_brief(args) -> int:
    """Short digest of committed bundles."""
    contract = report.load_contract()
    bundles = _load_committed(contract)
    if not bundles:
        print("no committed bundles — run `evaluate.py run --publish` on a clean tree")
        return 0
    agg = report.aggregate(bundles)
    _, claims = report.verify_claims(contract)
    print(report.render_report(agg, claims))
    return 0


ALL_REGIMES = ("lifecycle", "resource", "scale", "concurrency")


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    run = sub.add_parser("run", help="measure this machine")
    run.add_argument("--regimes", nargs="+", default=list(ALL_REGIMES), choices=ALL_REGIMES)
    run.add_argument("--foreign", action="store_true", help="include foreign-corpus scale lane")
    run.add_argument(
        "--runs", type=int, default=None, help="override hyperfine runs (unpublishable)"
    )
    run.add_argument("--warmup", type=int, default=None)
    run.add_argument("--publish", action="store_true", help="commit a verified clean-tree bundle")
    run.add_argument("--allow-dirty", action="store_true", help="exit 0 even with contract issues")
    run.set_defaults(func=cmd_run)

    verify = sub.add_parser("verify", help="verify committed bundles + claims (hermetic)")
    verify.add_argument("--bundle", help="verify one bundle path (default: all committed)")
    verify.add_argument(
        "--require-clean", action="store_true", help="also require a clean-tree provenance"
    )
    verify.set_defaults(func=cmd_verify)

    comp = sub.add_parser("compare", help="compare two bundles (cross-machine policy)")
    comp.add_argument("--a", required=True)
    comp.add_argument("--b", required=True)
    comp.set_defaults(func=cmd_compare)

    brief = sub.add_parser("brief", help="digest of committed bundles")
    brief.set_defaults(func=cmd_brief)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
