"""Narrow with exact match, then reason with compression (ADR-367).

`gist` answers *"where is this exact pattern?"*; `relate` answers *"what is this
text like?"*. These verbs need both at once: the exact `PatternSet` narrows the
corpus to a typed candidate set, then the compression kernel reasons **only
inside that narrowing**. Hand-piping `gist -l` into a relate verb throws the
match information away between the two steps and pays whole-corpus statistical
noise; these keep it.

  * `context(text, patterns)` — the minimal non-redundant reading set among files
    that *actually* match. `retrieval.pack` would happily rank a README that
    never mentions the subject.
  * `family(pattern)` — which implementations of this pattern are forks of each
    other, compared as **functions** rather than whole files, so one copy-pasted
    helper inside two unrelated modules still surfaces.
  * `provenance(text)` — where a pasted snippet came from, re-verified against the
    source file's current bytes rather than a shelf snapshot.

`radius.blast` is the fourth composed verb and lives in its own module.

`family`'s shape here is deliberately not the CLI's: a terminal reads top to
bottom, so it streams family and distinct rows interleaved. A program almost
always wants one class or the other, so it gets `FamilyReport.families` and
`.distinct` as separate fields.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal

from . import engine
from .corpus import CORPUS_TIMEOUT, Region, Scope, merge_paths, region, run, scope_argv
from .grade import Channel
from .retrieval import Pick, decode_pick


if TYPE_CHECKING:
    from collections.abc import Sequence
    import os


@dataclass(frozen=True, slots=True)
class Family:
    """A verified family of implementations that match the same pattern. `edge` is the widest admitted distance in this family and `score` the engine's consolidation-opportunity ranking (repeated lines × channel confidence) — a display order, never a fused relevance."""

    rank: int
    unit: str
    channel: Channel
    edge: float
    repeated_lines: int
    score: float
    members: tuple[Region, ...]

    @property
    def size(self) -> int:
        """Members in this family."""
        return len(self.members)

    @property
    def paths(self) -> tuple[str, ...]:
        """Distinct files the family spans, in first-seen order."""
        return merge_paths(m.path for m in self.members)


@dataclass(frozen=True, slots=True)
class Distinct:
    """A matching implementation that joined no family — kept first-class, with its closest structural neighbor and both independent distances, so similar names never imply the same implementation by omission."""

    unit: str
    member: Region
    nearest: Region | None
    byte_distance: float
    structure_distance: float


@dataclass(frozen=True, slots=True)
class FamilyReport:
    """Both answer classes, split: `families` are consolidation candidates, `distinct` regions are the genuinely different implementations."""

    families: tuple[Family, ...]
    distinct: tuple[Distinct, ...]

    @property
    def paths(self) -> tuple[str, ...]:
        """Every file either class touches, families first."""
        return merge_paths(
            (p for f in self.families for p in f.paths),
            (d.member.path for d in self.distinct),
        )


@dataclass(frozen=True, slots=True)
class Attribution:
    """One phrase traced back to a file. `verified` is the whole point: the engine re-read `source`'s **current** bytes and re-found the phrase there, so `line` can be trusted. A `verified=False` row is drift — the shelf remembers the phrase, the live file no longer holds it."""

    text: str
    occurrences: int
    source: str
    verified: bool
    line: int | None

    def __str__(self) -> str:
        """`path:line` when verified, else a drift marker."""
        return f"{self.source}:{self.line}" if self.verified else f"(drift) {self.source or '?'}"


def _scoped(roots: Scope, corpus_wide: bool, verb: str) -> list[str]:
    """Lower the mandatory scope. `context`/`family` refuse to run unscoped so a composed query can never silently sweep `vendor/`; that refusal happens here rather than as an opaque exit 2 from the child."""
    args = scope_argv(roots)
    if corpus_wide:
        return ["--all", *args]
    if not args:
        msg = f"{verb} requires a scope: pass roots=… or corpus_wide=True"
        raise ValueError(msg)
    return args


def context(
    text: str,
    patterns: Sequence[str],
    *,
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    top: int = 8,
    roots: Scope = (),
    corpus_wide: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> list[Pick]:
    """The minimal non-redundant reading set among files that *actually* match `patterns`.

    `match="any"` admits a file that hit ≥1 pattern, `"all"` requires every one.
    Only the survivors are packed, so each `Pick` carries both its
    `marginal_bits` and the `patterns` that admitted it — two scores, never fused.
    """
    if not patterns:
        msg = "context: at least one pattern is required"
        raise ValueError(msg)
    argv = [text, *(flag for p in patterns for flag in ("-e", p)), "--match", match]
    if fixed:
        argv.append("-F")
    if ignore_case:
        argv.append("-i")
    argv += ["--top", str(top), *_scoped(roots, corpus_wide, "context")]
    rows, _ = run("irregex", "context", argv, cwd=cwd, timeout=timeout)
    return [decode_pick(r) for r in rows]


def family(
    pattern: str,
    *,
    unit: Literal["function", "match", "file"] = "function",
    max_structure_distance: float | None = None,
    max_distance: float | None = None,
    echo_min: float | None = None,
    context_lines: int | None = None,
    min_size: int = 2,
    fixed: bool = False,
    ignore_case: bool = False,
    top: int = 50,
    roots: Scope = (),
    corpus_wide: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> FamilyReport:
    """Which implementations of `pattern` are forks of each other, compared as code rather than as files.

    `kinship.dups` compares whole files, so two unrelated modules that happen to
    share one copy-pasted helper stay invisible. This lifts every exact hit to its
    enclosing function first (`unit="match"` for bounded windows, `"file"` for
    whole-file kinship), then builds families only among those units.

    The three thresholds select the channel, mirroring the CLI's deliberately
    distinct spellings so a polarity can never silently invert:
    `max_structure_distance` for shared skeletons (the default), `max_distance`
    for byte near-duplicates, `echo_min` for renamed twins. Test files sharing a
    skeleton are structural twins rather than byte duplicates, so prefer
    `echo_min`/`max_structure_distance` when hunting those.
    """
    argv: list[str] = [pattern, "--unit", unit, "--min-size", str(min_size)]
    for flag, value in (
        ("--max-structure-distance", max_structure_distance),
        ("--max-distance", max_distance),
        ("--echo-min", echo_min),
        ("-C", context_lines),
    ):
        if value is not None:
            argv += [flag, str(value)]
    if fixed:
        argv.append("-F")
    if ignore_case:
        argv.append("-i")
    argv += ["--top", str(top), *_scoped(roots, corpus_wide, "family")]
    rows, _ = run("irregex", "family", argv, cwd=cwd, timeout=timeout)
    return FamilyReport(
        families=tuple(_family(r) for r in rows if r.get("kind") == "family"),
        distinct=tuple(_distinct(r) for r in rows if r.get("kind") == "distinct"),
    )


def _family(row: dict[str, object]) -> Family:
    """Decode one family row."""
    return Family(
        rank=engine.as_int(row, "rank"),
        unit=engine.as_str(row, "unit"),
        channel=Channel.parse(engine.as_str(row, "channel", "shapes")),
        edge=engine.as_float(row, "edge", 0.0) or 0.0,
        repeated_lines=engine.as_int(row, "repeated_lines"),
        score=engine.as_float(row, "score", 0.0) or 0.0,
        members=tuple(region(m) for m in engine.as_rows(row, "members")),
    )


def _distinct(row: dict[str, object]) -> Distinct:
    """Decode one unaffiliated-implementation row."""
    member = row.get("member")
    nearest = row.get("nearest")
    return Distinct(
        unit=engine.as_str(row, "unit"),
        member=region(member if isinstance(member, dict) else {}),
        nearest=region(nearest) if isinstance(nearest, dict) else None,
        byte_distance=engine.as_float(row, "byte_distance", 1.0) or 0.0,
        structure_distance=engine.as_float(row, "structure_distance", 1.0) or 0.0,
    )


def provenance(
    text: str,
    *,
    min_phrase: int = 12,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> list[Attribution]:
    """Where `text` came from, re-verified against the tree's current bytes.

    `retrieval.quote` attributes phrases from the codex shelf, which is a snapshot
    and can therefore point at a line that no longer exists. This re-reads each
    attributed file and re-finds the phrase, so a `verified` row is a citation you
    can follow. Corpus-wide by design — provenance reads the whole shelf, which
    `introspection.atlas_index(shelf=True)` builds.
    """
    rows, _ = run(
        "irregex",
        "provenance",
        [text, "--min-phrase", str(min_phrase)],
        cwd=cwd,
        timeout=timeout,
    )
    return [
        Attribution(
            text=engine.as_str(r, "text"),
            occurrences=engine.as_int(r, "occurrences"),
            source=engine.as_str(r, "source"),
            verified=bool(r.get("verified")),
            line=engine.as_int(r, "line") if r.get("line") is not None else None,
        )
        for r in rows
    ]
