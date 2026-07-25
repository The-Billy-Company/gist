"""The corpus substrate every compression verb stands on.

`gist` searches a *tree* the way ripgrep does — one file at a time, honoring
`.gitignore`. The compression verbs instead read a **corpus**: every non-binary
file under the roots minus VCS and build subtrees, treated as one statistical
population. That difference is why they live behind a different substrate, and
this module is it — the vocabulary shared by `kinship`, `retrieval`, `sweep`,
`compose`, and `radius`:

  * `Scope` / `scope_argv` — which roots a question covers, where one bare path
    is one root rather than an iterable of characters.
  * `Region` — a span of the corpus, and (Python-only) the bytes it points at.
  * `Kin` — rows *plus how the answer was produced*, so a caller can tell
    "nearest of three" from "nearest of twenty thousand".
  * `run` — invoke one verb of `relate` or `irregex`, returning its NDJSON rows
    and the stderr summary record the CLI shows a human.

Nothing here computes kinship. Distances, grades, and attribution are the
kernel's; this layer only carries them across the process boundary with their
provenance intact.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import os
from pathlib import Path
from typing import TYPE_CHECKING

from . import engine
from .grade import Channel, Grade


if TYPE_CHECKING:
    from collections.abc import Iterable


# Corpus analytics sweep the whole tree, so they are budgeted like an index
# build rather than like a grep. Warm answers land in milliseconds; this ceiling
# only has to cover a cold live rebuild of the kinship view.
CORPUS_TIMEOUT = 120.0

# The population field each verb reports in its stderr summary record. Verbs
# count different units (files, sketches, function fragments), so `Kin.scored`
# reads whichever one the verb actually measured.
_POPULATION_KEYS = ("files", "sketches", "fragments", "indexed_files")


type Scope = str | os.PathLike[str] | Iterable[str | os.PathLike[str]]


def scope_argv(roots: Scope) -> list[str]:
    """Normalize a scope — one path, or any iterable of them — into root arguments. A bare `str`/`PathLike` is one root, never an iterable of characters."""
    if isinstance(roots, str | os.PathLike):
        return [os.fspath(roots)]
    return [os.fspath(r) for r in roots]


def shape_argv(
    *,
    top: int = 0,
    min_grade: Grade | str | None = None,
    no_index: bool = False,
) -> list[str]:
    """The flag trio every kinship verb shares: how many rows, what floor, and whether to refuse the warm tier."""
    argv: list[str] = []
    if top:
        argv += ["--top", str(top)]
    if min_grade is not None:
        argv += ["--min-grade", Grade(min_grade).value]
    if no_index:
        argv.append("--no-index")
    return argv


def run(
    tool: str,
    verb: str,
    argv: Sequence[str],
    roots: Scope = (),
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = CORPUS_TIMEOUT,
) -> tuple[list[dict[str, object]], dict[str, object]]:
    """Run one `relate`/`irregex` verb under `--json`; return its rows and its stderr summary record.

    The two streams carry different things and both matter: stdout is the answer,
    stderr is what the answer was drawn from. A CLI user reads the second with
    their eyes, so returning it here is what keeps a program from being told less
    than a human would be.

    Exit codes are rg-shaped, so 1 means *no rows* rather than *no answer* — a
    corpus with no kin above the floor, or a pattern nothing matches. That is a
    result the caller asked for, so it returns empty; only a genuine 2 raises.
    """
    out = engine.run_verb(
        tool,
        [verb, *argv, "--json", *scope_argv(roots)],
        cwd=cwd,
        timeout=timeout,
        ok_codes=(0, 1),
    )
    return engine.ndjson_rows(out.stdout), engine.diagnostic(out.stderr)


@dataclass(frozen=True, slots=True)
class Region:
    """A span of one file — a function fragment, a match window, or a whole unit. `headline` is the declaration line when the engine identified one; `distance` is set only when the region was returned as a ranked hit."""

    path: str
    line_start: int
    line_end: int
    headline: str = ""
    distance: float | None = None

    @property
    def lines(self) -> int:
        """Lines spanned, inclusive."""
        return self.line_end - self.line_start + 1

    def read(self, *, cwd: str | os.PathLike[str] | None = None) -> str:
        """The region's actual source text, read from the file right now.

        The engine returns coordinates, which is all a terminal needs — its reader
        goes and looks. A program cannot, so this closes the loop: `concepts` and
        `family` hand back regions, and consolidating them means having the code.
        Paths are corpus-relative, so pass the same `cwd` the query used.
        """
        root = Path(cwd) if cwd is not None else Path()
        text = (root / self.path).read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines(keepends=True)
        return "".join(lines[max(0, self.line_start - 1) : self.line_end])

    def __str__(self) -> str:
        """`path:start-end`, the shape an editor or a report wants."""
        return f"{self.path}:{self.line_start}-{self.line_end}"


def region(row: dict[str, object]) -> Region:
    """Decode a `{path, line_start, line_end, headline?, distance?}` span."""
    return Region(
        path=engine.as_str(row, "path"),
        line_start=engine.as_int(row, "line_start"),
        line_end=engine.as_int(row, "line_end"),
        headline=engine.as_str(row, "headline"),
        distance=engine.as_float(row, "distance"),
    )


def graded(row: dict[str, object], channel: Channel, score: float) -> Grade:
    """The engine's own grade for a row, or this channel's band for `score` when an older binary omitted the field. Zig stays the calibration authority; this only keeps a version-skewed row typed."""
    from .grade import grade_of

    reported = row.get("grade")
    return Grade(reported) if isinstance(reported, str) else grade_of(channel, score)


def merge_paths(*streams: Iterable[str]) -> tuple[str, ...]:
    """Concatenate path streams, keeping first-seen order and dropping repeats — how a multi-section report collapses into one reading order."""
    return tuple(dict.fromkeys(p for stream in streams for p in stream))


class Kin[R](Sequence[R]):
    """Kinship rows plus how the answer was produced.

    Iterate, index, and slice it like the list it wraps; read `scored` /
    `source` / `elapsed_ms` for the provenance the CLI prints to stderr and a
    program otherwise cannot see. Rows arrive strongest-first, so `kin[0].grade`
    is the verdict on the whole answer.
    """

    __slots__ = ("channel", "elapsed_ms", "rows", "scored", "source")

    def __init__(
        self,
        rows: Iterable[R],
        *,
        channel: Channel,
        diagnostic: dict[str, object] | None = None,
    ) -> None:
        """Wrap `rows`, lifting provenance out of the verb's stderr summary record."""
        report = diagnostic or {}
        self.rows: tuple[R, ...] = tuple(rows)
        self.channel = channel
        self.scored: int | None = next(
            (engine.as_int(report, key) for key in _POPULATION_KEYS if key in report), None
        )
        source = report.get("source")
        self.source: str | None = source if isinstance(source, str) else None
        self.elapsed_ms: float | None = engine.as_float(report, "ms") or engine.as_float(
            report, "query_ms"
        )

    @property
    def warm(self) -> bool:
        """Whether a persisted artifact served this answer (rather than a live build). Never affects the rows — warm and live answers are byte-identical."""
        return self.source is not None and self.source != "live"

    def at_least(self, floor: Grade | str) -> tuple[R, ...]:
        """Rows whose grade meets `floor`. Prefer the `min_grade=` argument, which withholds them engine-side instead of shipping bytes you discard."""
        bar = Grade(floor)
        return tuple(r for r in self.rows if getattr(r, "grade", Grade.NONE).meets(bar))

    def __len__(self) -> int:
        """Number of rows."""
        return len(self.rows)

    def __getitem__(self, index: int | slice) -> R | tuple[R, ...]:
        """Index or slice the rows."""
        return self.rows[index]

    def __eq__(self, other: object) -> bool:
        """Equal to any sequence with the same rows, so a `Kin` compares against a plain list."""
        if isinstance(other, Kin):
            return self.rows == other.rows
        return list(self.rows) == list(other) if isinstance(other, Sequence) else NotImplemented

    # Defining __eq__ drops the inherited __hash__ by language rule; a Kin carries
    # a mutable row sequence and is deliberately unhashable.

    def __repr__(self) -> str:
        """`Kin(3 rows, channel=copies, scored=21095, source=atlas)`."""
        parts = [f"{len(self.rows)} rows", f"channel={self.channel}"]
        if self.scored is not None:
            parts.append(f"scored={self.scored}")
        if self.source is not None:
            parts.append(f"source={self.source}")
        return f"Kin({', '.join(parts)})"
