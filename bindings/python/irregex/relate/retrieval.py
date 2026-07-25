"""Compression retrieval — ask the corpus what a piece of text costs it.

The other half of relate (`kinship.py` is the first): where kinship compares two
things already in the tree, retrieval takes *text you have* and prices it
against everything the tree knows. Three questions, three verbs:

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

Everything is denominated in bits because that is what compression measures:
a low cost means the corpus already knows this text. Scores are the kernel's;
nothing is re-derived here. For attribution that is also re-verified against the
files' *current* bytes, use `compose.provenance` instead of `quote`.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import TYPE_CHECKING

from . import engine
from .corpus import CORPUS_TIMEOUT, Scope, run


if TYPE_CHECKING:
    import os


@dataclass(frozen=True, slots=True)
class Recalled:
    """One file ranked by how cheaply it would describe the query. `gain` ∈ (−∞, 1] is the coding gain — higher is closer, and a candidate worse than cold coding scores below zero."""

    path: str
    gain: float
    cost_bits: float
    bits_saved: float
    factors: int
    literals: int


@dataclass(frozen=True, slots=True)
class Pick:
    """One member of a jointly-chosen reading set. `marginal_bits` is what this file adds *beyond every earlier pick* — not its standalone relevance — and `coverage` is how much of the query the picks explain cumulatively through this one. `patterns` is populated only by `compose.context`, naming the exact patterns that admitted the file."""

    rank: int
    path: str
    marginal_bits: float
    coverage: float
    patterns: tuple[str, ...] = ()


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
    `coverage` and `foreign` are the honest verdict the CLI prints to stderr: a
    high `foreign` count means the query text simply is not in this repository,
    which no amount of ranking would have told you.
    """

    __slots__ = ("coverage", "foreign", "picks", "priced_bits")

    def __init__(self, picks: Sequence[Pick], report: dict[str, object]) -> None:
        """Wrap `picks`, lifting coverage and foreign-chunk counts out of the verb's stderr summary record."""
        self.picks = tuple(picks)
        self.coverage = (engine.as_float(report, "coverage_pct", 0.0) or 0.0) / 100.0
        self.foreign = engine.as_int(report, "foreign")
        self.priced_bits = engine.as_float(report, "priced_bits", 0.0) or 0.0

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
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> list[Recalled]:
    """The `top` files that would describe `text` most cheaply, closest first.

    Drives relate's `search` verb — named `recall` here because that is the job
    it does next to `irregex.search`: recall by content when you cannot spell the
    exact string. Typo-tolerant and regex-free; follow it with `irregex.search`
    on whatever exact name it surfaces.
    """
    rows, _ = run("relate", "search", [text, "--top", str(top)], roots, cwd=cwd, timeout=timeout)
    return [
        Recalled(
            path=engine.as_str(r, "path"),
            gain=engine.as_float(r, "gain", 0.0) or 0.0,
            cost_bits=engine.as_float(r, "cost_bits", 0.0) or 0.0,
            bits_saved=engine.as_float(r, "bits_saved", 0.0) or 0.0,
            factors=engine.as_int(r, "factors"),
            literals=engine.as_int(r, "literals"),
        )
        for r in rows
    ]


def pack(
    text: str,
    *,
    top: int = 8,
    roots: Scope = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> Packed:
    """The set of at most `top` files that jointly explains `text` most cheaply.

    Greedy submodular coverage: each pick is priced by what it adds beyond the
    picks already chosen, so the result is an anti-redundant reading list — the
    shape you want when assembling context for a task, where a second copy of an
    already-covered file is worth nothing. Stops early when nothing adds bits.
    """
    rows, report = run("relate", "pack", [text, "--top", str(top)], roots, cwd=cwd, timeout=timeout)
    return Packed([decode_pick(r) for r in rows], report)


def decode_pick(row: dict[str, object]) -> Pick:
    """Decode one coverage pick — shared with `compose.context`, which adds the admitting patterns."""
    return Pick(
        rank=engine.as_int(row, "rank"),
        path=engine.as_str(row, "path"),
        marginal_bits=engine.as_float(row, "marginal_bits", 0.0) or 0.0,
        coverage=engine.as_float(row, "coverage", 0.0) or 0.0,
        patterns=engine.as_strs(row, "patterns"),
    )


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
    rows, _ = run("relate", "quote", [text], cwd=cwd, timeout=timeout)
    if not rows:
        return Quotation((), 0.0, 0.0, 0, 0, 0)
    summary, *phrase_rows = rows
    return Quotation(
        phrases=tuple(
            Phrase(
                text=engine.as_str(r, "text"),
                occurrences=engine.as_int(r, "occurrences"),
                bits=engine.as_float(r, "bits", 0.0) or 0.0,
                source=engine.as_str(r, "source"),
            )
            for r in phrase_rows
        ),
        bits=engine.as_float(summary, "bits", 0.0) or 0.0,
        bits_per_byte=engine.as_float(summary, "bits_per_byte", 0.0) or 0.0,
        quoted_bytes=engine.as_int(summary, "quoted_bytes"),
        query_bytes=engine.as_int(summary, "query_bytes"),
        escapes=engine.as_int(summary, "escapes"),
    )
