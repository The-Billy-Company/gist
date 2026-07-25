"""Kinship — what resembles what, without anyone spelling a pattern.

Where `gist` answers *"where is this exact string?"*, kinship answers the
questions regex cannot: *what resembles this file, which files are the same
thing, what shares a skeleton under different names, which functions are the same
idea*. Similarity is measured by compression — two things are close when knowing
one makes the other cheap to describe — so nothing needs to be named in advance.

Six verbs across two granularities. Over whole **files**: `similar` (neighbors of
a probe), `dups` (verified near-duplicate pairs), `clusters` (the fork families
those pairs form), `echoes` (same skeleton, renamed vocabulary). Over
**functions**: `concepts` (families of functions that are the same idea) and
`fragments` (nearest functions to a description). The function pair exists
because a file-level comparison cannot see one duplicated helper living inside
two otherwise-unrelated modules.

Two things make this a library surface rather than a transcription of the CLI:

  * **Every row carries its calibrated `Grade`.** A raw distance misleads — 0.78
    over a 21k-file corpus means "both are Python", not "related". The CLI warns
    a human about that on stderr; a caller gets `row.grade` and the engine-side
    `min_grade=` filter instead.
  * **Every answer carries its provenance.** `Kin` is the row sequence *plus* the
    population it was drawn from, whether it came warm from the persisted atlas,
    and how long it took. An empty result over 21095 scored files is a completely
    different fact from an empty result over 55, and only one of them means
    "widen the scope".

Distances and grades are computed in the kernel; nothing is re-derived here.
Corpus policy is the verbs' own — see `contract/search_api.toml` `[irregex]`.
"""

from __future__ import annotations

from dataclasses import dataclass
import os

from . import engine
from .corpus import CORPUS_TIMEOUT, Kin, Region, Scope, graded, region, run, shape_argv
from .grade import Channel, Grade


@dataclass(frozen=True, slots=True)
class Similar:
    """One kinship neighbor: `distance` ∈ [0, 1], 0 = identical."""

    path: str
    distance: float
    grade: Grade
    channel: Channel


@dataclass(frozen=True, slots=True)
class DupPair:
    """One verified near-duplicate pair, `a` < `b` in path order."""

    a: str
    b: str
    distance: float
    grade: Grade


@dataclass(frozen=True, slots=True)
class Cluster:
    """A fork family: the transitive closure of the dup graph at one threshold — the whole fixture farm or mirrored module tree, not a pair list to re-join."""

    paths: tuple[str, ...]
    max_distance: float

    @property
    def size(self) -> int:
        """Members in this family."""
        return len(self.paths)


@dataclass(frozen=True, slots=True)
class Echo:
    """A pair far apart in bytes but close in structure — the same skeleton wearing different vocabulary (a Type-2 clone `dups` cannot see). `echo` is the gap the ranking uses; wider is a stronger abstraction candidate."""

    a: str
    b: str
    echo: float
    byte_distance: float
    structure_distance: float
    grade: Grade


@dataclass(frozen=True, slots=True)
class Concept:
    """A family of functions that are the same idea — the repeated engine, the duplicated dump, the copy-pasted validator. Ranked by consolidation opportunity: `repeated_lines` (shortest member span × redundant copies) then channel confidence, never a fused score. `byte_distance`/`echo` are present only for the channels that measured them."""

    members: tuple[Region, ...]
    repeated_lines: int
    confidence: float
    structure_distance: float
    byte_distance: float | None = None
    echo: float | None = None

    @property
    def size(self) -> int:
        """Fragments in this family."""
        return len(self.members)

    @property
    def paths(self) -> tuple[str, ...]:
        """Distinct files the family spans, in first-seen order."""
        return tuple(dict.fromkeys(m.path for m in self.members))


# ── file kinship ─────────────────────────────────────────────────────────────


def similar(
    path: str | os.PathLike[str],
    *,
    channel: Channel | str = Channel.COPIES,
    top: int = 20,
    min_grade: Grade | str | None = None,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Similar]:
    """The `top` files nearest `path` by compression kinship, closest first (the probe itself excluded).

    `channel` picks what "near" means: `copies` compares raw bytes (the default —
    copy-paste and its drift), `shapes` compares normalized structure so a
    renamed twin surfaces, `twins` ranks by how much *more* shape than
    vocabulary a pair shares, and `any` takes whichever channel sees more. The
    CLI's metric spellings (`bytes`/`structure`/`echo`/`fused`) parse too.
    """
    resolved = Channel.parse(channel)
    argv = [
        os.fspath(path),
        "--as",
        resolved.value,
        *shape_argv(top=top, min_grade=min_grade, no_index=no_index),
    ]
    rows, report = run("relate", "similar", argv, roots, cwd=cwd, timeout=timeout)
    return Kin(
        (
            Similar(
                path=engine.as_str(r, "path"),
                distance=(d := engine.as_float(r, "distance", 1.0) or 0.0),
                grade=graded(r, resolved, d),
                channel=Channel.parse(engine.as_str(r, "channel", resolved.value)),
            )
            for r in rows
        ),
        channel=resolved,
        diagnostic=report,
    )


def dups(
    *,
    max_distance: float = 0.25,
    top: int = 100,
    min_grade: Grade | str | None = None,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[DupPair]:
    """Near-duplicate file pairs at byte distance ≤ `max_distance`, closest first. Every emitted pair is exactly verified, not merely nominated. For the *families* those pairs form, use `clusters` — it is the transitive closure at the same threshold, and saves you re-joining the graph."""
    argv = [
        "--max-distance",
        str(max_distance),
        *shape_argv(top=top, min_grade=min_grade, no_index=no_index),
    ]
    rows, report = run("relate", "dups", argv, roots, cwd=cwd, timeout=timeout)
    return Kin(
        (
            DupPair(
                a=engine.as_str(r, "a"),
                b=engine.as_str(r, "b"),
                distance=(d := engine.as_float(r, "distance", 1.0) or 0.0),
                grade=graded(r, Channel.COPIES, d),
            )
            for r in rows
        ),
        channel=Channel.COPIES,
        diagnostic=report,
    )


def clusters(
    *,
    max_distance: float = 0.25,
    min_size: int = 2,
    top: int = 50,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Cluster]:
    """Fork families — connected components of the verified dup graph, largest first. This is the unit a dedup or restructure sweep acts on: act per family, not per pair."""
    argv = [
        "--max-distance",
        str(max_distance),
        "--min-size",
        str(min_size),
        *shape_argv(top=top, no_index=no_index),
    ]
    rows, report = run("relate", "clusters", argv, roots, cwd=cwd, timeout=timeout)
    return Kin(
        (
            Cluster(
                paths=engine.as_strs(r, "paths"),
                max_distance=engine.as_float(r, "max_distance", 0.0) or 0.0,
            )
            for r in rows
        ),
        channel=Channel.COPIES,
        diagnostic=report,
    )


def echoes(
    *,
    min_echo: float = 0.15,
    top: int = 50,
    min_grade: Grade | str | None = None,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Echo]:
    """DRY candidates `dups` cannot see: pairs whose byte distance exceeds their structure distance by at least `min_echo`, widest gap first. `dups` finds copy-paste; `echoes` finds the same skeleton after a rename — the abstraction candidate."""
    argv = [
        "--min-echo",
        str(min_echo),
        *shape_argv(top=top, min_grade=min_grade, no_index=no_index),
    ]
    rows, report = run("relate", "echoes", argv, roots, cwd=cwd, timeout=timeout)
    return Kin(
        (
            Echo(
                a=engine.as_str(r, "a"),
                b=engine.as_str(r, "b"),
                echo=(gap := engine.as_float(r, "echo", 0.0) or 0.0),
                byte_distance=engine.as_float(r, "bytes", 1.0) or 0.0,
                structure_distance=engine.as_float(r, "structure", 1.0) or 0.0,
                grade=graded(r, Channel.TWINS, gap),
            )
            for r in rows
        ),
        channel=Channel.TWINS,
        diagnostic=report,
    )


# ── function kinship ─────────────────────────────────────────────────────────

# `concepts` predates the shared `--as` vocabulary and still spells its channel
# `--lens` by metric name; it also has no fused channel to select.
_CONCEPT_LENS: dict[Channel, str] = {
    Channel.SHAPES: "structure",
    Channel.COPIES: "bytes",
    Channel.TWINS: "echo",
}


def _lens(channel: Channel | str) -> tuple[Channel, list[str]]:
    resolved = Channel.parse(channel)
    if resolved not in _CONCEPT_LENS:
        options = ", ".join(c.value for c in _CONCEPT_LENS)
        msg = f"concepts has no {resolved.value!r} channel; use one of {options}"
        raise ValueError(msg)
    return resolved, ["--lens", _CONCEPT_LENS[resolved]]


def concepts(
    *,
    channel: Channel | str = Channel.SHAPES,
    max_distance: float = 0.25,
    min_echo: float = 0.15,
    min_lines: int = 5,
    min_size: int = 2,
    top: int = 20,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Concept]:
    """Families of functions that are the same idea, ranked by consolidation opportunity.

    The function-level sibling of `clusters`/`echoes`: the comparison unit is the
    function fragment, not the file, so one duplicated helper inside two
    otherwise-unrelated modules still surfaces. `fragments` is the retrieval half
    of the same verb — nearest functions to a described concept.
    """
    resolved, lens = _lens(channel)
    argv = [
        *lens,
        "--max-distance",
        str(max_distance),
        "--min-echo",
        str(min_echo),
        "--min-lines",
        str(min_lines),
        "--min-size",
        str(min_size),
        *shape_argv(top=top, no_index=no_index),
    ]
    rows, report = run("relate", "concepts", argv, roots, cwd=cwd, timeout=timeout)
    return Kin(
        (
            Concept(
                members=tuple(region(m) for m in engine.as_rows(r, "members")),
                repeated_lines=engine.as_int(r, "repeated_lines"),
                confidence=engine.as_float(r, "confidence", 0.0) or 0.0,
                structure_distance=engine.as_float(r, "structure", 1.0) or 0.0,
                byte_distance=engine.as_float(r, "bytes"),
                echo=engine.as_float(r, "echo"),
            )
            for r in rows
        ),
        channel=resolved,
        diagnostic=report,
    )


def fragments(
    text: str,
    *,
    channel: Channel | str = Channel.SHAPES,
    top: int = 20,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Region]:
    """The function fragments nearest to `text`, closest first — concept retrieval at function granularity, where `recall` works at file granularity. Each `Region` carries its `distance`, and `Region.read()` returns the code itself."""
    resolved, lens = _lens(channel)
    argv = [text, *lens, *shape_argv(top=top, no_index=no_index)]
    rows, report = run("relate", "concepts", argv, roots, cwd=cwd, timeout=timeout)
    return Kin((region(r) for r in rows), channel=resolved, diagnostic=report)
