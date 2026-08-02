"""Runtime mirror of `contract/surface.toml` — this product's own contract.

The package embeds these constants so it has no runtime dependency on a repo
file (a wheel ships without one); `tests/test_contract_surface.py` reads the
canonical TOML and asserts this mirror matches it. That is the standard
mirror-plus-parity-test shape, and the reason it lives *here* rather than in the
substrate: a mirror can only be gated where the canonical file is, so mirroring
gist's contract inside `irgx` made the engine's own test suite unrunnable
without a gist checkout beside it.

The substrate keeps mirroring what the substrate authors — the request options,
the ABI and engine versions, the analytic verb table, the grade vocabulary its
row decoder needs — and this names only what `surface.toml` declares about the
search product: how it is distributed, and the seam an agent calls it across.
"""

from __future__ import annotations

import os
from pathlib import Path

# Mirrors `[package]` in contract/surface.toml. The distribution and the import
# name differ on purpose: `gist` was taken on PyPI, so the wheel is published as
# `gist-search` while the module a caller imports stayed `gist`.
PACKAGE_DIST = "gist-search"
PACKAGE_IMPORT = "gist"

# Mirrors `[tool_boundary]` in contract/surface.toml — the agent / code-place
# seam. `ALIASES` rename a tool-boundary param onto its canonical request
# option; `ROUTING_KEYS` are recognized-but-ignored, because place and transport
# routing stay outside this tool.
ALIASES: dict[str, str] = {
    "query": "pattern",
    "glob": "globs",
    "context_lines": "context",
}
ROUTING_KEYS: frozenset[str] = frozenset({"place", "at", "semantic"})


def contract_path(name: str = "surface") -> Path:
    """Path to this product's canonical contract TOML; may not exist in an installed wheel.

    `GIST_<NAME>_CONTRACT` overrides. Otherwise the file is looked for at every
    ancestor rather than at a counted depth, so a source checkout, a monorepo
    vendoring, and an editable install all resolve. Failing all of them the path
    this layout would have used is returned anyway, so a caller reporting the
    miss names somewhere real.
    """
    if override := os.environ.get(f"GIST_{name.upper()}_CONTRACT"):
        return Path(override)
    here = Path(__file__).resolve()
    relative = f"contract/{name}.toml"
    for parent in here.parents:
        if (candidate := parent / relative).is_file():
            return candidate
    return here.parents[3] / relative
