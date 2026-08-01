"""Kinship — what resembles what, without anyone spelling a pattern.

Where `gist` answers *"where is this exact string?"*, kinship answers the
questions regex cannot: *what resembles this file, which units are the same
thing, what shares a skeleton under different names, which of these is genuinely
unique*. Similarity is measured by compression — two things are close when
knowing one makes the other cheap to describe — so nothing needs to be named in
advance.

**Two questions, not six verbs.** Everything here is one of:

  * `similar(probe)` — the *neighbor* question: rank the corpus against ONE
    thing. The probe may be a file, one function out of a file (`path#L120`), or
    text; its shape decides how it is priced.
  * `pairs()` / `families()` / `distinct()` — the *repetition* question: what
    repeats inside a corpus, reported as the two things you can inspect and the
    one thing you can act on. All three take the same three axes — `unit`
    (file · function · match), `channel` (copies · twins · shapes · any), and an
    optional `matching` exact filter — because repetition is a point in that
    space rather than a family of verbs. `families` is the shape a dedup or
    restructure sweep acts on; `distinct` is its complement, which turns "which
    of these 14 implementations is unique?" into a measurement with a receipt.

Three things make this a library surface rather than a transcription of the CLI:

  * **Every row carries its calibrated `Grade`.** A raw distance misleads — 0.78
    over a 21k-file corpus means "both are Python", not "related". The CLI warns
    a human about that on stderr; a caller gets `row.grade` and the engine-side
    `min_grade=` filter instead.
  * **Every answer carries its provenance.** `Kin` is the row sequence *plus* the
    population it was drawn from, whether it came warm from the persisted atlas,
    and how long it took. An empty result over 21095 scored units is a completely
    different fact from an empty result over 55, and only one of them means
    "widen the scope".
  * **The score is named for its polarity.** A distance closes toward zero, a
    `twins` gap and a `recall` gain grow. Rows keep them in separate fields
    (`distance`/`echo`/`gain` on the wire, `score` plus `channel` here); nothing
    is ever fused into one number.

Distances and grades are computed in the kernel; nothing is re-derived here.
Corpus policy is the verbs' own — see `contract/search_api.toml` `[irregex]`.
"""

from __future__ import annotations

from dataclasses import dataclass
import os
from typing import TYPE_CHECKING, Literal

from ..contract.grades import Channel, Grade
from ..runtime import shell
from .corpus import CORPUS_TIMEOUT, Kin, Scope, graded, matching_argv, run, shape_argv


if TYPE_CHECKING:
    from collections.abc import Sequence


type Unit = Literal["file", "function", "match"]


def _split(label: str) -> tuple[str, int | None]:
    """A unit label back into `(path, start_line)`. File units are the path alone; fragment units are `path#Lnnn`, the coordinate an editor wants."""
    path, _, line = label.rpartition("#L")
    return (path, int(line)) if path and line.isdigit() else (label, None)


@dataclass(frozen=True, slots=True)
class Located:
    """Mixin for a row whose subject is one unit label."""

    unit: str

    @property
    def path(self) -> str:
        """The file this unit lives in."""
        return _split(self.unit)[0]

    @property
    def line(self) -> int | None:
        """The fragment's first line, or `None` when the unit is a whole file."""
        return _split(self.unit)[1]


@dataclass(frozen=True, slots=True)
class Neighbor(Located):
    """One ranked neighbor of a probe. `score` is `channel`'s own quantity — a distance closing toward 0 on `copies`/`shapes`/`any`, a widening gap on `twins`, a coding gain on `recall` — and `grade` is where that score falls on the channel's calibrated bands."""

    score: float
    grade: Grade
    channel: Channel

    @property
    def distance(self) -> float | None:
        """`score` when this channel measures a distance, else `None` — so a caller filtering on closeness cannot silently read a gain as one."""
        return None if self.channel.higher_is_stronger else self.score


@dataclass(frozen=True, slots=True)
class Pair:
    """Two units that repeat each other, `a` and `b` in label order. `score` is the channel's quantity; `byte_distance` and `structure_distance` are both always reported, so a `twins` gap can be read back to the two measurements it came from."""

    a: str
    b: str
    score: float
    byte_distance: float
    structure_distance: float
    grade: Grade
    channel: Channel

    @property
    def paths(self) -> tuple[str, ...]:
        """The two files, in label order (identical when a helper repeats inside one file)."""
        return (_split(self.a)[0], _split(self.b)[0])


@dataclass(frozen=True, slots=True)
class Family:
    """A fork family — the transitive closure of the verified repetition graph, which is the unit a dedup or restructure sweep acts on. `edge` is the family's *loosest* admitted score, so the grade describes its weakest link rather than its best pair. Families rank by consolidation opportunity (`repeated_lines`, the redundant span), never by score."""

    members: tuple[str, ...]
    edge: float
    repeated_lines: int
    byte_distance: float
    structure_distance: float
    grade: Grade
    channel: Channel

    @property
    def size(self) -> int:
        """Members in this family."""
        return len(self.members)

    @property
    def paths(self) -> tuple[str, ...]:
        """Distinct files the family spans, in first-seen order."""
        return tuple(dict.fromkeys(_split(m)[0] for m in self.members))


@dataclass(frozen=True, slots=True)
class Lonely(Located):
    """A unit that joined no family, with the receipt: its `nearest` miss and both independent distances. This is the complement of `families`, and the *rows are the answer* — a strong-looking nearest miss means the unit is barely distinct, so these rows carry no grade (grading them on kinship bands would call the strongest answer "weak")."""

    nearest: str | None
    byte_distance: float
    structure_distance: float


# ── the neighbor question ────────────────────────────────────────────────────


def similar(
    probe: str | os.PathLike[str],
    *,
    channel: Channel | str | None = None,
    unit: Unit | None = None,
    matching: Sequence[str] = (),
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    top: int = 20,
    min_grade: Grade | str | None = None,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Neighbor]:
    """The `top` units nearest `probe`, strongest first, with the probe itself excluded.

    The probe's **shape** decides how it is priced, so a caller never has to make
    a flag agree with an argument:

      * `"libs/…/scan.py"` — a file: kinship over whole units.
      * `"libs/…/scan.py#L120"` — the function containing line 120: kinship over
        function fragments (the unit follows the probe automatically).
      * `"how leases expire"` — text with no `channel`: the corpus prices it by
        coding gain, and rows arrive on `Channel.RECALL`. `retrieval.recall` is
        the same call with the cost breakdown typed.
      * text *with* a `channel` — treat the snippet as a record and compare it
        structurally: "what is shaped like this?".

    `channel` picks what "near" means for a record probe: `copies` compares raw
    bytes (copy-paste and its drift), `shapes` compares normalized structure so a
    renamed twin surfaces, `twins` ranks by how much *more* shape than vocabulary
    a pair shares, `any` takes whichever channel sees more. The CLI's metric
    spellings (`bytes`/`structure`/`echo`/`fused`) parse too.

    `matching` narrows the population to units an exact pattern admitted first —
    "among the files that mention `WalletService`, which resembles this one?".

    Generated units stay in the population here (unlike the repetition verbs): a
    hand-written file's generated twin is a legitimate, often wanted answer. Units
    too small to shed a real fingerprint sample stay out, because they land at
    distance ≈ 0 by arithmetic and a false `identical` is worse than no row.
    """
    named = Channel.parse(channel) if channel is not None else None
    if named is not None and not named.pairwise:
        msg = f"similar: {named.value!r} is chosen by the probe's shape, not by channel=; pass text with channel=None"
        raise ValueError(msg)
    argv = [os.fspath(probe)]
    if named is not None:
        argv += ["--as", named.value]
    if unit is not None:
        argv += ["--unit", unit]
    argv += matching_argv(matching, match=match, fixed=fixed, ignore_case=ignore_case)
    argv += shape_argv(top=top, min_grade=min_grade, no_index=no_index)
    rows, report = run("relate", "similar", argv, roots, cwd=cwd, timeout=timeout)
    # The probe's shape — not this argument list — decides how the answer was
    # priced, so the channel is read back from the engine's own summary rather
    # than re-derived here. A text probe with no `channel=` comes back on
    # `recall`; `path#Lnnn` comes back on `shapes`.
    answered = _reported(report) or named or Channel.COPIES
    return Kin([_neighbor(r, answered) for r in rows], channel=answered, diagnostic=report)


def _reported(report: dict[str, object]) -> Channel | None:
    """The channel the engine says it answered on, if it said."""
    named = report.get("channel")
    return Channel.parse(named) if isinstance(named, str) else None


def _neighbor(row: dict[str, object], answered: Channel) -> Neighbor:
    """Decode one ranked neighbor, reading the score out of whichever polarity column the engine named it in.

    `answered` is the channel for the answer as a whole; a row may name its own,
    because `any` resolves per pair to whichever of the two records saw more.
    """
    reported = row.get("channel")
    resolved = Channel.parse(reported) if isinstance(reported, str) else answered
    score = shell.as_float(row, resolved.quantity, 0.0) or 0.0
    return Neighbor(
        unit=shell.as_str(row, "unit"),
        score=score,
        grade=graded(row, resolved, score),
        channel=resolved,
    )


# ── the repetition question ─────────────────────────────────────────────────


def pairs(
    *,
    channel: Channel | str = Channel.TWINS,
    unit: Unit = "file",
    max_distance: float | None = None,
    min_echo: float | None = None,
    matching: Sequence[str] = (),
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    min_lines: int | None = None,
    min_mass: int | None = None,
    include_generated: bool = False,
    top: int = 50,
    min_grade: Grade | str | None = None,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Pair]:
    """Verified repeating pairs, strongest first — two units to open side by side.

    The channel is the question: `copies` finds copy-paste and its drift (byte
    near-duplicates), `shapes` finds a shared skeleton, and the default `twins`
    finds the *gap* between them — the same skeleton wearing different
    vocabulary, which is the Type-2 clone byte distance calls unrelated and the
    one abstraction candidate no other tool reports.

    Thresholds are spelled per polarity so one can never silently invert:
    `max_distance` admits a distance channel, `min_echo` a `twins` gap. Pass the
    one that matches your channel; the other is ignored by the engine.

    For the *families* those pairs form — which is what a sweep should act on —
    use `families()`, and skip re-running union-find over a pair list.
    """
    rows, report, resolved = _survey(
        "pairs",
        channel=channel,
        unit=unit,
        max_distance=max_distance,
        min_echo=min_echo,
        matching=matching,
        match=match,
        fixed=fixed,
        ignore_case=ignore_case,
        min_lines=min_lines,
        min_mass=min_mass,
        include_generated=include_generated,
        top=top,
        min_grade=min_grade,
        roots=roots,
        no_index=no_index,
        cwd=cwd,
        timeout=timeout,
    )
    return Kin(
        (
            Pair(
                a=shell.as_str(r, "a"),
                b=shell.as_str(r, "b"),
                score=(s := shell.as_float(r, resolved.quantity, 0.0) or 0.0),
                byte_distance=shell.as_float(r, "bytes", 1.0) or 0.0,
                structure_distance=shell.as_float(r, "structure", 1.0) or 0.0,
                grade=graded(r, resolved, s),
                channel=resolved,
            )
            for r in rows
        ),
        channel=resolved,
        diagnostic=report,
    )


def families(
    *,
    channel: Channel | str = Channel.TWINS,
    unit: Unit = "file",
    min_size: int = 2,
    max_distance: float | None = None,
    min_echo: float | None = None,
    matching: Sequence[str] = (),
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    min_lines: int | None = None,
    min_mass: int | None = None,
    include_generated: bool = False,
    top: int = 50,
    min_grade: Grade | str | None = None,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Family]:
    """Fork families — connected components of the verified repetition graph, best consolidation opportunity first.

    This is the shape to *act* on: the whole fixture farm, the mirrored module
    tree, the helper pasted into six files. A pair list makes every caller
    re-derive the closure, and every caller did.

    `unit="function"` is the setting a file-level sweep cannot substitute for: a
    12-line helper cloned into six unrelated modules shares ~3% of those files'
    bytes and is invisible at file granularity. With `matching=[pattern]` it
    answers "which implementations of this symbol are forks of each other?".
    """
    rows, report, resolved = _survey(
        "families",
        channel=channel,
        unit=unit,
        min_size=min_size,
        max_distance=max_distance,
        min_echo=min_echo,
        matching=matching,
        match=match,
        fixed=fixed,
        ignore_case=ignore_case,
        min_lines=min_lines,
        min_mass=min_mass,
        include_generated=include_generated,
        top=top,
        min_grade=min_grade,
        roots=roots,
        no_index=no_index,
        cwd=cwd,
        timeout=timeout,
    )
    return Kin(
        (
            Family(
                members=shell.as_strs(r, "members"),
                edge=(e := shell.as_float(r, resolved.quantity, 0.0) or 0.0),
                repeated_lines=shell.as_int(r, "repeated_lines"),
                byte_distance=shell.as_float(r, "bytes", 1.0) or 0.0,
                structure_distance=shell.as_float(r, "structure", 1.0) or 0.0,
                grade=graded(r, resolved, e),
                channel=resolved,
            )
            for r in rows
        ),
        channel=resolved,
        diagnostic=report,
    )


def distinct(
    *,
    channel: Channel | str = Channel.TWINS,
    unit: Unit = "file",
    max_distance: float | None = None,
    min_echo: float | None = None,
    matching: Sequence[str] = (),
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    min_lines: int | None = None,
    min_mass: int | None = None,
    include_generated: bool = False,
    top: int = 50,
    roots: Scope = (),
    no_index: bool = False,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Kin[Lonely]:
    """The complement: units that joined no family, each with its nearest miss priced.

    "Which of these implementations is genuinely unique?" is otherwise answered
    by an *absence* — nothing in a pair list — which is indistinguishable from a
    threshold that was too tight. Every row here carries the closest thing the
    unit had and both measured distances, so the answer comes with a receipt.

    Ordered by how far the nearest miss is: the most isolated unit first. Rows
    carry no grade, because a strong-looking miss score means the unit is barely
    distinct — the opposite of what a kinship grade would claim.
    """
    rows, report, resolved = _survey(
        "distinct",
        channel=channel,
        unit=unit,
        max_distance=max_distance,
        min_echo=min_echo,
        matching=matching,
        match=match,
        fixed=fixed,
        ignore_case=ignore_case,
        min_lines=min_lines,
        min_mass=min_mass,
        include_generated=include_generated,
        top=top,
        min_grade=None,
        roots=roots,
        no_index=no_index,
        cwd=cwd,
        timeout=timeout,
    )
    return Kin(
        (
            Lonely(
                unit=shell.as_str(r, "unit"),
                nearest=(near if (near := shell.as_str(r, "nearest")) not in {"", "—"} else None),
                byte_distance=shell.as_float(r, "bytes", 1.0) or 0.0,
                structure_distance=shell.as_float(r, "structure", 1.0) or 0.0,
            )
            for r in rows
        ),
        channel=resolved,
        diagnostic=report,
    )


def _survey(
    shape: Literal["pairs", "families", "distinct"],
    *,
    channel: Channel | str,
    unit: Unit,
    matching: Sequence[str],
    match: Literal["any", "all"],
    fixed: bool,
    ignore_case: bool,
    top: int,
    min_grade: Grade | str | None,
    roots: Scope,
    no_index: bool,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
    min_size: int | None = None,
    max_distance: float | None = None,
    min_echo: float | None = None,
    min_lines: int | None = None,
    min_mass: int | None = None,
    include_generated: bool = False,
) -> tuple[list[dict[str, object]], dict[str, object], Channel]:
    """Lower one repetition query. The three shapes differ only in what a row *is*, so they share every axis — and the noise floors are left unset by default, which lets the engine apply the unit's own (a fragment floor for functions, a mass floor for files) rather than a number restated here."""
    resolved = Channel.parse(channel)
    if not resolved.pairwise:
        msg = f"repetition has no {resolved.value!r} channel — it compares two units, and recall prices a text probe"
        raise ValueError(msg)
    argv = ["--shape", shape, "--as", resolved.value, "--unit", unit]
    for flag, value in (
        ("--min-size", min_size),
        ("--max-distance", max_distance),
        ("--min-echo", min_echo),
        ("--min-lines", min_lines),
        ("--min-mass", min_mass),
    ):
        if value is not None:
            argv += [flag, str(value)]
    if include_generated:
        argv.append("--include-generated")
    argv += matching_argv(matching, match=match, fixed=fixed, ignore_case=ignore_case)
    argv += shape_argv(top=top, min_grade=min_grade, no_index=no_index)
    rows, report = run("relate", "echoes", argv, roots, cwd=cwd, timeout=timeout)
    return rows, report, resolved
