r"""Result-side aggregation over GIST matches (ADR-352). `search`/`files`/`count` answer *where* a pattern occurs; aggregation answers *how it is distributed* — the question an agent asks next: which files carry the most `TODO`s, which directories concentrate a `panic`, what distinct error codes match `apperr\\.\\w+`, which ADRs the tree cites most. It is a pure post-processing layer over the `Match` records the engine already returns: it never widens `SearchRequest` (the contract stays match-finding-only — presentation and stats are deliberately *not* request options) and never runs a second matcher. from gist import search, tally tally(search("TODO", paths=["services"]), by="dir").top(5) `by` selects the axis — a named one (`"file"` · `"dir"` · `"ext"` · `"match"`) or any `Callable[[Match], str]` for a custom bucketing. Only `MatchKind.MATCH` lines are counted; `-A/-B/-C` context lines are display neighborhood, not matches, so they never inflate a tally."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from posixpath import dirname, splitext
from typing import TYPE_CHECKING

from .request import Match, MatchKind


if TYPE_CHECKING:
    from collections.abc import Iterable, Iterator


# An axis is a function from a match to the bucket label it belongs in.
type GroupKey = Callable[[Match], str]


def by_path(m: Match) -> str:
    """Bucket by the file the match is in."""
    return m.path


def by_dir(m: Match) -> str:
    """Bucket by the match's parent directory (``""`` for a repo-root file)."""
    return dirname(m.path)


def by_extension(m: Match) -> str:
    """Bucket by file extension, dot included (``""`` when the file has none)."""
    return splitext(m.path)[1]


def by_match_text(m: Match) -> str:
    """Bucket by the literal text that matched — the first submatch span, else the stripped line (a match line always carries ≥1 submatch in `--json`). This is the axis for "what distinct tokens did this pattern hit"."""
    return m.submatches[0].text if m.submatches else m.text.strip()


_NAMED_AXES: dict[str, GroupKey] = {
    "file": by_path,
    "dir": by_dir,
    "ext": by_extension,
    "match": by_match_text,
}


def resolve_axis(by: str | GroupKey) -> GroupKey:
    """A named axis (`"file"`/`"dir"`/`"ext"`/`"match"`) or a custom callable. An unknown name is a loud `ValueError` — a typo can't silently pick the wrong grouping and misreport a distribution."""
    if callable(by):
        return by
    try:
        return _NAMED_AXES[by]
    except KeyError:
        options = ", ".join(sorted(_NAMED_AXES))
        msg = f"unknown group axis {by!r}; use one of {options} or a callable"
        raise ValueError(msg) from None


@dataclass(frozen=True, slots=True)
class Group:
    """One aggregation bucket: every match sharing a `key`."""

    key: str
    matches: tuple[Match, ...]

    @property
    def count(self) -> int:
        """Matching lines in this bucket."""
        return len(self.matches)

    @property
    def files(self) -> int:
        """Distinct files this bucket spans (1 for a file-axis bucket, ≥1 for a dir/ext/match axis)."""
        return len({m.path for m in self.matches})


@dataclass(frozen=True, slots=True)
class Tally:
    """Buckets ranked by descending match count (ties broken by key ascending) — the shape a report or an agent reads top-down."""

    groups: tuple[Group, ...]

    @property
    def total(self) -> int:
        """Total matching lines across every bucket."""
        return sum(g.count for g in self.groups)

    @property
    def files(self) -> int:
        """Distinct files across every bucket."""
        return len({m.path for g in self.groups for m in g.matches})

    def top(self, n: int) -> tuple[Group, ...]:
        """The `n` largest buckets (all of them when `n <= 0`)."""
        return self.groups if n <= 0 else self.groups[:n]

    def get(self, key: str) -> Group | None:
        """The bucket labelled `key`, or `None` if the pattern never hit it."""
        return next((g for g in self.groups if g.key == key), None)

    def __iter__(self) -> Iterator[Group]:
        """Iterate buckets in descending-count order."""
        return iter(self.groups)

    def __len__(self) -> int:
        """Number of non-empty buckets."""
        return len(self.groups)


def tally(matches: Iterable[Match], *, by: str | GroupKey = "file") -> Tally:
    """Bucket `matches` along `by` and rank the buckets by descending count. Pure and binary-free: it consumes `Match` records, so it composes with `gist.search(...)` or any other source of them and is unit-testable without the engine. Context lines (`MatchKind.CONTEXT`) are skipped, so a request with `-A/-B/-C` context still tallies only the true matches."""
    axis = resolve_axis(by)
    buckets: dict[str, list[Match]] = {}
    for m in matches:
        if m.kind is MatchKind.MATCH:
            buckets.setdefault(axis(m), []).append(m)
    ordered = sorted(buckets.items(), key=lambda kv: (-len(kv[1]), kv[0]))
    return Tally(tuple(Group(key, tuple(group)) for key, group in ordered))
