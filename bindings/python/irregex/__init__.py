r"""irregex — the importable face of Billy's search and kinship kernel (ADR-352/367).

Three engines, one import. Nothing here reimplements a matcher: every call drives
the same certified binaries the CLI drives, so a Python answer and a shell answer
are the same answer.

    import irregex

    # exact — where is this pattern?
    for m in irregex.search(r"func\s+\w+\(", paths=["services/backend"]):
        print(f"{m.path}:{m.line_number}: {m.text}")

    # compression — what is this like, and what would explain it?
    for kin in irregex.similar("services/backend/api/main.go", min_grade="strong"):
        print(kin.path, kin.grade)
    reading_set = irregex.pack("how does wallet crediting settle").paths

    # composed — both engines on one question
    radius = irregex.blast("WalletService")
    print(radius.paths)          # every file the change reaches

**This is not the CLI with a Python skin.** A terminal reads top-to-bottom and
throws structure away; a program wants the opposite. So:

* **Calibration is a value, not stderr prose.** `similar` returning 0.78 looks
  like a result but sits past where kinship means "both files are Zig". Every
  kinship row carries a `Grade`, and `min_grade=` filters on it — the CLI's
  stderr verdict, promoted to something a caller can branch on.
* **Provenance rides the result.** A `Kin` knows how many candidates it was drawn
  from, whether the answer came warm or live, and how long it took. "Nearest of
  three" and "nearest of twenty thousand" are different claims.
* **Complete by default.** The CLI truncates to a context budget; binding methods
  lift it, because a silently-trimmed list is a wrong list.
* **Answers, not sections.** `blast` prints six panes for a human to skim; here it
  is one object whose `paths` is the edit set, `exact_paths` the provable subset.
  `family` interleaves two row classes on one stream; here they are two fields.
* **The warm tier is inspectable.** `atlas_status()` lets a long-running process
  decide once whether to build, instead of paying a cold walk per call.

Faces: `search`/`files`/`count`/`rank`/`summary` (exact) · `similar`/`dups`/
`clusters`/`echoes`/`concepts`/`fragments`/`patterns` (kinship) ·
`recall`/`pack`/`quote` (retrieval) · `blast`/`context`/`family`/`provenance`
(composed). Row types too generic to stand alone — a blast's `Reference`, `Twin`,
`Ripple` — live on their module (`irregex.compose.Reference`).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import (
    aggregate,
    compose,
    corpus,
    engine,
    grade,
    introspection,
    kinship,
    radius,
    retrieval,
    sweep,
)
from .aggregate import Group, Tally, tally
from .compose import Attribution, Distinct, Family, FamilyReport, context, family, provenance
from .contract import ABI_VERSION, ENGINE_VERSION
from .corpus import Kin, Region
from .cursor import CancelToken, Cursor, Engine
from .errors import (
    GistError,
    GistNotFoundError,
    SearchFailedError,
    UnsupportedPatternError,
)
from .grade import Channel, Grade, grade_of
from .introspection import (
    Artifact,
    AtlasStatus,
    Capabilities,
    FlagCapability,
    IndexState,
    IndexStatus,
    atlas_index,
    atlas_status,
    capabilities,
    index,
    status,
)
from .kinship import (
    Cluster,
    Concept,
    DupPair,
    Echo,
    Similar,
    clusters,
    concepts,
    dups,
    echoes,
    fragments,
    similar,
)
from .radius import Blast, blast
from .request import (
    Match,
    MatchKind,
    Ranked,
    RankKind,
    SearchEngine,
    SearchRequest,
    Submatch,
)
from .retrieval import Packed, Phrase, Pick, Quotation, Recalled, pack, quote, recall
from .session import (
    Session,
    SessionGeneration,
    ensure_serve,
    ffi_eligible,
    opening_session,
    warm_eligible,
)
from .sweep import PatternCount, PatternHit, pattern_counts, patterns

schema = capabilities


if TYPE_CHECKING:
    from collections.abc import Mapping
    import os


__all__ = [
    "ABI_VERSION",
    "Artifact",
    "AtlasStatus",
    "Attribution",
    "Blast",
    "CancelToken",
    "Capabilities",
    "Channel",
    "Cluster",
    "Concept",
    "Cursor",
    "Distinct",
    "DupPair",
    "ENGINE_VERSION",
    "Echo",
    "Engine",
    "Family",
    "FamilyReport",
    "FlagCapability",
    "GistError",
    "GistNotFoundError",
    "Grade",
    "Group",
    "IndexState",
    "IndexStatus",
    "Kin",
    "Match",
    "MatchKind",
    "Packed",
    "PatternCount",
    "PatternHit",
    "Phrase",
    "Pick",
    "Quotation",
    "RankKind",
    "Ranked",
    "Recalled",
    "Region",
    "SearchEngine",
    "SearchFailedError",
    "SearchRequest",
    "Session",
    "SessionGeneration",
    "Similar",
    "Submatch",
    "Tally",
    "UnsupportedPatternError",
    "aggregate",
    "atlas_index",
    "atlas_status",
    "binary",
    "blast",
    "capabilities",
    "clusters",
    "compose",
    "concepts",
    "context",
    "corpus",
    "count",
    "count_matches",
    "dups",
    "echoes",
    "engine",
    "ensure_serve",
    "family",
    "ffi_eligible",
    "files",
    "fragments",
    "grade",
    "grade_of",
    "index",
    "introspection",
    "kinship",
    "opening_session",
    "pack",
    "pattern_counts",
    "patterns",
    "provenance",
    "quote",
    "radius",
    "rank",
    "recall",
    "request_from_tool",
    "retrieval",
    "run",
    "schema",
    "search",
    "similar",
    "status",
    "summary",
    "sweep",
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
