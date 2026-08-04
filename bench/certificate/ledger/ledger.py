#!/usr/bin/env python3
"""Mint ledger — the certificate's history, so a re-mint is never silent.

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`). What this
package certifies and which numbers are worth watching come from its own
``guard/profile.py`` charter; nothing below names a layer or a metric.

A certificate is a *rewritten* artifact: the mint regenerates the whole file and
each layer is spliced back afterward by its own reporter. That design is honest
per-mint but amnesiac across mints — nothing in the tree remembered what the
previous certificate said, so a re-mint that improved eight numbers and silently
dropped a whole layer looked identical to a clean one. Documentation pinned to
those numbers then failed far away from the cause, and the only way to
reconstruct what happened was to pickaxe git.

This ledger is that memory. Every mint appends one row recording what the
certificate *claimed* — corpus, the layers actually present, and each headline
number the charter declares — keyed by a content digest of ``CERTIFICATE.md``.
Two questions become cheap:

  * "did the certificate change?"  -> ``verify`` (fail-closed; a certificate on
    disk that no row describes is unrecorded drift, and it names the delta)
  * "what did it say last week?"   -> ``list`` / ``show`` over the recorded rows

**A commit is a reference, never a requirement.** The recorded ``commit`` is
provenance for a human tracing a number back to a tree; it is a plain reference
field. Nothing here compares it, resolves it, or fails without it, so a mint
from a dirty tree, a detached worktree, or an exported tarball records and
verifies exactly like any other.

Storage is two files beside this script: ``ledger.jsonl`` is the machine record
(one JSON object per mint, sorted by time) and ``LEDGER.md`` is the rendered
look-back table, regenerated from it on every write.

Usage:
    ledger.py record [--bundle DIR] [--note TEXT]   append a row for a bundle
    ledger.py verify [--require-layers] [--json]    fail-closed drift gate
    ledger.py status [--json]                       same read, never fails
    ledger.py list [--limit N] [--json]             the look-back table
    ledger.py show [DIGEST | latest] [--json]       one mint in full
    ledger.py backfill [--limit N]                  seed history from git
    ledger.py render                                rebuild LEDGER.md

``verify`` fails on **unrecorded drift** — a certificate on disk that no row
describes. A mint missing a roster layer is always reported, but only fails
under ``--require-layers``: the two have different remedies (``record`` clears
drift; only re-splicing the layer clears a gap), and a gate whose printed fix
doesn't clear it is a gate that gets routed around.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path

# What this package certifies — the layers a complete mint carries, keyed by the
# header substring that proves each was spliced, and the headline numbers worth
# watching across mints. A layer absent from the roster's match is a layer the
# mint dropped: the regression this ledger exists to catch. The charter is shared
# with the reproducibility gate and the shell completeness check, so adding a
# layer is one row there rather than three copies here.
sys.path.insert(
    0, str(Path(__file__).resolve().parent.parent / "guard")
)  # the package's charter lives in the sibling guard/
from profile import CHARTER

LAYERS = CHARTER.probes

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]  # ledger → certificate → bench → package root
LEDGER = HERE / "ledger.jsonl"
RENDER = HERE / "LEDGER.md"
CERTIFICATE = "CERTIFICATE.md"

CORPUS_RE = re.compile(r"corpus:?\s+\*{0,2}(\d+)\*{0,2} files · ([\d.]+) MiB")


@dataclass(frozen=True, slots=True)
class Mint:
    """One certificate as it stood at one moment, keyed by its content digest."""

    recorded: str
    platform: str
    machine: str
    bundle: str
    digest: str
    corpus_files: int = 0
    corpus_mib: float = 0.0
    layers: tuple[str, ...] = ()
    absent: tuple[str, ...] = ()
    #: This mint's headline numbers, keyed by ``Headline.key`` from the package
    #: charter. A key that is absent or ``None`` means the mint did not make that
    #: claim — never that the claim was zero.
    headlines: dict[str, float | None] = field(default_factory=dict)
    commit: str | None = None  # provenance only — never gated on
    note: str = ""

    @property
    def short(self) -> str:
        return self.digest[:12]

    def headline(self, key: str) -> float | None:
        """This mint's value for one headline, or None when it did not claim it."""
        return self.headlines.get(key)


def read_mint(bundle: Path, *, note: str = "", text: str | None = None) -> Mint | None:
    """Build a ledger row from a certificate bundle on disk (None if absent).

    ``text`` overrides the on-disk certificate so a historical blob can be read
    through the same parser as a live one — the backfill path.
    """
    certificate = bundle / CERTIFICATE
    if text is None:
        if not certificate.is_file():
            return None
        try:
            text = certificate.read_text()
        except OSError:
            return None

    machine: dict[str, object] = {}
    if (meta := bundle / "machine.json").is_file():
        try:
            loaded = json.loads(meta.read_text())
            machine = loaded if isinstance(loaded, dict) else {}
        except (OSError, json.JSONDecodeError):
            machine = {}

    headers = [ln for ln in text.splitlines() if ln.startswith("#")]
    present = tuple(name for name, needle in LAYERS.items() if any(needle in h for h in headers))
    corpus = CORPUS_RE.search(text)
    os_field = str(machine.get("os", "")).strip()
    commit = str(machine.get("git_commit", "")).strip() or None

    return Mint(
        recorded=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        platform=os_field.split()[0].lower() if os_field else "unknown",
        machine=str(machine.get("cpu_model", "")) or "unknown",
        bundle=str(bundle.relative_to(KERNEL) if bundle.is_relative_to(KERNEL) else bundle),
        digest=hashlib.sha256(text.encode()).hexdigest(),
        corpus_files=int(corpus.group(1)) if corpus else 0,
        corpus_mib=float(corpus.group(2)) if corpus else 0.0,
        layers=present,
        absent=tuple(name for name in LAYERS if name not in present),
        headlines=CHARTER.measure(bundle, text),
        commit=commit,
        note=note,
    )


def discover(root: Path) -> list[Path]:
    """Every certificate bundle under ``root`` (per-platform subdirs + the flat one)."""
    found = (
        [c for c in sorted(root.iterdir()) if (c / CERTIFICATE).is_file()] if root.is_dir() else []
    )
    return ([root] if (root / CERTIFICATE).is_file() else []) + found


def load() -> list[Mint]:
    if not LEDGER.is_file():
        return []
    mints = []
    for line in LEDGER.read_text().splitlines():
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            continue
        raw["layers"] = tuple(raw.get("layers", ()))
        raw["absent"] = tuple(raw.get("absent", ()))
        mints.append(Mint(**{k: v for k, v in raw.items() if k in Mint.__slots__}))
    return sorted(mints, key=lambda m: m.recorded)


def save(mints: list[Mint]) -> None:
    ordered = sorted(mints, key=lambda m: m.recorded)
    LEDGER.write_text("".join(json.dumps(asdict(m)) + "\n" for m in ordered))
    render(ordered)


def _table(header: list[str], rows: list[list[str]]) -> list[str]:
    """Column-aligned markdown, matching what prettier would reformat this into.

    The renderer owns the alignment so a mint never leaves the tree
    formatter-dirty — every cell here is narrow-width, so codepoint length is
    the display width.
    """
    width = [max(len(cell) for cell in column) for column in zip(header, *rows, strict=True)]

    def fit(cells: list[str]) -> str:
        return "| " + " | ".join(c.ljust(w) for c, w in zip(cells, width, strict=True)) + " |"

    return [fit(header), fit(["-" * w for w in width]), *map(fit, rows)]


def _cell(value: float | None, unit: str) -> str:
    """One headline as a table cell — an em dash where a mint made no such claim."""
    if value is None:
        return "—"
    return f"{value:g}{unit}"


def render(mints: list[Mint] | None = None) -> None:
    """Regenerate the human look-back table from the machine record."""
    mints = load() if mints is None else mints
    lines = [
        "# Certificate mint ledger",
        "",
        "> Generated by `bench/certificate/ledger/ledger.py` from `ledger.jsonl` — do not hand-edit.",
        "> One row per certificate mint, newest first. `layers` is what that mint",
        "> actually carried, so a dropped layer is visible here instead of surfacing",
        "> later as a documentation failure. `commit` is provenance for tracing a",
        "> number back to a tree; nothing gates on it.",
        "",
    ]
    header = [
        "recorded",
        "platform",
        "corpus",
        *(h.column for h in CHARTER.headlines),
        "layers",
        "absent",
        "commit",
    ]
    rows = [
        [
            m.recorded,
            m.platform,
            f"{m.corpus_files} files · {m.corpus_mib} MiB" if m.corpus_files else "—",
            *(_cell(m.headline(h.key), h.unit) for h in CHARTER.headlines),
            " ".join(m.layers) or "—",
            " ".join(m.absent) or "none",
            m.commit[:12] if m.commit else "—",
        ]
        for m in reversed(mints)
    ]
    lines += _table(header, rows) if rows else ["_No mints recorded yet._"]
    if notes := [f"- `{m.short}` — {m.note}" for m in reversed(mints) if m.note]:
        lines += ["", "## Notes", "", *notes]
    RENDER.write_text("\n".join(lines) + "\n")


def delta(current: Mint, previous: Mint | None) -> list[str]:
    """Human-readable differences between a certificate and the last recorded one."""
    if previous is None:
        return ["first recorded mint for this platform"]
    changes = []
    if lost := [n for n in current.absent if n in previous.layers]:
        changes.append(f"LAYERS DROPPED: {', '.join(lost)}")
    if gained := [n for n in current.layers if n in previous.absent]:
        changes.append(f"layers added: {', '.join(gained)}")
    if current.corpus_files != previous.corpus_files:
        changes.append(f"corpus {previous.corpus_files} -> {current.corpus_files} files")
    for spec in CHARTER.headlines:
        now, before = current.headline(spec.key), previous.headline(spec.key)
        if now == before:
            continue
        # A number that vanished is not a number that got worse; say which.
        if now is None:
            changes.append(f"{spec.column} NO LONGER CLAIMED (was {before:g}{spec.unit})")
        elif before is None:
            changes.append(f"{spec.column} now claimed at {now:g}{spec.unit}")
        else:
            improved = (now > before) == spec.rising
            way = "improved" if improved else "REGRESSED"
            changes.append(f"{spec.column} {way} {before:g} -> {now:g}{spec.unit}")
    return changes or ["content changed, headline numbers identical"]


def survey(root: Path) -> list[dict[str, object]]:
    """Compare every bundle on disk against its newest recorded row."""
    recorded = load()
    known = {m.digest for m in recorded}
    report = []
    for bundle in discover(root):
        current = read_mint(bundle)
        if current is None:
            continue
        prior = [m for m in recorded if m.platform == current.platform]
        report.append(
            {
                "bundle": current.bundle,
                "platform": current.platform,
                "digest": current.short,
                "recorded": current.digest in known,
                "absent_layers": list(current.absent),
                "changes": []
                if current.digest in known
                else delta(current, prior[-1] if prior else None),
            }
        )
    return report


def _names(value: object) -> list[str]:
    """Read a string list back out of a survey row (which is typed loosely for JSON)."""
    return [str(v) for v in value] if isinstance(value, list) else []


def _print_survey(report: list[dict[str, object]]) -> None:
    for row in report:
        mark = "✓" if row["recorded"] else "!"
        print(f"  {mark} {row['platform']} [{row['bundle']}] {row['digest']}")
        if not row["recorded"]:
            print("      unrecorded certificate — `ledger.py record` to log it:")
            for change in _names(row["changes"]):
                print(f"        - {change}")
        if absent := _names(row["absent_layers"]):
            print(f"      layers not in this certificate: {', '.join(absent)}")


def backfill(root: Path, limit: int) -> int:
    """Seed the ledger from the certificate's git history (commit = date + reference)."""
    rel = f"{root.relative_to(KERNEL)}/{CERTIFICATE}" if root.is_relative_to(KERNEL) else None
    if rel is None:
        print("backfill needs a bundle inside the repo", file=sys.stderr)
        return 1
    try:
        log = subprocess.check_output(
            ["git", "-C", str(KERNEL), "log", f"-{limit}", "--format=%H %cI", "--", rel],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.CalledProcessError):
        print("no git history available — nothing to backfill", file=sys.stderr)
        return 0

    mints = load()
    known = {m.digest for m in mints}
    added = 0
    for line in reversed(log.splitlines()):
        sha, _, when = line.partition(" ")
        try:
            text = subprocess.check_output(
                ["git", "-C", str(KERNEL), "show", f"{sha}:{rel}"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (OSError, subprocess.CalledProcessError):
            continue
        mint = read_mint(root, text=text)
        if mint is None or mint.digest in known:
            continue
        stamp = datetime.fromisoformat(when.strip()).astimezone(UTC)
        recovered = Mint(
            **{
                **asdict(mint),
                "recorded": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "commit": sha,
                "layers": mint.layers,
                "absent": mint.absent,
            }
        )
        mints.append(recovered)
        known.add(recovered.digest)
        added += 1
        print(
            f"  + {recovered.recorded} {recovered.short} layers={' '.join(recovered.layers) or '—'}"
        )
    save(mints)
    print(f"backfilled {added} mint(s) from git history -> {LEDGER.relative_to(KERNEL)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    """Record and inspect the history of the Dominance-and-Fit Certificate."""
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--artifacts-root", type=Path, default=HERE.parent / "artifact")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    sub = ap.add_subparsers(dest="verb")

    recording = sub.add_parser("record", help="append a row for a bundle on disk")
    recording.add_argument("--bundle", type=Path, default=None)
    recording.add_argument("--note", default="")
    checking = sub.add_parser("verify", help="fail-closed: every certificate on disk is recorded")
    checking.add_argument(
        "--require-layers",
        action="store_true",
        help="also fail when a bundle is missing a roster layer (expects a complete mint)",
    )
    sub.add_parser("status", help="same survey as verify, always exits 0")
    listing = sub.add_parser("list", help="the recorded mints, newest first")
    listing.add_argument("--limit", type=int, default=20)
    showing = sub.add_parser("show", help="one recorded mint in full")
    showing.add_argument("digest", nargs="?", default="latest")
    seeding = sub.add_parser("backfill", help="seed history from git")
    seeding.add_argument("--limit", type=int, default=30)
    sub.add_parser("render", help="rebuild LEDGER.md from ledger.jsonl")
    args = ap.parse_args(argv)

    root = args.artifacts_root.resolve()
    verb = args.verb or "status"

    if verb == "record":
        bundles = [args.bundle.resolve()] if args.bundle else discover(root)
        mints = load()
        known, added = {m.digest for m in mints}, []
        for bundle in bundles:
            mint = read_mint(bundle, note=args.note)
            if mint is None:
                print(f"no {CERTIFICATE} under {bundle}", file=sys.stderr)
                continue
            if mint.digest in known:
                print(f"  = {mint.platform} {mint.short} already recorded")
                continue
            prior = [m for m in mints if m.platform == mint.platform]
            mints.append(mint)
            known.add(mint.digest)
            added.append(mint)
            print(
                f"  + {mint.platform} {mint.short} — {'; '.join(delta(mint, prior[-1] if prior else None))}"
            )
        if added:
            save(mints)
            print(f"recorded {len(added)} mint(s) -> {LEDGER.relative_to(KERNEL)}")
        return 0

    if verb in {"verify", "status"}:
        report = survey(root)
        if args.json:
            print(json.dumps({"mints": report}, indent=2, sort_keys=True))
        else:
            _print_survey(report)
        if verb == "status":
            return 0
        if not report:
            print(f"no certificate bundles under {root}", file=sys.stderr)
            return 1
        # Two independent conditions, reported separately so the remediation the
        # gate prints is one that actually clears it. Unrecorded drift is the
        # ledger's own contract and `record` fixes it; an incomplete mint is the
        # certify pipeline's business and only a re-splice fixes it, so it fails
        # the run only when the caller says it expects a complete mint.
        drifted = [r for r in report if not r["recorded"]]
        gaps = [r for r in report if r["absent_layers"]]
        if drifted:
            print(
                f"FAIL: {len(drifted)} certificate(s) on disk are not the ones the ledger "
                "describes. Run `ledger.py record` after a deliberate re-mint.",
                file=sys.stderr,
            )
        if gaps and args.require_layers:
            missing = ", ".join(sorted({n for r in gaps for n in _names(r["absent_layers"])}))
            print(
                f"FAIL: incomplete mint — layer(s) never spliced: {missing}. Re-run the "
                "owning layer (each layer's rerun command is in its bench/<layer>/README.md); "
                "`record` cannot clear this.",
                file=sys.stderr,
            )
        if drifted or (gaps and args.require_layers):
            return 1
        note = f" ({len(gaps)} layer-incomplete)" if gaps else ""
        print(f"OK: {len(report)} certificate(s) recorded{note}.")
        return 0

    if verb == "list":
        mints = load()[-args.limit :]
        if args.json:
            print(json.dumps([asdict(m) for m in reversed(mints)], indent=2))
            return 0
        for m in reversed(mints):
            numbers = "  ".join(
                f"{h.column} {_cell(m.headline(h.key), h.unit)}" for h in CHARTER.headlines
            )
            print(
                f"  {m.recorded}  {m.platform:<8} {m.short}  "
                f"{m.corpus_files} files  {numbers}  "
                f"absent: {' '.join(m.absent) or 'none'}"
            )
        return 0

    if verb == "show":
        mints = load()
        match = (
            mints[-1]
            if args.digest == "latest" and mints
            else next((m for m in mints if m.digest.startswith(args.digest)), None)
        )
        if match is None:
            print(f"no recorded mint matching {args.digest!r}", file=sys.stderr)
            return 1
        print(json.dumps(asdict(match), indent=2))
        return 0

    if verb == "backfill":
        return backfill(root, args.limit)

    render()
    print(f"rendered {RENDER.relative_to(KERNEL)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
