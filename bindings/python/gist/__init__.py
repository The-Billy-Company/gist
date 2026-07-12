"""gist — the importable face of Billy's code-search kernel (ADR-352).

One clean, script-friendly search API over the certified `gist` engine, sharing
the exact `SearchRequest` shape the CLI and Billy's agent tool speak. Results are
produced by the same rg-parity engine the CLI uses — this package drives it, it
does not reimplement it.

    import gist

    for m in gist.search(r"func\\s+\\w+\\(", paths=["services/backend"]):
        print(f"{m.path}:{m.line_number}: {m.text}")

    hits   = gist.files("TODO", types=["py"])       # files-with-matches
    total  = gist.count("panic", paths=["services"]) # total matching lines
    report = gist.status()                            # index freshness report

Every convenience wrapper accepts the same keyword options as `SearchRequest`;
pass a `SearchRequest` to `gist.run` when you want to build it once and reuse it
(e.g. across faces, or through the agent adapter `request_from_tool`).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import engine
from .contract import ABI_VERSION, ENGINE_VERSION
from .errors import (
    GistError,
    GistNotFoundError,
    SearchFailedError,
    UnsupportedPatternError,
)
from .request import Match, MatchKind, SearchRequest, Submatch


if TYPE_CHECKING:
    import os


__all__ = [
    "ABI_VERSION",
    "ENGINE_VERSION",
    "GistError",
    "GistNotFoundError",
    "Match",
    "MatchKind",
    "SearchFailedError",
    "SearchRequest",
    "Submatch",
    "UnsupportedPatternError",
    "binary",
    "count",
    "files",
    "request_from_tool",
    "run",
    "search",
    "status",
    "version",
]


def search(
    pattern: str,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
    **options: object,
) -> list[Match]:
    """Find `pattern`, returning structured `Match` records. Keyword options are
    `SearchRequest` fields (`paths`, `fixed`, `ignore_case`, `globs`, …)."""
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


def request_from_tool(payload: object) -> SearchRequest:
    """Map an agent tool payload (a dict) into a `SearchRequest`. Lazy import
    keeps `gist.agent` off the hot path for plain script callers."""
    from .agent import request_from_tool as _rft

    return _rft(payload)  # type: ignore[arg-type]


def status(*, cwd: str | os.PathLike[str] | None = None) -> str:
    """The persisted-index freshness report (`gist status`)."""
    return engine.status(cwd=cwd)


def version() -> str:
    """The driven binary's semver."""
    return engine.version()


def binary() -> str:
    """Absolute path to the resolved `gist` binary."""
    return engine.binary()
