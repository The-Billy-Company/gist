#!/usr/bin/env python3
"""Certificate reproducibility gate.

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

A certificate is only a claim until a third party can regenerate it from the
bundle. This gate enforces that, and nothing about any one package's physics:
what it knows is that a bundle must be **well-formed and complete**, and it
learns what "complete" means for this package from `guard/profile.py`. The
package's own coherence checks — the ones that need to know what a layer
measures — arrive as ``CHARTER.audit``.

  --artifacts : the output dir holds every required file, and its corpus hashes,
                exact tool identities, machine metadata, and rostered layer
                headers + sidecars agree with each other.
  --dataviz   : the figure scripts are generated FROM that committed data, not
                transcribed — fail if any figure script still says "transcribe" /
                "hardcoded" / "manual" or never actually reads its source CSV.

``machine.json`` records a ``git_commit`` when one is available, but it is
**provenance, not a requirement**: a commit only helps a human trace a number
back to a tree, and it says nothing about whether the bundle reproduces. So
nothing here resolves, compares, or demands it — a mint from a dirty tree, a
detached worktree, or an exported tarball is judged purely on its bytes. What
the certificate claimed, and when, is recorded by ``ledger.py``.

Usage: artifacts.py [--artifacts-dir DIR] [--dataviz-dir DIR]
                    [--artifacts] [--dataviz] [--public-safe]
Exit 0 iff every requested check passes; 2 if a certificate dir is simply absent
or pending regeneration (REGENERATE.md without machine.json).
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from charter import read_json, read_tsv
from profile import CHARTER
from publish import check_public_safe

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]  # guard → certificate → bench → package root

# Two components is a real release shape, not a truncated one — GNU grep is `3.12`.
SEMVER = re.compile(r"v?\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?")
SHA256_ID = re.compile(r"sha256:[0-9a-f]{64}", re.I)
SHA256 = re.compile(r"[0-9a-f]{64}", re.I)
TRANSCRIBE_MARKERS = re.compile(r"transcrib|hardcod|\bmanual\b|hand-wave|paste (?:it|the)", re.I)
CSV_READ = re.compile(
    r"read_csv|DictReader|loadtxt|genfromtxt|csv\.reader|json\.load|open\([^)]*\.(csv|json)"
)


def _check_tools(path: Path, problems: list[str]) -> set[str]:
    """Every tool the bundle names must be pinned to an exact, distinct identity."""
    if not path.is_file():
        return set()
    identities: dict[str, str] = {}
    digests: dict[str, str] = {}
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        tool, *tokens = line.split() or [""]
        if not tool:
            continue
        if not tokens:
            problems.append(f"tool-versions.txt:{line_no}: expected '<tool> <identity>...'")
            continue
        if tool in identities:
            problems.append(f"tool-versions.txt: duplicate tool identity: {tool}")
        identities[tool] = " ".join(tokens)
        for token in tokens:
            if SHA256_ID.fullmatch(token):
                digests[tool] = token.lower()
            elif not SEMVER.fullmatch(token):
                problems.append(
                    f"tool-versions.txt:{line_no}: {tool} needs exact semver or "
                    f"executable sha256, got {token!r}"
                )
    # One digest under two tool ids means both resolved to the same file — the
    # signature of a version-manager shim, where `command -v` hands back the
    # multiplexer (a mise shim symlinks to `mise`) rather than the rival. Such a
    # line still reads as an exact pin, so nothing but this check separates it
    # from a real one.
    collisions: dict[str, list[str]] = {}
    for tool, digest in digests.items():
        collisions.setdefault(digest, []).append(tool)
    for digest, sharers in sorted(collisions.items()):
        if len(sharers) > 1:
            problems.append(
                f"tool-versions.txt: {', '.join(sorted(sharers))} share one executable "
                f"digest ({digest[7:21]}…) — a shim resolved them to the same binary, "
                f"so none of them is pinned"
            )
    problems.extend(
        f"tool-versions.txt missing an exact identity for: {tool}"
        for tool in CHARTER.required_tools
        if tool not in identities
    )
    if unknown := identities.keys() - CHARTER.support_tools - CHARTER.bench_tools:
        problems.append(f"tool-versions.txt has unknown tool ids: {', '.join(sorted(unknown))}")
    return set(identities)


def _check_manifest(path: Path, meta: dict[str, object], problems: list[str]) -> None:
    """The corpus manifest must hash a real, deduplicated tree that machine.json agrees with."""
    fields, rows = read_tsv(path, problems)
    expected = ["path", "size_bytes", "sha256"]
    if fields and fields != expected:
        problems.append(f"corpus-manifest.tsv header must be {expected}, got {fields}")
        return
    seen: set[str] = set()
    total = 0
    for line_no, row in enumerate(rows, 2):
        name, size, digest = (row.get(field, "") for field in expected)
        if not name or name in seen:
            problems.append(f"corpus-manifest.tsv:{line_no}: empty or duplicate path {name!r}")
        seen.add(name)
        try:
            n = int(size)
            if n < 0:
                raise ValueError
            total += n
        except ValueError:
            problems.append(f"corpus-manifest.tsv:{line_no}: invalid size {size!r}")
        if not SHA256.fullmatch(digest):
            problems.append(f"corpus-manifest.tsv:{line_no}: invalid sha256 {digest!r}")
    if not rows:
        problems.append("corpus-manifest.tsv has no file rows")
    if meta:
        if meta.get("corpus_file_count") != len(rows):
            problems.append("machine.json corpus_file_count != manifest row count")
        if meta.get("corpus_total_bytes") != total:
            problems.append("machine.json corpus_total_bytes != manifest size sum")


def _check_layers(bundle: Path, problems: list[str]) -> None:
    """Fail closed when the certificate promises layers it does not ship.

    Two independent proofs per layer, because they fail differently: a missing
    **header** is a mint that never ran that step, and a missing **sidecar** is a
    section of prose with no measurement under it. The second is the dangerous
    one — it reads exactly like evidence.

    """
    problems.extend(
        f"missing {CHARTER.package} layer artifact: {name} "
        "(run the full bench/certificate/mint/mint.sh — never a partial mint)"
        for name in CHARTER.layer_sidecars
        if not (bundle / name).is_file()
    )
    cert = bundle / "CERTIFICATE.md"
    if not cert.is_file():
        return
    text = cert.read_text(errors="replace")
    problems.extend(
        f"CERTIFICATE.md missing section {header!r} — "
        "the header promises this layer; run the full mint.sh"
        for header in CHARTER.layer_headers
        if header not in text
    )
    problems.extend(
        f"CERTIFICATE.md carries a retired claim its evidence no longer supports: {claim!r}"
        for claim in CHARTER.forbidden_claims
        if claim in text
    )


def check_artifacts(bundle: Path, public_safe: bool = False) -> list[str]:
    """Validate a certificate artifact directory.

    Returns a problem list, ``["__ABSENT__"]`` when the bundle is missing or
    pending regeneration, or an empty list on success.
    """
    if not bundle.is_dir():
        print(f"  (no certificate dir at {bundle} — run `bench/certificate/mint/mint.sh` first)")
        return ["__ABSENT__"]
    if (bundle / "REGENERATE.md").is_file() and not (bundle / "machine.json").is_file():
        print(f"  (certificate pending regeneration at {bundle} — see REGENERATE.md)")
        return ["__ABSENT__"]
    problems: list[str] = []
    problems.extend(
        f"missing required artifact: {name}"
        for name in CHARTER.required_files
        if not (bundle / name).is_file()
    )
    machine = read_json(bundle / "machine.json", problems)
    meta = machine if isinstance(machine, dict) else {}
    problems.extend(
        f"machine.json missing key: {key}"
        for key in CHARTER.required_machine_keys
        if key not in meta
    )
    tools = _check_tools(bundle / "tool-versions.txt", problems)
    _check_manifest(bundle / "corpus-manifest.tsv", meta, problems)
    _check_layers(bundle, problems)
    CHARTER.audit(bundle, meta, tools, problems)
    if public_safe:
        problems.extend(check_public_safe(bundle, meta))
    return problems


def check_dataviz(directory: Path) -> list[str]:
    """Fail if figure scripts transcribe numbers instead of reading committed data."""
    scripts = sorted(directory.glob("*.py"))
    if not scripts:
        return [f"no figure scripts under {directory}"]
    problems: list[str] = []
    for script in scripts:
        text = script.read_text()
        marker = TRANSCRIBE_MARKERS.search(text)
        if marker:
            line = text[: marker.start()].count("\n") + 1
            problems.append(
                f"{script.name}: transcribed figure — says {marker.group(0)!r} at line "
                f"{line} (generate from committed CSV instead)"
            )
        elif not CSV_READ.search(text):
            problems.append(
                f"{script.name}: does not read a committed .csv/.json "
                "(figures must be generated from raw data, not inlined)"
            )
    return problems


def main() -> int:
    """Run artifact and/or dataviz reproducibility checks."""
    ap = argparse.ArgumentParser(description=f"{CHARTER.package} certificate gate")
    # Defaults to the COMMITTED receipts, not the mint's scratch home: a gate
    # asked "is the evidence reproducible" must answer about bytes a reader can
    # actually fetch. The mint passes `--artifacts-dir` for its own pre-publish
    # check of the bundle it just wrote.
    ap.add_argument("--artifacts-dir", type=Path, default=KERNEL / CHARTER.published_dir)
    ap.add_argument("--dataviz-dir", type=Path, default=KERNEL / "assets" / "figures")
    ap.add_argument("--artifacts", action="store_true", help="run only the artifacts check")
    ap.add_argument("--dataviz", action="store_true", help="run only the dataviz check")
    ap.add_argument(
        "--public-safe",
        action="store_true",
        help="also refuse a bundle that would leak a private corpus (publish gate)",
    )
    args = ap.parse_args()
    run_art = args.artifacts or not args.dataviz
    run_dv = args.dataviz or not args.artifacts

    rc = 0
    if run_art:
        print(f"[artifacts] {args.artifacts_dir}")
        problems = check_artifacts(args.artifacts_dir, public_safe=args.public_safe)
        if problems == ["__ABSENT__"]:
            rc = max(rc, 2)
        elif problems:
            for problem in problems:
                print(f"  - {problem}")
            print("  FAIL: certificate is not reproducible from committed bytes.")
            rc = max(rc, 1)
        else:
            print("  ok: all required artifacts + metadata present.")
    if run_dv:
        print(f"[dataviz] {args.dataviz_dir}")
        problems = check_dataviz(args.dataviz_dir)
        if problems:
            for problem in problems:
                print(f"  - {problem}")
            print("  FAIL: figures are transcribed, not generated from committed raw data.")
            rc = max(rc, 1)
        else:
            print("  ok: every figure script is generated from committed raw data.")
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
