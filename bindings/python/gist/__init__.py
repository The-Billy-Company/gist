"""gist — the importable face of the search product.

Exact search over a tree. Kinship lives in `relate`; composed verbs live in
`blast`. This package exposes search and its index lifecycle only.

    import gist

    for m in gist.search(r"func\\s+\\w+\\(", paths=["src/server/api"]):
        print(f"{m.path}:{m.line_number}: {m.text}")
"""

from __future__ import annotations

from typing import TYPE_CHECKING

# Pinning the engine copy has to precede every `irgx` import, because
# importing `irgx` maps one eagerly. See `_substrate`.
# isort: off
from . import _substrate as _pin_the_engine  # noqa: F401
from irgx.contract import ABI_VERSION, ENGINE_VERSION
from irgx.request import (
    Match,
    MatchKind,
    Ranked,
    RankKind,
    SearchEngine,
    SearchRequest,
    Submatch,
)
from irgx.runtime import shell as engine
from irgx.runtime.errors import (
    BadPatternError,
    GistError,
    GistNotFoundError,
    RowDecodeError,
    SchemaDriftError,
    SearchFailedError,
    UnsupportedPatternError,
)

from ._daemon import (
    Session,
    SessionGeneration,
    ensure_serve,
    ffi_eligible,
    opening_session,
    warm_eligible,
)
from .exact import aggregate, ranked
from .exact.aggregate import Group, Tally, tally
from .exact.cursor import CancelToken, Cursor, Engine
from .index import lifecycle as introspection
from .index.lifecycle import (
    Capabilities,
    FlagCapability,
    IndexState,
    IndexStatus,
    capabilities,
    index,
    status,
)

# isort: on

schema = capabilities


if TYPE_CHECKING:
    import os
    from collections.abc import Mapping


__all__ = [
    "ABI_VERSION",
    "ENGINE_VERSION",
    "BadPatternError",
    "CancelToken",
    "Capabilities",
    "Cursor",
    "Engine",
    "FlagCapability",
    "GistError",
    "GistNotFoundError",
    "Group",
    "IndexState",
    "IndexStatus",
    "Match",
    "MatchKind",
    "RankKind",
    "Ranked",
    "RowDecodeError",
    "SchemaDriftError",
    "SearchEngine",
    "SearchFailedError",
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
    "engine",
    "ensure_serve",
    "ffi_eligible",
    "files",
    "index",
    "introspection",
    "opening_session",
    "rank",
    "request_from_tool",
    "run",
    "schema",
    "search",
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
    """Search for `pattern`, then aggregate the matches along `by`."""
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
    """The engine's definition-first ranked view for `pattern`."""
    return ranked.rank(
        SearchRequest(pattern=pattern, **options), limit=limit, cwd=cwd, timeout=timeout
    )


def request_from_tool(payload: Mapping[str, object]) -> SearchRequest:
    """Map an agent tool payload into a `SearchRequest`."""
    from .agent import request_from_tool as _rft

    return _rft(payload)


def version() -> str:
    """The driven binary's semver."""
    return engine.version()


def binary() -> str:
    """Absolute path to the resolved `gist` binary."""
    return engine.binary()
