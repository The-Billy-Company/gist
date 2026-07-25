"""Narrow with exact match, then reason with compression (ADR-367).

`gist` answers *"where is this exact pattern?"*; `relate` answers *"what is this
text like?"*. Some questions need both at once: the exact `PatternSet` narrows the
corpus to a typed candidate set, then the compression kernel reasons **only inside
that narrowing**. Hand-piping `gist -l` into a relate verb throws the match
information away between the two steps and pays whole-corpus statistical noise.

Composition is a **modifier**, not a family of verbs. Narrowing is spelled
`matching=[…]` on the relate query functions, where it composes with every other
axis they already have:

  * `retrieval.pack(text, matching=[…])` — the minimal non-redundant reading set
    among files that *actually* match. Unnarrowed, `pack` would happily rank a
    README that never mentions the subject.
  * `kinship.families(matching=[pattern], unit="function")` — which
    implementations of a pattern are forks of each other, compared as functions
    rather than whole files, so one copy-pasted helper inside two unrelated
    modules still surfaces.
  * `kinship.similar(path, matching=[…])`, `retrieval.recall(text, matching=[…])`
    — the neighbor and recall questions, asked inside the matching set.

What remains here is the composed verb that is not a narrowing of an existing
question but a different act:

  * `provenance(text)` — where a pasted snippet came from, re-verified against
    each source file's current bytes rather than a shelf snapshot.

`radius.blast` is the other one, and lives in its own module.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

from ..contract.table import verb_schema
from ..relate.corpus import CORPUS_TIMEOUT
from ..runtime import analytic, cold
from ..runtime.decode import bind


if TYPE_CHECKING:
    import os


# The engine's own default phrase floor; anything else is a knob the analytic
# params family cannot carry, so the query declines to the CLI rather than being
# answered with a floor the caller did not ask for.
_MIN_PHRASE = 12


@bind("attribution", absent={"source": "", "line": None})
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


def provenance(
    text: str,
    *,
    min_phrase: int = _MIN_PHRASE,
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
    schema = verb_schema("provenance")
    argv = [text, "--min-phrase", str(min_phrase)]

    def spawn() -> analytic.Rows:
        return cold.answer("irregex", "provenance", argv, schema=schema, cwd=cwd, timeout=timeout)

    if min_phrase != _MIN_PHRASE:
        return list(spawn().drain())
    return list(
        analytic.answer("provenance", analytic.Compose(text=text), cwd=cwd, cold=spawn).drain()
    )
