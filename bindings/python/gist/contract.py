"""Runtime mirror of `contract/search_api.toml` (ADR-352). The package embeds the contract's load-bearing constants so it has no runtime dependency on the repo file (a wheel ships without it); the package's parity test reads the canonical TOML and asserts this mirror matches it — the standard mirror-plus-parity-test shape, so the two cannot silently drift."""

from __future__ import annotations

from pathlib import Path


# Mirrors `[meta]` in contract/search_api.toml.
ABI_VERSION = 2
ENGINE_VERSION = "0.1.0"
PACKAGE_DIST = "billy-gist"
PACKAGE_IMPORT = "gist"

# Mirrors `[request_options]` keys — the deep SearchRequest surface.
REQUEST_OPTIONS: frozenset[str] = frozenset(
    {
        "pattern",
        "paths",
        "fixed",
        "ignore_case",
        "smart_case",
        "word",
        "invert",
        "globs",
        "iglobs",
        "types",
        "not_types",
        "before",
        "after",
        "context",
        "max_count",
        "max_depth",
        "hidden",
        "no_ignore",
        "follow",
        "no_index",
        "engine",
        "multiline",
        "multiline_dotall",
        "unicode",
    }
)

# Mirrors `[match_kinds]` and `[exit_codes]`.
MATCH_KINDS: frozenset[str] = frozenset({"match", "context"})
EXIT_MATCHED = 0
EXIT_NO_MATCH = 1
EXIT_ERROR = 2

# Mirrors `[tool_boundary]` — the agent / code-place seam (ADR-352). `ALIASES`
# rename a tool-boundary param onto its canonical request option; `ROUTING_KEYS`
# are recognized-but-ignored (place/transport routing stays outside GIST).
ALIASES: dict[str, str] = {
    "query": "pattern",
    "glob": "globs",
    "context_lines": "context",
}
ROUTING_KEYS: frozenset[str] = frozenset({"place", "at", "semantic"})


def contract_path() -> Path:
    """Path to the canonical `search_api.toml` in the repo (for the parity test); may not exist in an installed wheel."""
    return Path(__file__).resolve().parents[3] / "contract" / "search_api.toml"
