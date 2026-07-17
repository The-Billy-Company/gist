r"""gist — the importable face of Billy's code-search kernel (ADR-352). One clean, script-friendly search API over the certified `gist` engine, sharing the exact `SearchRequest` shape the CLI and Billy's agent tool speak. Results are produced by the same rg-parity engine the CLI uses — this package drives it, it does not reimplement it. import gist for m in gist.search(r"func\\s+\\w+\\(", paths=["services/backend"]): print(f"{m.path}:{m.line_number}: {m.text}") hits   = gist.files("TODO", types=["py"])       # files-with-matches total  = gist.count("panic", paths=["services"]) # total matching lines report = gist.status()                            # index freshness report Beyond *where* a pattern occurs, `summary` answers *how it is distributed* — search then aggregate in one call — and `rank` answers *which hit matters most*, gist's definition-first view (a symbol's declaration ahead of its call sites, codegen demoted), with no rg equivalent: hot = gist.summary("TODO", paths=["services"], by="dir")   # ranked buckets for g in hot.top(5): print(f"{g.count:4}  {g.key}") for r in gist.rank("SearchRequest", limit=5):              # def-first, engine-classified print(f"[{r.kind}] {r.path}:{r.line_number}")          # skip r.generated for codegen Every convenience wrapper accepts the same keyword options as `SearchRequest`; pass a `SearchRequest` to `gist.run` when you want to build it once and reuse it (e.g. across faces, or through the agent adapter `request_from_tool`)."""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import aggregate, engine
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
from .session import (
    Session,
    SessionGeneration,
    ensure_serve,
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
    "GistError",
    "GistNotFoundError",
    "Group",
    "Capabilities",
    "FlagCapability",
    "IndexState",
    "IndexStatus",
    "Match",
    "MatchKind",
    "RankKind",
    "Ranked",
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
    "ensure_serve",
    "files",
    "index",
    "opening_session",
    "rank",
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
    return engine.rank(SearchRequest(pattern=pattern, **options), limit=limit, cwd=cwd, timeout=timeout)


def request_from_tool(payload: Mapping[str, object]) -> SearchRequest:
    """Map an agent tool payload (a dict) into a `SearchRequest`. Lazy import keeps `gist.agent` off the hot path for plain script callers."""
    from .agent import request_from_tool as _rft

    return _rft(payload)


def version() -> str:
    """The driven binary's semver."""
    return engine.version()


def binary() -> str:
    """Absolute path to the resolved `gist` binary."""
    return engine.binary()
