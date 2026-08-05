#!/usr/bin/env python3
"""What **gist** certifies — the one file in `guard/` that is not vendored.

Every other module here is byte-identical across the four packages and holds the
*method*: what makes a bundle reproducible, what a ledger drift looks like, when
a release may be cut. This file holds the *claim*, and it is gist's alone.

gist is the indexed pattern-search product. Its certificate answers one question
that only a package shipping a `gist` binary can ask — "is this faster than
ripgrep, on ripgrep's own terms, and does it stay a drop-in while being so?" —
across four Layer A lanes plus portability and the no-index scanner:

    A  cold, warm, ranked, and in-process, over 12 probe classes vs seven rivals
    H  the portability matrix, graded by what was actually executed
    I  scanner mode — gist with the index taken away, on ripgrep's home turf

The engine layers (B–E, J, L) moved to `irregex` and the retrieval and
multi-pattern layers (F, G, K) to `relate` when the certificate was split, on the
rule the bench charters state: **a package certifies what it builds.** A claim
measurable by linking the engine belongs upstream; a claim needing a running
product binary belongs to whichever package can execute it. Those layers are not
missing here — they are published by their owners, over their own corpora, with
their own ledgers.

Shell reads the roster from this file rather than re-deriving it::

    python3 bench/certificate/guard/profile.py headers
    python3 bench/certificate/guard/profile.py sidecars
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from charter import Charter, Headline, Layer, geomean, main, read_json, read_tsv

#: The 12-class probe registry, mirroring `irregex/bench/apparatus/harness/probes.zig`
#: so the macroscopic (process-vs-process) and microscopic (in-process) halves of
#: Layer A grade the same questions. Deliberately includes saturating needles
#: (`regex-eol`, `regex-dense-scan`) where the trigram prefilter admits the whole
#: tree — the cases ripgrep is built to win. A certificate that raced only the
#: selective classes would be a sales sheet.
CERT_CLASSES = frozenset(
    {
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
)

#: Tools that appear as a timed column somewhere in the bundle.
BENCH_TOOLS = frozenset({"gist", "rg", "csearch", "zoekt", "ugrep", "ag", "ggrep", "gitgrep"})
#: Tools that build or drive the measurement but are never themselves timed.
SUPPORT_TOOLS = frozenset({"zig", "hyperfine"})

_TALLY = re.compile(r"across (\d+) classes: (\d+) win · (\d+) parity · (\d+) loss")
_RATIO = re.compile(r"^([\d.]+)x$")


def _check_cells(
    bundle: Path, meta: dict[str, object], tools: set[str], problems: list[str]
) -> None:
    """Layer A's matrix must be exactly classes × timed tools, with a receipt per cell.

    This is the check that makes a headline speedup non-negotiable. A bundle can
    be complete and still be a lie by omission — race eleven of twelve classes,
    drop the tool that won, and the geomean improves without a single false
    number. So the cell set is compared for *equality* against the cross product,
    every cell is traced back to one hyperfine export holding its own samples,
    and every export is cross-checked against the command log. Nothing here trusts
    a median; it verifies the median had the runs it claims.

    """
    macro_fields, macro = read_tsv(bundle / "certify_macro.csv", problems)
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
    measured = tools & BENCH_TOOLS
    expected = {f"{name}__{tool}.json" for name in CERT_CLASSES for tool in measured}
    if classes != set(CERT_CLASSES):
        problems.append("certify_macro.csv class set != the certificate class registry")
    if macro_cells != expected:
        problems.append("certify_macro.csv cell matrix != certificate classes x timed tools")
    if not macro_cells:
        problems.append("certify_macro.csv has no benchmark cells")

    micro_fields, micro = read_tsv(bundle / "certify.csv", problems)
    if micro_fields and "class" not in micro_fields:
        problems.append("certify.csv must contain a class column")
    if {row.get("class", "") for row in micro} != set(CERT_CLASSES):
        problems.append("certify.csv class set != the certificate class registry")

    raw = {path.name: path for path in (bundle / "raw").glob("*.json")}
    if missing := sorted(expected - raw.keys()):
        problems.append(f"raw cells missing: {', '.join(missing)}")
    if extra := sorted(raw.keys() - expected):
        problems.append(f"unexpected raw cells: {', '.join(extra)}")

    commands: dict[str, str] = {}
    runs = meta.get("runs")
    for name, path in raw.items():
        doc = read_json(path, problems)
        if not isinstance(doc, dict):
            continue
        results = doc.get("results")
        if not isinstance(results, list) or len(results) != 1 or not isinstance(results[0], dict):
            problems.append(f"raw/{name}: expected exactly one hyperfine result")
            continue
        command, times = results[0].get("command"), results[0].get("times")
        exit_codes = results[0].get("exit_codes")
        if not isinstance(command, str) or not command:
            problems.append(f"raw/{name}: missing exact timed command")
        else:
            commands[name] = command
            # `… 2>&1 | wc -l` times a pipeline whose exit status is wc's, so a
            # rival that crashed mid-run still reads as a clean fast sample.
            if re.search(r"2>&1\s*\|\s*wc\s+-l", command):
                problems.append(f"raw/{name}: timed command masks producer status")
        if not isinstance(times, list) or not times:
            problems.append(f"raw/{name}: missing timing samples")
        elif isinstance(runs, int) and len(times) != runs:
            problems.append(f"raw/{name}: {len(times)} samples != machine.json runs={runs}")
        samples = len(times) if isinstance(times, list) else 0
        if not isinstance(exit_codes, list) or len(exit_codes) != samples:
            problems.append(f"raw/{name}: exit-code samples do not match timing samples")
        elif any(code not in (0, 1) for code in exit_codes):
            problems.append(f"raw/{name}: timed a hard exit >=2")

    logged: dict[str, str] = {}
    log = bundle / "command-log.txt"
    if log.is_file():
        for line_no, line in enumerate(log.read_text().splitlines(), 1):
            name, separator, command = line.partition("\t")
            if not separator or not command:
                problems.append(f"command-log.txt:{line_no}: expected '<raw-file>\\t<command>'")
            elif name in logged:
                problems.append(f"command-log.txt:{line_no}: duplicate raw cell {name}")
            else:
                logged[name] = command
    if logged.keys() != commands.keys():
        problems.append("command-log.txt cell set != raw hyperfine cell set")
    problems.extend(
        f"command-log.txt command differs from raw/{name}"
        for name in logged.keys() & commands.keys()
        if logged[name] != commands[name]
    )


def _check_index_sizes(bundle: Path, problems: list[str]) -> None:
    """The index's own size accounting must add up and name its runtime components.

    gist's speed claim is bought with disk, so the certificate publishes what it
    spent. An index whose parts do not sum to its declared requirement is either
    mis-measured or quietly excluding a file it needs at query time — and the
    second is how a footprint comparison against csearch becomes flattering.

    """
    doc = read_json(bundle / "index-sizes.json", problems)
    if not isinstance(doc, dict) or not isinstance(doc.get("gist"), dict):
        return
    if doc.get("schema_version") != 2:
        problems.append("index-sizes.json schema_version must be 2")
    gist = doc["gist"]
    fields = ("posting_bytes", "path_bytes", "freshness_bytes", "required_bytes", "workspace_bytes")
    if any(not isinstance(gist.get(f), int) or gist[f] < 0 for f in fields):
        problems.append(f"index-sizes.json gist fields must be non-negative integers: {fields}")
        return
    parts = gist["posting_bytes"] + gist["path_bytes"] + gist["freshness_bytes"]
    if gist["required_bytes"] != parts:
        problems.append("index-sizes.json required_bytes != posting + path + freshness")
    expected = {
        "index.gist": gist["posting_bytes"],
        "paths.list": gist["path_bytes"],
        "built.ns": gist["freshness_bytes"],
    }
    if gist.get("required_files") != expected:
        problems.append("index-sizes.json required_files != required runtime components")


def audit(bundle: Path, meta: dict[str, object], tools: set[str], problems: list[str]) -> None:
    """gist's coherence checks, beyond the generic well-formedness contract."""
    _check_cells(bundle, meta, tools, problems)
    _check_index_sizes(bundle, problems)


def measure(bundle: Path, text: str) -> dict[str, float | None]:
    """gist's headline numbers for the ledger: the cold-race tally and its geomean.

    Parsed from the rendered certificate rather than from `certify_macro.csv`, so
    a historical mint reconstructs exactly as it was published. The certificate
    is the artifact under version control; the sidecars on disk only ever
    describe the latest run, which would silently rewrite history the next time
    anyone re-minted.

    """
    tally = _TALLY.search(text)
    lines, section = text.splitlines(), []
    for i, line in enumerate(lines):
        if line.startswith("## ") and "Layer A — macroscopic dominance" in line:
            rest = lines[i + 1 :]
            end = next((j for j, ln in enumerate(rest) if ln.startswith("## ")), len(rest))
            section = rest[:end]
            break
    # The speedup column is positional, but a pattern containing `|` (the literal
    # alternation class) shifts it — so take the one cell shaped like a ratio.
    speedups = []
    for row in section:
        if not row.startswith("|"):
            continue
        ratios = [m.group(1) for cell in row.split("|") if (m := _RATIO.match(cell.strip()))]
        if len(ratios) == 1:
            speedups.append(float(ratios[0]))
    geo = geomean(speedups)
    return {
        "wins": float(tally.group(2)) if tally else None,
        "parity": float(tally.group(3)) if tally else None,
        "loss": float(tally.group(4)) if tally else None,
        "rg_geomean": round(geo, 2) if geo else None,
    }


CHARTER = Charter(
    package="gist",
    artifact_dir=".gist",
    roster=(
        Layer("A-micro", "Layer A — empirical, microscopic"),
        Layer("A-macro", "Layer A — macroscopic dominance"),
        Layer("A-warm", "Layer A — warm tier"),
        Layer(
            "A-rank",
            "Layer A — the `--rank` lane",
            "## Layer A — the `--rank` lane (definition-first, the shape rg can't express)",
            "certify_rank.csv",
        ),
        Layer(
            "H",
            "Layer H — portability",
            "## Layer H — portability (target matrix, executed)",
            "portable.json",
        ),
        Layer(
            "I",
            "Layer I — scanner mode + ripgrep conformance",
            "## Layer I — scanner mode + ripgrep conformance (no index)",
            "scanner.csv",
        ),
    ),
    required_files=(
        "CERTIFICATE.md",
        "certify.csv",
        "certify_macro.csv",
        "machine.json",
        "tool-versions.txt",
        "corpus-manifest.tsv",
        "command-log.txt",
        "index-sizes.json",
    ),
    required_machine_keys=(
        "cpu_model",
        "cpu_count",
        "ram_bytes",
        "os",
        "kernel",
        "filesystem",
        "corpus_id",
        "corpus_file_count",
        "corpus_total_bytes",
        "runs",
        "warmup",
        "roots",
    ),
    required_tools=("gist", "zig", "rg", "csearch", "zoekt", "hyperfine"),
    support_tools=SUPPORT_TOOLS,
    bench_tools=BENCH_TOOLS,
    headlines=(
        Headline("rg_geomean", "cold vs rg", "× geo"),
        Headline("wins", "win", ""),
        Headline("parity", "parity", ""),
        # The only headline where down is good: a class gist loses to ripgrep.
        Headline("loss", "loss", "", rising=False),
    ),
    audit=audit,
    measure=measure,
)


if __name__ == "__main__":
    raise SystemExit(main(CHARTER, sys.argv))
