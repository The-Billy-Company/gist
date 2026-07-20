r"""irregex — the importable face of Billy's search and kinship kernel (ADR-352). One script-friendly API drives the certified `gist` and `relate` engines without reimplementing either. import irregex for m in irregex.search(r"func\\s+\\w+\\(", paths=["services/backend"]): print(f"{m.path}:{m.line_number}: {m.text}") hits = irregex.files("TODO", types=["py"]) total = irregex.count("panic", paths=["services"]) neighbors = irregex.similar("services/backend/api/main.go") Every search convenience accepts the same options as `SearchRequest`; build one explicitly for reuse through `irregex.run` or `request_from_tool`. `summary` aggregates matches, `rank` provides Gist's definition-first view, and `similar` / `dups` / `patterns` expose Relate's native corpus operations."""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import aggregate, engine, kinship
from .aggregate import Group, Tally, tally
from .contract import ABI_VERSION, ENGINE_VERSION
from .errors import (
    GistError,
    GistNotFoundError,
    SearchFailedError,
    UnsupportedPatternError,
)
from .introspection import (
    Capabilities,
    FlagCapability,
    IndexState,
    IndexStatus,
    capabilities,
    index,
    status,
)
from .request import (
    Match,
    MatchKind,
    Ranked,
    RankKind,
    SearchEngine,
    SearchRequest,
    Submatch,
)
from .kinship import (
    DupPair,
    PatternCount,
    PatternHit,
    Similar,
    dups,
    pattern_counts,
    patterns,
    similar,
)
from .session import (
    Session,
    SessionGeneration,
    ensure_serve,
    ffi_eligible,
    opening_session,
    warm_eligible,
)


schema = capabilities


if TYPE_CHECKING:
    from collections.abc import Mapping
    import os


__all__ = [
    "ABI_VERSION",
    "ENGINE_VERSION",
    "DupPair",
    "GistError",
    "GistNotFoundError",
    "Group",
    "Capabilities",
    "FlagCapability",
    "IndexState",
    "IndexStatus",
    "Match",
    "MatchKind",
    "PatternCount",
    "PatternHit",
    "RankKind",
    "Ranked",
    "Similar",
    "SearchFailedError",
    "SearchEngine",
    "SearchRequest",
    "Session",
    "SessionGeneration",
    "Submatch",
    "Tally",
    "UnsupportedPatternError",
    "aggregate",
    "binary",
    "capabilities",
    "count",
    "count_matches",
    "dups",
    "ensure_serve",
    "ffi_eligible",
    "files",
    "index",
    "kinship",
    "opening_session",
    "pattern_counts",
    "patterns",
    "rank",
    "similar",
    "request_from_tool",
    "run",
    "search",
    "schema",
    "status",
    "summary",
    "tally",
    "version",
    "warm_eligible",
]


def search(
    pattern: str,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> list[Match]:
    """Find `pattern`, returning structured `Match` records. Keyword options are `SearchRequest` fields (`paths`, `fixed`, `ignore_case`, `globs`, …)."""
    return engine.run(SearchRequest(pattern=pattern, **options), cwd=cwd, timeout=timeout)


def files(
    pattern: str,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> list[str]:
    """Sorted paths of files containing a match (the `-l` shape)."""
    return engine.files(SearchRequest(pattern=pattern, **options), cwd=cwd, timeout=timeout)


def count(
    pattern: str,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> int:
    """Total matching lines across the searched tree."""
    return engine.count(SearchRequest(pattern=pattern, **options), cwd=cwd, timeout=timeout)


def count_matches(
    pattern: str,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> int:
    """Total match occurrences across the searched tree."""
    return engine.count_matches(SearchRequest(pattern=pattern, **options), cwd=cwd, timeout=timeout)


def run(
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
) -> list[Match]:
    """Execute a prebuilt `SearchRequest`, returning structured matches."""
    return engine.run(request, cwd=cwd, timeout=timeout)


def summary(
    pattern: str,
    *,
    by: str | aggregate.GroupKey = "file",
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> Tally:
    """Search for `pattern`, then aggregate the matches along `by` — a named axis (`"file"` · `"dir"` · `"ext"` · `"match"`) or a `Callable[[Match], str]` — into buckets ranked by descending count. Keyword options are the same `SearchRequest` fields `search` accepts (`paths`, `types`, `ignore_case`, …)."""
    matches = engine.run(SearchRequest(pattern=pattern, **options), cwd=cwd, timeout=timeout)
    return tally(matches, by=by)


def rank(
    pattern: str,
    *,
    limit: int = 20,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> list[Ranked]:
    """The engine's definition-first ranked view: the top-`limit` files for `pattern`, each tagged `def`/`use`/`gen` by the engine itself — a symbol's definition ahead of its call sites, generated files demoted. Uses the persisted index when available and live-ranks otherwise."""
    return engine.rank(
        SearchRequest(pattern=pattern, **options), limit=limit, cwd=cwd, timeout=timeout
    )


def request_from_tool(payload: Mapping[str, object]) -> SearchRequest:
    """Map an agent tool payload (a dict) into a `SearchRequest`. Lazy import keeps `irregex.agent` off the hot path for plain script callers."""
    from .agent import request_from_tool as _rft

    return _rft(payload)


def version() -> str:
    """The driven binary's semver."""
    return engine.version()


def binary() -> str:
    """Absolute path to the resolved `gist` binary."""
    return engine.binary()
