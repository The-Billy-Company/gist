#!/usr/bin/env python3
"""What a certificate IS — the vocabulary every package's gates are written in.

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

Four packages publish four different certificates. `irregex` certifies an engine
against its own physical limits; `gist` certifies a product against ripgrep;
`relate` certifies retrieval and multi-pattern attribution against Hyperscan.
None of them measures the same thing, and pretending otherwise is how a shared
gate ends up with `if package == "gist"` in it.

So the split is not between packages, it is between **method and claim**. This
module and its siblings in `guard/` hold the method: what makes a bundle
reproducible, what a mint must record before it may be published, what drift in
a ledger looks like. The claim — which layers exist, which tools must be pinned,
which sidecar proves what, what the headline number is called — is one
`guard/profile.py` per package, which is deliberately NOT vendored.

A gate therefore never asks what package it is in. It asks its `CHARTER`, and
the answer is data. Adding a layer is one `Layer` row in one package's profile;
the reproducibility gate, the ledger, and the shell completeness check all widen
from it, in that package only.

The dataclasses are frozen and slotted because a charter is read by every gate in
a mint and written by none of them.
"""

from __future__ import annotations

import csv
import json
import math
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol


def geomean(values: list[float]) -> float | None:
    """Geometric mean of the positive values, or None when there are none.

    The right average for ratios: a 4× win and a 0.25× loss are each other's
    inverse and must cancel to 1.0, which the arithmetic mean reports as 2.1×.

    """
    usable = [v for v in values if v > 0]
    return math.exp(sum(map(math.log, usable)) / len(usable)) if usable else None


def read_json(path: Path, problems: list[str]) -> object | None:
    """Parse a bundle's JSON sidecar, recording a malformed file as a finding.

    An absent file returns ``None`` silently: presence is the required-files
    gate's job, and reporting it twice buries the one message that matters.

    """
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        problems.append(f"{path.name} is not valid JSON: {error}")
        return None


def read_tsv(path: Path, problems: list[str]) -> tuple[list[str], list[dict[str, str]]]:
    """Parse a bundle's TSV sidecar into (fieldnames, rows).

    ``surrogateescape`` because a corpus manifest indexes real filenames, and a
    tree containing one undecodable byte must still be auditable.

    """
    if not path.is_file():
        return [], []
    try:
        with path.open(newline="", errors="surrogateescape") as source:
            reader = csv.DictReader(source, delimiter="\t")
            return reader.fieldnames or [], list(reader)
    except (OSError, csv.Error) as error:
        problems.append(f"{path.name} is not valid TSV: {error}")
        return [], []


@dataclass(frozen=True, slots=True)
class Layer:
    """One certificate layer, as the gates recognize it.

    ``probe`` is the loose substring the ledger scans headers for — deliberately
    shorter than ``header`` so a mint still counts when a section's parenthetical
    is reworded. ``header`` is the exact prefix the reproducibility gate demands,
    and ``None`` means the layer is rostered for the ledger but outside that
    stricter contract (lanes that ride a parent layer's sidecar). ``sidecar`` is
    the artifact filename that proves the layer was measured rather than merely
    named.

    """

    key: str
    probe: str
    header: str | None = None
    sidecar: str | None = None


@dataclass(frozen=True, slots=True)
class Headline:
    """One number the ledger watches across mints.

    A certificate is rewritten in place on every mint, so its history is only
    whatever the ledger recorded before the bytes changed. A mint where the
    number is unobtainable records ``None``, which reads as "this mint did not
    make that claim" — never as zero, because zero is a regression and silence
    is not.

    ``column`` is what a human sees in LEDGER.md; ``key`` is the stable field
    name in ledger.jsonl and must never be renamed once rows exist. ``rising``
    says which direction is good, so drift can be reported as improvement or
    regression rather than as a bare delta.

    """

    key: str
    column: str
    unit: str = "×"
    rising: bool = True


class Auditor(Protocol):
    """A package's own deep checks over a bundle, beyond the generic contract.

    The generic gate proves a bundle is *well-formed and complete*: the required
    files exist, the machine metadata is there, the tools are pinned to exact
    identities, the corpus manifest agrees with itself, and every rostered layer
    shipped its header and its sidecar. What it cannot know is whether the
    numbers are *coherent* — that gist's macro cell matrix is exactly classes ×
    timed tools, that irregex's Layer C verdict agrees with the measured fraction
    of the memory roof it reports. Those are claims about a specific layer's
    physics, so they live with the package that makes them.

    Append to ``problems``; return nothing. Raising is a bug — a malformed bundle
    is a finding, not an exception.

    """

    def __call__(
        self,
        bundle: Path,
        meta: dict[str, object],
        tools: set[str],
        problems: list[str],
    ) -> None:
        """Record every incoherence found in ``bundle`` onto ``problems``."""


def _no_audit(bundle: Path, meta: dict[str, object], tools: set[str], problems: list[str]) -> None:
    """The default auditor: a package with no layer-specific physics to check."""


def _no_headlines(bundle: Path, text: str) -> dict[str, float | None]:
    """The default measurer: a package whose ledger tracks only which layers shipped."""
    return {}


@dataclass(frozen=True, slots=True)
class Charter:
    """Everything a gate needs to know about what THIS package certifies.

    One instance per package, in ``guard/profile.py``. The gates import it and
    ask; nothing else distinguishes one package's certificate machinery from
    another's.

    """

    #: Package name, used in messages so a failure says which certificate broke.
    package: str
    #: Where a mint WRITES, relative to the package root — scratch, gitignored,
    #: and overwritten by the next run. Not what a bare gate reads: see
    #: ``published_dir``.
    artifact_dir: str
    #: Layers in certificate order.
    roster: tuple[Layer, ...]
    #: Base artifacts every bundle carries, regardless of layer.
    required_files: tuple[str, ...]
    #: Keys ``machine.json`` must record for the run to be reproducible.
    required_machine_keys: tuple[str, ...]
    #: Tools whose exact identity must appear in ``tool-versions.txt``.
    required_tools: tuple[str, ...]
    #: Tools that build or drive the measurement but are never themselves timed.
    support_tools: frozenset[str]
    #: Tools that appear as a timed column somewhere in the bundle.
    bench_tools: frozenset[str]
    #: Where a published bundle LIVES — the committed receipts, and therefore
    #: what a bare ``artifacts.py`` judges. Separate from ``artifact_dir``
    #: because they were one field until a gate run with no arguments reported
    #: on a gitignored scratch directory: it answered about bytes no reader
    #: could fetch, which is the exact failure that let this repository's claims
    #: outlive its evidence.
    published_dir: str = "bench/certificate/artifact"
    #: Numbers the ledger tracks across mints, in display order.
    headlines: tuple[Headline, ...] = ()
    #: Prose a certificate may never carry — retired claims that outlived their
    #: evidence. Each is checked as a literal substring of CERTIFICATE.md.
    forbidden_claims: tuple[str, ...] = ()
    #: The package's own coherence checks. See ``Auditor``.
    audit: Auditor = field(default=_no_audit)
    #: Read this mint's headline numbers from its bundle and rendered prose.
    #: Keyed by ``Headline.key``; a key the package could not measure is absent
    #: or ``None``. Separate from ``headlines`` because *what* is tracked is a
    #: stable contract while *how* it is obtained differs per number — some are
    #: scraped from the prose, some computed over a sidecar.
    measure: Callable[[Path, str], dict[str, float | None]] = field(default=_no_headlines)

    @property
    def layer_headers(self) -> tuple[str, ...]:
        """The exact ``## …`` headers a complete bundle must carry."""
        return tuple(x.header for x in self.roster if x.header)

    @property
    def layer_sidecars(self) -> tuple[str, ...]:
        """Sidecar filenames that prove a layer was measured, not merely named."""
        return tuple(x.sidecar for x in self.roster if x.sidecar)

    @property
    def probes(self) -> dict[str, str]:
        """Ledger view: layer key → the header substring that proves it spliced."""
        return {x.key: x.probe for x in self.roster}

    def views(self) -> dict[str, tuple[str, ...]]:
        """The roster as the shell gates consume it, one newline-separated list each."""
        return {
            "headers": self.layer_headers,
            "sidecars": self.layer_sidecars,
            "probes": tuple(self.probes.values()),
            "keys": tuple(self.probes),
            "files": self.required_files,
        }


def main(charter: Charter, argv: list[str]) -> int:
    """Shared CLI body — each package's ``profile.py`` calls this with its charter.

    Shell reads the roster through it rather than re-deriving the layer list::

        python3 guard/profile.py headers    # exact `## …` headers the gate wants
        python3 guard/profile.py sidecars   # filenames that prove a mint

    """
    import sys

    views = charter.views()
    view = argv[1] if len(argv) > 1 else "headers"
    if view not in views:
        print(
            f"{charter.package} profile: unknown view {view!r} — "
            f"pick one of {', '.join(views)}",
            file=sys.stderr,
        )
        return 2
    print("\n".join(views[view]))
    return 0
