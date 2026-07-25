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

from dataclasses import dataclass, field, replace
from typing import TYPE_CHECKING

from ..contract.table import verb_schema
from ..runtime import analytic, cold, shell
from ..runtime.decode import bind
from .corpus import Scope, scope_argv


if TYPE_CHECKING:
    from collections.abc import Sequence
    import os


@bind("pattern_hit", extra=("pattern",))
@dataclass(frozen=True, slots=True)
class PatternHit:
    """One attributed match row: pattern `pattern_id` (source `pattern`) hit `path` at `line`. The engine attributes by id; the pattern text is filled in from the request, which is the only party that has it."""

    path: str
    line: int
    pattern_id: int
    pattern: str = ""

    def __str__(self) -> str:
        """`path:line`."""
        return f"{self.path}:{self.line}"


@bind("pattern_count")
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
    timeout: float = shell.DEFAULT_TIMEOUT,
) -> list[PatternHit]:
    """One walk, every pattern in `specs`, exact per-pattern attribution as `PatternHit` rows in total (path, line, pattern) order. This is the batched shape that replaces N sequential searches plus downstream re-classification."""
    hits = _sweep(
        "patterns",
        _Batch(specs, fixed, ignore_case, under, top),
        analytic.Sweep(tuple(specs), under=under, top=top, fixed=fixed, ignore_case=ignore_case),
        roots,
        cwd=cwd,
        timeout=timeout,
    )
    # The engine attributes a hit to a pattern *id* — the request owns the text.
    return [
        replace(hit, pattern=specs[hit.pattern_id]) if hit.pattern_id < len(specs) else hit
        for hit in hits
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
    timeout: float = shell.DEFAULT_TIMEOUT,
) -> list[PatternCount]:
    """Grouped counts (`by` = `"pattern"` or `"file"`), descending, computed engine-side by the loom — no rows cross the process boundary."""
    return _sweep(
        "pattern_counts",
        _Batch(specs, fixed, ignore_case, under, top, ("--by", by)),
        analytic.Sweep(
            tuple(specs), under=under, top=top, fixed=fixed, ignore_case=ignore_case, by=by
        ),
        roots,
        cwd=cwd,
        timeout=timeout,
    )


def _sweep[R](
    verb: str,
    batch: _Batch,
    params: analytic.Sweep,
    roots: Scope,
    *,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
) -> list[R]:
    """Answer one sweep verb through the ladder. `batch.argv()` is lowered eagerly so an empty pattern set is rejected on both tiers alike."""
    argv, scope = batch.argv(), scope_argv(roots)
    schema = verb_schema(verb)
    answer = analytic.answer(
        verb,
        params,
        roots=scope,
        cwd=cwd,
        cold=lambda: cold.answer(
            "relate", "patterns", argv, schema=schema, roots=scope, cwd=cwd, timeout=timeout
        ),
    )
    return list(answer.drain())
