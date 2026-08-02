#!/usr/bin/env python3
"""The certificate's layer roster — one row per layer, read by every gate.

A layer's identity used to be written three times: the header substring
``ledger.py`` counts as proof the layer was minted, the header *and* side-car
``check_artifacts.py`` demands, and the completeness list at the tail of
``certify_layers.sh``. Three copies of one fact is three chances to add a layer
and have a gate quietly not know about it — the same class of silent drop the
ledger exists to catch, one level up.

This module is the single roster. Adding a layer is **one ``Layer`` row**; the
ledger, the reproducibility gate, and the shell completeness check all widen
from it. A row is only added once that layer actually mints — a header no
certificate carries would fail the very gate it was meant to describe.

Shell reads it through the tiny CLI at the bottom::

    python3 layers.py headers    # the exact `## …` headers the strict gate wants
    python3 layers.py sidecars   # the side-car filenames that prove a mint
"""

from __future__ import annotations

import sys
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Layer:
    """One certificate layer, as the gates recognize it.

    ``probe`` is the loose substring the ledger scans headers for — deliberately
    shorter than ``header`` so a mint still counts when a section's parenthetical
    is reworded. ``header`` is the exact prefix the reproducibility gate demands,
    and ``None`` means the layer is rostered for the ledger but outside that
    stricter contract (the Layer A lanes and B′ ride their parent's side-cars).
    ``sidecar`` is the artifact filename that proves the layer was measured
    rather than merely named.
    """

    key: str
    probe: str
    header: str | None = None
    sidecar: str | None = None


#: Every layer a complete mint carries, in certificate order.
ROSTER: tuple[Layer, ...] = (
    Layer("A-micro", "Layer A — empirical, microscopic"),
    Layer("A-macro", "Layer A — macroscopic dominance"),
    Layer("A-warm", "Layer A — warm tier"),
    Layer(
        "A-rank",
        "Layer A — the `--rank` lane",
        "## Layer A — the `--rank` lane",
        "certify_rank.csv",
    ),
    Layer("B", "Layer B — port-optimality", "## Layer B — port-optimality", "portcert.json"),
    Layer("B'", "Layer B′ — port bound, measured"),
    Layer("C", "Layer C — roofline", "## Layer C — roofline (measured headroom)", "roofline.json"),
    Layer(
        "D",
        "Layer D — algorithmic lower bound",
        "## Layer D — algorithmic lower bound",
        "lowerbound.csv",
    ),
    Layer(
        "E",
        "Layer E — crest sieve",
        "## Layer E — crest sieve (the trigram blind spot, measured)",
        "crest.csv",
    ),
    Layer("F", "Layer F — codex self-index", "## Layer F — codex self-index", "codex.csv"),
    Layer("G", "Layer G — relate", "## Layer G — relate", "relate.csv"),
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
    Layer(
        "J",
        "Layer J — positional + substring index tiers",
        "## Layer J — positional + substring index tiers at scale (vs zoekt)",
        "scale.csv",
    ),
    Layer(
        "K",
        "Layer K — multi-pattern",
        "## Layer K — multi-pattern simultaneous matching (vs Hyperscan/Vectorscan)",
        "multipattern.csv",
    ),
    Layer(
        "L",
        "Layer L — index quality",
        "## Layer L — index quality head-to-head (vs csearch)",
        "indexq.csv",
    ),
)

#: Ledger view: key → the header substring that proves the layer was spliced.
LAYERS: dict[str, str] = {layer.key: layer.probe for layer in ROSTER}

#: Reproducibility-gate view: the exact headers a complete bundle must carry.
REQUIRED_LAYER_HEADERS: tuple[str, ...] = tuple(x.header for x in ROSTER if x.header)

#: Reproducibility-gate view: side-cars that prove a layer was measured.
REQUIRED_LAYER_FILES: tuple[str, ...] = tuple(x.sidecar for x in ROSTER if x.sidecar)

_VIEWS = {
    "headers": REQUIRED_LAYER_HEADERS,
    "sidecars": REQUIRED_LAYER_FILES,
    "probes": tuple(LAYERS.values()),
    "keys": tuple(LAYERS),
}


def main(argv: list[str]) -> int:
    """Print one roster view, newline-separated, for the shell gates."""
    view = argv[1] if len(argv) > 1 else "headers"
    if view not in _VIEWS:
        print(f"layers: unknown view {view!r} — pick one of {', '.join(_VIEWS)}", file=sys.stderr)
        return 2
    print("\n".join(_VIEWS[view]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
