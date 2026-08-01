"""The subprocess tier, rebuilt as rows (ADR-377).

The CLI is the fallback rung, and it will stay one: it is the only transport that
works against a library this Python was never built beside, and its answer is the
same answer. What changed is that it no longer has its own decoder. `rows()`
lifts a `--json` object into the same positional `Row` the C cursor produces, so
the seventeen hand-written NDJSON readers collapse into one schema walk.

Two things the wire cannot express by itself:

  * **A missing key is an absent field, not a zero.** The presence mask is
    reconstructed from which keys the object actually carries, which is what lets
    a `distance` of 0.0 keep meaning *identical* on this tier too.
  * **A label the table does not know stays unknown.** An enum label is resolved
    to its ordinal through the contract; an unrecognized one is handed on as an
    out-of-range ordinal so the decoder reports it rather than guessing.

`_KEYS` is the only place CLI spelling is written down. It exists because the
human-facing JSON was named for a reader (`bytes`, `in`) before the row schemas
were named for a decoder; every entry is a rename, never a reshaping.
"""

from __future__ import annotations

import os
from typing import TYPE_CHECKING, Final

from ..contract import table
from ..contract.table import Tag
from . import shell
from .analytic import Stats, rows_of
from .decode import ABSENT, Row


if TYPE_CHECKING:
    from collections.abc import Iterable, Mapping, Sequence

    from .analytic import Rows


#: `(schema, field) → the key the CLI prints`. Only genuine spelling differences.
_KEYS: Final[dict[tuple[str, str], str]] = {
    ("reference", "enclosing"): "in",
    ("ranked", "line_number"): "line",
    ("ranked", "snippet"): "text",
}

#: Tags whose absence on the wire reads as empty rather than unmeasured.
_COLLECTIONS: Final = frozenset({Tag.TEXTS, Tag.ROWS})

#: Population counters, in the order a verb is most likely to have measured one.
_POPULATION: Final = ("files", "sketches", "fragments", "indexed_files")


def rows(schema: int, objects: Iterable[Mapping[str, object]]) -> list[Row]:
    """Lift `--json` objects into positional rows of `schema`."""
    return [_row(schema, obj) for obj in objects]


def _row(schema: int, obj: Mapping[str, object]) -> Row:
    """One object, read against the schema's declared field order. A key the object omits is the absent bit — except for a collection, where JSON has no way to distinguish *unmeasured* from *empty* and the empty reading is the true one (`pack` prints no `patterns` because nothing narrowed the pick)."""
    name = table.schema_name(schema)
    values = [
        _value(f.tag, f.nested, raw)
        if (raw := obj.get(_KEYS.get((name, f.name), f.name))) is not None
        else ()
        if f.tag in _COLLECTIONS
        else ABSENT
        for f in table.fields(schema)
    ]
    return Row(schema, tuple(values))


def _value(tag: Tag, nested: int, raw: object) -> object:
    """One JSON value into the shape the decoder expects for `tag`."""
    match tag:
        case Tag.ENUM:
            labels = table.ENUMS.get(table.ENUM_BY_ID.get(nested, ""), ())
            # An unmodelled label becomes an out-of-range ordinal, which the
            # decoder surfaces as `Unknown` — the same treatment a newer library's
            # ordinal gets, rather than a second, softer failure mode here.
            return labels.index(raw) if raw in labels else len(labels)
        case Tag.ROWS:
            return rows(nested, raw if isinstance(raw, list) else [raw])
        case Tag.TEXTS:
            return [str(v) for v in raw] if isinstance(raw, list) else [str(raw)]
        case _:
            return raw


def answer(
    tool: str,
    verb: str,
    argv: Sequence[str],
    *,
    schema: int,
    roots: Sequence[str] = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float,
) -> Rows:
    """Run one CLI verb under `--json` and present its output as `Rows`.

    Exit 1 is rg-shaped — *no rows*, not *no answer* — so it returns empty; only
    a genuine failure raises. The stderr summary record carries what no row can
    (`foreign`, the population, which tier answered), so it becomes `Stats` here
    instead of being read by eye.
    """
    out = shell.run_verb(
        tool,
        [verb, *argv, "--json", *(os.fspath(r) for r in roots)],
        cwd=cwd,
        timeout=timeout,
        ok_codes=(0, 1),
    )
    parsed = shell.ndjson_rows(out.stdout)
    return rows_of(rows(schema, parsed), stats(shell.diagnostic(out.stderr), len(parsed)))


def stats(report: Mapping[str, object], count: int) -> Stats:
    """The verb's stderr summary record as answer-level stats."""
    source = report.get("source")
    return Stats(
        source=source if isinstance(source, str) else "cold",
        elapsed_ms=shell.as_float(report, "ms") or shell.as_float(report, "query_ms") or 0.0,
        files_considered=next(
            (shell.as_int(report, key) for key in _POPULATION if key in report), 0
        ),
        refreshed=shell.as_int(report, "refreshed"),
        foreign=shell.as_int(report, "foreign"),
        omitted=shell.as_int(report, "omitted"),
        rows=count,
    )
