"""The doc_radar canary (ADR-352, plan step 4/6).

Proves the unified search API is a byte-equivalent substitute for the `rg`
calls doc_radar makes today, and measures the warm (persisted-index) vs cold
vs ripgrep cost over doc_radar's *real* query corpus — the evidence that gates
graduating GIST into the live radar's content-search wrappers.
"""

from .doc_radar import (
    CanaryReport,
    QueryResult,
    collect_queries,
    run_canary,
)


__all__ = [
    "CanaryReport",
    "QueryResult",
    "collect_queries",
    "run_canary",
]
