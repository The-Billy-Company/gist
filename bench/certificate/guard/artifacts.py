#!/usr/bin/env python3
"""Certificate reproducibility gate.

A certificate is only a claim until a third party can regenerate it from the
bundle. This gate enforces two independent contracts:

  --artifacts : a certificate output dir holds every required file, and its
                corpus hashes, exact tool identities, raw-cell matrix, command
                log, machine metadata, and size accounting agree.
  --dataviz   : the figure scripts are generated FROM that committed data, not
                transcribed — fail if any `gist_*.py` still says "transcribe" /
                "hardcoded" / "manual" or never actually reads its source CSV.

``machine.json`` records a ``git_commit`` when one is available, but it is
**provenance, not a requirement**: a commit only helps a human trace a number
back to a tree, and it says nothing about whether the bundle reproduces. So
nothing here resolves, compares, or demands it — a mint from a dirty tree, a
detached worktree, or an exported tarball is judged purely on its bytes. What
the certificate claimed, and when, is recorded by ``ledger.py``.

Usage: check_artifacts.py [--artifacts-dir DIR] [--dataviz-dir DIR]
                          [--artifacts] [--dataviz]   (default: run both)
Exit 0 iff every requested check passes; 2 if a certificate dir is simply absent
or pending regeneration (REGENERATE.md without machine.json).
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import re

# Side-cars and headers that prove each layer was minted, not merely named in
# the header. Every narrower surface the header promises (codex space, the
# --rank lane, the relate face) ships its own fail-closed sidecar — no claim
# without a receipt. Both views come from the shared roster, so a new layer
# widens this gate, the ledger, and the shell completeness check from one row.
from layers import REQUIRED_LAYER_FILES, REQUIRED_LAYER_HEADERS


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[5]  # ... -> repo root

REQUIRED_FILES = (
    "CERTIFICATE.md",
    "certify.csv",
    "certify_macro.csv",
    "machine.json",
    "tool-versions.txt",
    "corpus-manifest.tsv",
    "command-log.txt",
    "index-sizes.json",
)
FORBIDDEN_LAYER_C_CLAIMS = (
    "cycles/byte sits on the hardware ceiling",
    "no implementation on this chip can go faster",
    "**Verdict — memory-bandwidth-bound.**",
)
REQUIRED_MACHINE_KEYS = (
    "cpu_model",
    "cpu_count",
    "ram_bytes",
    "os",
    "kernel",
    "filesystem",
    "corpus_file_count",
    "corpus_total_bytes",
    "runs",
    "warmup",
    "roots",
)
REQUIRED_TOOLS = ("gist", "zig", "rg", "csearch", "zoekt", "hyperfine")
SUPPORT_TOOLS = {"zig", "hyperfine"}
BENCH_TOOLS = {"gist", "rg", "csearch", "zoekt", "ugrep", "ag", "ggrep", "gitgrep"}
CERT_CLASSES = {
    "literal-rare",
    "literal-dotted",
    "literal-common",
    "literal-punct2",
    "regex-decl",
    "regex-dotted",
    "regex-anchored",
    "regex-classcount",
    "regex-alternation",
    "regex-dense-scan",
    "regex-eol",
    "regex-litalt",
}
SEMVER = re.compile(r"v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?")
SHA256_ID = re.compile(r"sha256:[0-9a-f]{64}", re.I)
SHA256 = re.compile(r"[0-9a-f]{64}", re.I)
TRANSCRIBE_MARKERS = re.compile(r"transcrib|hardcod|\bmanual\b|hand-wave|paste (?:it|the)", re.I)
CSV_READ = re.compile(
    r"read_csv|DictReader|loadtxt|genfromtxt|csv\.reader|json\.load|open\([^)]*\.(csv|json)"
)


def _json(path: Path, problems: list[str]) -> object | None:
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        problems.append(f"{path.name} is not valid JSON: {error}")
        return None


def _tsv(path: Path, problems: list[str]) -> tuple[list[str], list[dict[str, str]]]:
    if not path.is_file():
        return [], []
    try:
        with path.open(newline="", errors="surrogateescape") as source:
            reader = csv.DictReader(source, delimiter="\t")
            return reader.fieldnames or [], list(reader)
    except (OSError, csv.Error) as error:
        problems.append(f"{path.name} is not valid TSV: {error}")
        return [], []


def _check_tools(path: Path, problems: list[str]) -> set[str]:
    if not path.is_file():
        return set()
    identities: dict[str, str] = {}
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            problems.append(f"tool-versions.txt:{line_no}: expected '<tool> <identity>'")
            continue
        tool, identity = parts
        if tool in identities:
            problems.append(f"tool-versions.txt: duplicate tool identity: {tool}")
        identities[tool] = identity
        if not (SEMVER.fullmatch(identity) or SHA256_ID.fullmatch(identity)):
            problems.append(
                f"tool-versions.txt:{line_no}: {tool} needs exact semver or "
                f"executable sha256, got {identity!r}"
            )
    for tool in REQUIRED_TOOLS:
        if tool not in identities:
            problems.append(f"tool-versions.txt missing an exact identity for: {tool}")
    unknown = identities.keys() - SUPPORT_TOOLS - BENCH_TOOLS
    if unknown:
        problems.append(f"tool-versions.txt has unknown tool ids: {', '.join(sorted(unknown))}")
    return set(identities)


def _check_manifest(path: Path, meta: dict[str, object], problems: list[str]) -> None:
    fields, rows = _tsv(path, problems)
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


def _check_cells(d: Path, meta: dict[str, object], tools: set[str], problems: list[str]) -> None:
    macro_fields, macro = _tsv(d / "certify_macro.csv", problems)
    if macro_fields and not {"class", "tool"}.issubset(macro_fields):
        problems.append("certify_macro.csv must contain class and tool columns")
    macro_cells: set[str] = set()
    classes: set[str] = set()
    for line_no, row in enumerate(macro, 2):
        cell = f"{row.get('class', '')}__{row.get('tool', '')}.json"
        if cell in macro_cells:
            problems.append(f"certify_macro.csv:{line_no}: duplicate cell {cell}")
        macro_cells.add(cell)
        classes.add(row.get("class", ""))
    measured_tools = tools & BENCH_TOOLS
    expected = {
        f"{class_name}__{tool}.json" for class_name in CERT_CLASSES for tool in measured_tools
    }
    if classes != CERT_CLASSES:
        problems.append("certify_macro.csv class set != the certificate class registry")
    if macro_cells != expected:
        problems.append("certify_macro.csv cell matrix != certificate classes x timed tools")
    if not macro_cells:
        problems.append("certify_macro.csv has no benchmark cells")

    micro_fields, micro = _tsv(d / "certify.csv", problems)
    if micro_fields and "class" not in micro_fields:
        problems.append("certify.csv must contain a class column")
    micro_classes = {row.get("class", "") for row in micro}
    if micro_classes != CERT_CLASSES:
        problems.append("certify.csv class set != the certificate class registry")

    raw = {path.name: path for path in (d / "raw").glob("*.json")}
    missing, extra = sorted(expected - raw.keys()), sorted(raw.keys() - expected)
    if missing:
        problems.append(f"raw cells missing: {', '.join(missing)}")
    if extra:
        problems.append(f"unexpected raw cells: {', '.join(extra)}")

    commands: dict[str, str] = {}
    runs = meta.get("runs")
    for name, path in raw.items():
        doc = _json(path, problems)
        if not isinstance(doc, dict):
            continue
        results = doc.get("results")
        if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict):
            problems.append(f"raw/{name}: expected exactly one hyperfine result")
            continue
        result = results[0]
        command = result.get("command")
        times = result.get("times")
        exit_codes = result.get("exit_codes")
        if not isinstance(command, str) or not command:
            problems.append(f"raw/{name}: missing exact timed command")
        else:
            commands[name] = command
            if re.search(r"2>&1\s*\|\s*wc\s+-l", command):
                problems.append(f"raw/{name}: timed command masks producer status")
        if not isinstance(times, list) or not times:
            problems.append(f"raw/{name}: missing timing samples")
        elif isinstance(runs, int) and len(times) != runs:
            problems.append(f"raw/{name}: {len(times)} samples != machine.json runs={runs}")
        sample_count = len(times) if isinstance(times, list) else 0
        if not isinstance(exit_codes, list) or len(exit_codes) != sample_count:
            problems.append(f"raw/{name}: exit-code samples do not match timing samples")
        elif any(code not in (0, 1) for code in exit_codes):
            problems.append(f"raw/{name}: timed a hard exit >=2")

    logged: dict[str, str] = {}
    log = d / "command-log.txt"
    if log.is_file():
        for line_no, line in enumerate(log.read_text().splitlines(), 1):
            name, separator, command = line.partition("\t")
            if not separator or not command:
                problems.append(
                    f"command-log.txt:{line_no}: expected '<raw-file>\\t<exact-command>'"
                )
            elif name in logged:
                problems.append(f"command-log.txt:{line_no}: duplicate raw cell {name}")
            else:
                logged[name] = command
    if logged.keys() != commands.keys():
        problems.append("command-log.txt cell set != raw hyperfine cell set")
    for name in logged.keys() & commands.keys():
        if logged[name] != commands[name]:
            problems.append(f"command-log.txt command differs from raw/{name}")


def _check_layers(d: Path, problems: list[str]) -> None:
    """Fail closed when the certificate promises layers/surfaces it does not ship."""
    problems.extend(
        f"missing Layer B–G artifact: {name} "
        "(run the full bench/certify/certify.sh — never a partial mint)"
        for name in REQUIRED_LAYER_FILES
        if not (d / name).is_file()
    )
    cert = d / "CERTIFICATE.md"
    if not cert.is_file():
        return
    text = cert.read_text(errors="replace")
    problems.extend(
        f"CERTIFICATE.md missing section {header!r} — "
        "the header promises this layer/surface; run the full certify.sh"
        for header in REQUIRED_LAYER_HEADERS
        if header not in text
    )
    problems.extend(
        f"CERTIFICATE.md overstates Layer C with retired claim: {claim!r}"
        for claim in FORBIDDEN_LAYER_C_CLAIMS
        if claim in text
    )

    roof = _json(d / "roofline.json", problems)
    if not isinstance(roof, dict):
        return
    tiers = {
        tier.get("name"): tier.get("gbps")
        for tier in roof.get("tiers", [])
        if isinstance(tier, dict)
    }
    dram = tiers.get("DRAM")
    scans = roof.get("gist_scan", [])
    pure = next(
        (
            scan.get("gbps")
            for scan in scans
            if isinstance(scan, dict) and "0 matches" in str(scan.get("kind", ""))
        ),
        None,
    )
    if (
        not isinstance(dram, int | float)
        or dram <= 0
        or not isinstance(pure, int | float)
        or pure <= 0
    ):
        problems.append("roofline.json needs positive DRAM and full-scan GB/s measurements")
        return
    ratio = pure / dram
    near_roof = ratio >= 0.8
    verdict = "near the measured roof" if near_roof else "material headroom remains"
    if verdict not in text:
        problems.append(
            f"CERTIFICATE.md Layer C verdict disagrees with measured {ratio:.0%} of roof"
        )
    if not near_roof and "does **not** certify DRAM saturation" not in text:
        problems.append("sub-80% Layer C result must explicitly reject a DRAM-saturation claim")


def _check_index_sizes(path: Path, problems: list[str]) -> None:
    doc = _json(path, problems)
    if not isinstance(doc, dict) or not isinstance(doc.get("gist"), dict):
        return
    if doc.get("schema_version") != 2:
        problems.append("index-sizes.json schema_version must be 2")
    gist = doc["gist"]
    fields = ("posting_bytes", "path_bytes", "freshness_bytes", "required_bytes", "workspace_bytes")
    if any(not isinstance(gist.get(field), int) or gist[field] < 0 for field in fields):
        problems.append(f"index-sizes.json gist fields must be non-negative integers: {fields}")
        return
    parts = gist["posting_bytes"] + gist["path_bytes"] + gist["freshness_bytes"]
    if gist["required_bytes"] != parts:
        problems.append("index-sizes.json required_bytes != posting + path + freshness")
    expected_files = {
        "index.gist": gist["posting_bytes"],
        "paths.list": gist["path_bytes"],
        "built.ns": gist["freshness_bytes"],
    }
    if gist.get("required_files") != expected_files:
        problems.append("index-sizes.json required_files != required runtime components")


def check_artifacts(d: Path) -> list[str]:
    """Validate a certificate artifact directory.

    Returns a problem list, ``["__ABSENT__"]`` when the bundle is missing
    or pending regeneration, or an empty list on success.
    """
    if not d.is_dir():
        print(f"  (no certificate dir at {d} — run `bench/certify/certify.sh` first)")
        return ["__ABSENT__"]
    if (d / "REGENERATE.md").is_file() and not (d / "machine.json").is_file():
        print(f"  (certificate pending regeneration at {d} — see REGENERATE.md)")
        return ["__ABSENT__"]
    problems: list[str] = []
    for name in REQUIRED_FILES:
        if not (d / name).is_file():
            problems.append(f"missing required artifact: {name}")
    machine = _json(d / "machine.json", problems)
    meta = machine if isinstance(machine, dict) else {}
    for key in REQUIRED_MACHINE_KEYS:
        if key not in meta:
            problems.append(f"machine.json missing key: {key}")
    tools = _check_tools(d / "tool-versions.txt", problems)
    _check_manifest(d / "corpus-manifest.tsv", meta, problems)
    _check_cells(d, meta, set(tools), problems)
    _check_index_sizes(d / "index-sizes.json", problems)
    _check_layers(d, problems)
    return problems


def check_dataviz(d: Path) -> list[str]:
    """Fail if figure scripts transcribe numbers instead of reading committed data."""
    scripts = sorted(d.glob("gist_*.py"))
    if not scripts:
        return [f"no gist_*.py figure scripts under {d}"]
    problems: list[str] = []
    for s in scripts:
        text = s.read_text()
        m = TRANSCRIBE_MARKERS.search(text)
        if m:
            line = text[: m.start()].count("\n") + 1
            problems.append(
                f"{s.name}: transcribed figure — says {m.group(0)!r} at line "
                f"{line} (generate from committed CSV instead)"
            )
        elif not CSV_READ.search(text):
            problems.append(
                f"{s.name}: does not read a committed .csv/.json "
                "(figures must be generated from raw data, not inlined)"
            )
    return problems


def main() -> int:
    """Run artifact and/or dataviz reproducibility checks."""
    ap = argparse.ArgumentParser()
    ap.add_argument("--artifacts-dir", type=Path, default=REPO / ".local" / "gist-verify")
    ap.add_argument(
        "--dataviz-dir",
        type=Path,
        default=REPO / "scripts" / "act" / "workspace" / "dataviz" / "figures",
    )
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
