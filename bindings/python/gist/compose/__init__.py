"""Both engines on one question (ADR-367).

Exact match narrows a candidate set; compression reasons *inside* it. Neither
half can answer these alone and the two scores never fuse into one number — a
coincidence must not be able to outrank a call site.

  * `provenance` — where a pasted snippet really came from, each phrase
    re-verified against the source file's current bytes.
  * `blast` — what moves if this symbol changes: definitions, dependents,
    dependencies, twins, ripple, and the comments that name it, computed from the
    tree's current bytes with no precomputed graph to go stale.
"""

from __future__ import annotations

from .radius import Blast, Dependency, Mention, Reference, Ripple, Site, blast
from .verbs import Attribution, provenance


__all__ = [
    "Attribution",
    "Blast",
    "Dependency",
    "Mention",
    "Reference",
    "Ripple",
    "Site",
    "blast",
    "provenance",
]
