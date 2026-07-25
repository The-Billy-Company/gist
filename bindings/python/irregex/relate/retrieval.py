"""Compression retrieval — ask the corpus what a piece of text costs it.

The other half of relate (`kinship.py` is the first): where kinship compares two
things already in the tree, retrieval takes *text you have* and prices it
against everything the tree knows. Three questions:

  * `recall(text)` — which single files would describe this text most cheaply?
    Content recall with no regex and no exact spelling required: the answer to
    "gist found nothing and I'm not sure what it's called".
  * `pack(text)` — which *set* of files jointly explains it cheapest, each pick
    priced by the bits it adds **beyond the picks before it**? Near-duplicates
    of an earlier pick never make the cut, which is what makes this a reading
    list rather than a ranking.
  * `quote(text)` — rewrite the text as verbatim corpus quotations, each phrase
    priced in bits and attributed to a source file. Where did this snippet come
    from, and how much of it is genuinely new?

`recall` and `pack` both take `matching=[…]`: the exact engine narrows the corpus
first and the pricing happens only inside what matched (ADR-367). Compression is
a statistical measure and knows nothing about a word, so unnarrowed it will
happily rank a file that never mentions the subject.

Everything is denominated in bits because that is what compression measures:
a low cost means the corpus already knows this text. Scores are the kernel's;
nothing is re-derived here. For attribution that is also re-verified against the
files' *current* bytes, use `compose.provenance` instead of `quote`.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field as dc_field, replace
from typing import TYPE_CHECKING, Literal

from ..contract.grades import Channel, Grade, grade_of
from ..contract.table import verb_schema
from ..runtime import analytic, cold
from ..runtime.decode import bind
from .corpus import CORPUS_TIMEOUT, Scope, matching_argv, run, scope_argv


if TYPE_CHECKING:
    import os

    from ..runtime.analytic import Stats


@bind("recalled", extra=("grade",))
@dataclass(frozen=True, slots=True)
class Recalled:
    """One file ranked by how cheaply it would describe the query. `gain` ∈ (−∞, 1] is the coding gain — higher is closer, and a candidate worse than cold coding scores below zero. `grade` bands that gain: text the corpus can quote verbatim reaches `identical`, an on-target query lands `strong`/`moderate`, and a subject the scope does not contain grades `weak` or `none` however it is ranked."""

    path: str
    gain: float
    # Banded on this side against the recall channel's calibration, not carried by
    # the row: the engine measures the gain, the contract prices the bands. Keyword
    # -only so the fields the schema *does* carry stay required.
    grade: Grade = dc_field(default=Grade.NONE, kw_only=True)
    cost_bits: float
    bits_saved: float
    factors: int
    literals: int


@bind("pick")
@dataclass(frozen=True, slots=True)
class Pick:
    """One member of a jointly-chosen reading set. `marginal_bits` is what this file adds *beyond every earlier pick* — not its standalone relevance — and `coverage` is how much of the query the picks explain cumulatively through this one. `patterns` is populated only by `compose.context`, naming the exact patterns that admitted the file."""

    rank: int
    path: str
    marginal_bits: float
    coverage: float
    patterns: tuple[str, ...] = ()


@bind("phrase", absent={"source": ""})
@dataclass(frozen=True, slots=True)
class Phrase:
    """One maximal verbatim phrase the corpus already contains, priced in bits and attributed to one exemplar file (`source` is empty when attribution failed)."""

    text: str
    occurrences: int
    bits: float
    source: str


class Packed(Sequence[Pick]):
    """A reading set plus how well it covers the query.

    Iterate it for the picks in order, or take `paths` for the set itself.
    `coverage` and `foreign` are the honest verdict a CLI user reads off stderr: a
    high `foreign` count means the query text simply is not in this repository,
    which no amount of ranking would have told you.
    """

    __slots__ = ("picks", "stats")

    def __init__(self, picks: Sequence[Pick], stats: Stats) -> None:
        """Wrap `picks` with the answer-level stats behind them."""
        self.picks = tuple(picks)
        self.stats = stats

    @property
    def coverage(self) -> float:
        """How much of the query the whole set explains, in [0, 1] — the last pick's cumulative figure, since each is priced against the ones before it."""
        return self.picks[-1].coverage if self.picks else 0.0

    @property
    def foreign(self) -> int:
        """Query fingerprints the corpus has never seen. Nonzero with few picks means the subject is not in this tree at all — a different fact from a thin ranking."""
        return self.stats.foreign

    @property
    def paths(self) -> tuple[str, ...]:
        """The reading set, in pick order."""
        return tuple(p.path for p in self.picks)

    def __len__(self) -> int:
        """Number of picks."""
        return len(self.picks)

    def __getitem__(self, index: int | slice) -> Pick | tuple[Pick, ...]:
        """Index or slice the picks."""
        return self.picks[index]

    def __repr__(self) -> str:
        """`Packed(3 picks, coverage=0.87, foreign=0)`."""
        return (
            f"Packed({len(self.picks)} picks, coverage={self.coverage:.2f}, foreign={self.foreign})"
        )


@bind("quotation")
@dataclass(frozen=True, slots=True)
class Quotation:
    """A text rewritten as corpus quotations. `bits_per_byte` is the corpus-conditional compression rate — low means the corpus already knows this text — and `novelty` is the share of bytes no quotation covered."""

    phrases: tuple[Phrase, ...]
    bits: float
    bits_per_byte: float
    quoted_bytes: int
    query_bytes: int
    escapes: int

    @property
    def novelty(self) -> float:
        """Fraction of the query the corpus could not quote at all, in [0, 1]."""
        return 1.0 - self.quoted_bytes / self.query_bytes if self.query_bytes else 0.0

    @property
    def sources(self) -> tuple[str, ...]:
        """Distinct attributed files, in first-quoted order."""
        return tuple(dict.fromkeys(p.source for p in self.phrases if p.source))


def recall(
    text: str,
    *,
    top: int = 10,
    matching: Sequence[str] = (),
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> list[Recalled]:
    """The `top` files that would describe `text` most cheaply, closest first.

    A **text** probe handed to relate's one neighbor verb (`similar`): with no
    kinship channel named, the honest reading of prose is "explain this to me",
    which is retrieval priced in bits. Named `recall` here because that is the job
    it does next to `irregex.search` — recall by content when you cannot spell the
    exact string. Typo-tolerant and regex-free; follow it with `irregex.search` on
    whatever exact name it surfaces.

    `kinship.similar` is the same call with the neighbor row type; this one adds
    the cost breakdown (`cost_bits`, `factors`, `literals`) the gain came from.
    `matching` restricts the pricing to files an exact pattern admitted, which
    turns the question into "among the files that mention X, which explains this
    best?" — the lexicon is then built over that subset, so prices are relative
    to it rather than to the whole corpus.
    """
    argv = [text, "--top", str(top)]
    argv += matching_argv(matching, match=match, fixed=fixed, ignore_case=ignore_case)

    def cold_rung() -> analytic.Rows:
        raw, report = run("relate", "similar", argv, roots, cwd=cwd, timeout=timeout)
        # The neighbor verb names its subject `unit`, because a row may be a
        # fragment; a recall row is always a whole file.
        objects = [{**r, "path": r.get("unit") or r.get("path")} for r in raw]
        return analytic.rows_of(
            cold.rows(verb_schema("recall"), objects), cold.stats(report, len(objects))
        )

    rows = analytic.answer(
        "recall",
        analytic.Retrieval(query=text, top=top),
        roots=scope_argv(roots),
        cwd=cwd,
        # Narrowing by an exact pattern set is a compose-family request; the
        # retrieval params have no room for it, so it stays a CLI question.
        native=not matching,
        cold=cold_rung,
    ).drain()
    return [replace(r, grade=grade_of(Channel.RECALL, r.gain)) for r in rows]


def pack(
    text: str,
    *,
    top: int = 8,
    matching: Sequence[str] = (),
    match: Literal["any", "all"] = "any",
    fixed: bool = False,
    ignore_case: bool = False,
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Packed:
    """The set of at most `top` files that jointly explains `text` most cheaply.

    Greedy submodular coverage: each pick is priced by what it adds beyond the
    picks already chosen, so the result is an anti-redundant reading list — the
    shape you want when assembling context for a task, where a second copy of an
    already-covered file is worth nothing. Stops early when nothing adds bits.

    `matching` packs only the files an exact pattern admitted (ADR-367), and each
    `Pick` then names the `patterns` that let it in. That is the difference
    between "the cheapest description of this text" and "the cheapest description
    among files that actually mention the subject" — unnarrowed, a README that
    never names the thing can still rank, because coverage is a statistical
    measure and knows nothing about the word.
    """
    argv = [text, "--top", str(top)]
    argv += matching_argv(matching, match=match, fixed=fixed, ignore_case=ignore_case)
    scope, schema = scope_argv(roots), verb_schema("pack")
    # Narrowed, this *is* the composed verb: same pick rows, an exact set admitting
    # the candidates. The CLI spells both as `relate pack`, so only the cold rung's
    # argv differs between the two.
    verb, params = (
        (
            "context",
            analytic.Compose(
                text=text,
                patterns=tuple(matching),
                top=top,
                match_all=match == "all",
                fixed=fixed,
                ignore_case=ignore_case,
            ),
        )
        if matching
        else ("pack", analytic.Retrieval(query=text, top=top))
    )
    answer = analytic.answer(
        verb,
        params,
        roots=scope,
        cwd=cwd,
        cold=lambda: cold.answer(
            "relate", "pack", argv, schema=schema, roots=scope, cwd=cwd, timeout=timeout
        ),
    )
    return Packed(answer.drain(), answer.stats)


def quote(
    text: str,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Quotation:
    """Rewrite `text` as verbatim quotations from the whole corpus, priced in bits.

    Scope is deliberately absent: quotation reads the corpus-wide codex shelf, so
    build it first with `relate index --shelf` (`introspection.atlas_index(shelf=True)`).
    The shelf is a snapshot — for attribution re-verified against each source
    file's *current* bytes, use `compose.provenance`.
    """

    def cold_rung() -> analytic.Rows:
        raw, report = run("relate", "quote", [text], cwd=cwd, timeout=timeout)
        # The CLI streams the summary first and the phrases after it; the schema
        # nests them, which is the shape the in-process plane returns.
        summary, phrases = (raw[0], raw[1:]) if raw else ({}, [])
        objects = [{**summary, "phrases": phrases}] if raw else []
        return analytic.rows_of(
            cold.rows(verb_schema("quote"), objects), cold.stats(report, len(phrases))
        )

    quoted = analytic.answer("quote", analytic.Retrieval(query=text), cwd=cwd, cold=cold_rung).one()
    return quoted if quoted is not None else Quotation((), 0.0, 0.0, 0, 0, 0)
