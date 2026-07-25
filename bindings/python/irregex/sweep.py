"""N patterns, one walk, exact per-pattern attribution.

The odd one out among the relate verbs: nothing here is compression. `patterns`
is an *exact* multi-pattern sweep that lives in the relate binary because it
shares the corpus walk — the loom runs every pattern against each file as it is
read once, instead of re-reading the tree per pattern.

That makes it the right tool for a question no single search answers: *"which of
these twenty things appear, and where?"* Sequential `gist -l` calls pay the walk
N times and then make the caller re-derive which pattern produced which hit;
this returns the attribution the engine already knew. Roughly 6× faster than the
sequential shape at N≈3, and the gap widens with N.

`pattern_counts` goes further and never ships rows at all — the grouping happens
engine-side, so a "how many of each?" question costs one number per group rather
than one line per hit.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING

from . import engine
from .corpus import Scope, run


if TYPE_CHECKING:
    from collections.abc import Sequence
    import os


@dataclass(frozen=True, slots=True)
class PatternHit:
    """One attributed match row: pattern `pattern_id` (source `pattern`) hit `path` at `line`."""

    path: str
    line: int
    pattern_id: int
    pattern: str

    def __str__(self) -> str:
        """`path:line`."""
        return f"{self.path}:{self.line}"


@dataclass(frozen=True, slots=True)
class PatternCount:
    """One engine-side group: `label` is a pattern source or a file path."""

    label: str
    count: int


@dataclass(frozen=True, slots=True)
class _Batch:
    """The argv shape `patterns` and `pattern_counts` share."""

    specs: Sequence[str]
    fixed: bool = False
    ignore_case: bool = False
    under: str | None = None
    top: int = 0
    extra: tuple[str, ...] = field(default_factory=tuple)

    def argv(self) -> list[str]:
        """Lower into relate argv, rejecting an empty pattern set loudly."""
        if not self.specs:
            msg = "patterns: at least one pattern is required"
            raise ValueError(msg)
        argv = [flag for s in self.specs for flag in ("-e", s)]
        if self.fixed:
            argv.append("-F")
        if self.ignore_case:
            argv.append("-i")
        if self.under is not None:
            argv += ["--under", self.under]
        if self.top:
            argv += ["--top", str(self.top)]
        return [*argv, *self.extra]


def patterns(
    specs: Sequence[str],
    *,
    fixed: bool = False,
    ignore_case: bool = False,
    under: str | None = None,
    top: int = 0,
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
) -> list[PatternHit]:
    """One walk, every pattern in `specs`, exact per-pattern attribution as `PatternHit` rows in total (path, line, pattern) order. This is the batched shape that replaces N sequential searches plus downstream re-classification."""
    argv = _Batch(specs, fixed, ignore_case, under, top).argv()
    rows, _ = run("relate", "patterns", argv, roots, cwd=cwd, timeout=timeout)
    return [
        PatternHit(
            path=engine.as_str(r, "path"),
            line=engine.as_int(r, "line"),
            pattern_id=engine.as_int(r, "pattern_id"),
            pattern=engine.as_str(r, "pattern"),
        )
        for r in rows
    ]


def pattern_counts(
    specs: Sequence[str],
    *,
    by: str = "pattern",
    fixed: bool = False,
    ignore_case: bool = False,
    under: str | None = None,
    top: int = 0,
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = engine.DEFAULT_TIMEOUT,
) -> list[PatternCount]:
    """Grouped counts (`by` = `"pattern"` or `"file"`), descending, computed engine-side by the loom — no rows cross the process boundary."""
    argv = _Batch(specs, fixed, ignore_case, under, top, ("--by", by)).argv()
    rows, _ = run("relate", "patterns", argv, roots, cwd=cwd, timeout=timeout)
    return [
        PatternCount(label=engine.as_str(r, "label"), count=engine.as_int(r, "count")) for r in rows
    ]
