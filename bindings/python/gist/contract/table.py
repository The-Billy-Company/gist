"""The analytic plane's row-schema table, indexed for a decoder to walk (ADR-377).

`../schema.gen.py` is lowered from `contract/search_api.toml` by
`tools/build_schema_tables.py` and rewritten in place on every `make gen`, so it
stays exactly where the generator puts it. A dot in a filename is not a legal
module name, which is why the tables arrive through a file loader rather than an
`import` — the alternative is a hand-copied second table, the drift this plane
exists to remove.

What this module adds is the indexes the generated file deliberately does not
carry: value tags as an enum whose ordinals are *read off* `TAGS` (a renumbered
tag becomes an import-time failure instead of a mis-decode), fields as named
tuples, and name → id lookups both ways. Every schema fact in the package enters
here.
"""

from __future__ import annotations

from enum import IntEnum
import importlib.util
from pathlib import Path
from typing import TYPE_CHECKING, Final, NamedTuple


if TYPE_CHECKING:
    from types import ModuleType


def _generated() -> ModuleType:
    """Execute the generated table beside the package root."""
    path = Path(__file__).resolve().parent.parent / "schema.gen.py"
    spec = importlib.util.spec_from_file_location(f"{__package__}._generated", path)
    if spec is None or spec.loader is None:
        msg = f"generated row-schema table missing or unloadable at {path}"
        raise ImportError(msg)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_GEN: Final = _generated()

#: Digest of the WHOLE schema table this decoder was generated from. The engine
#: reports its own through `irregex_schema_digest`; disagreement is drift.
DIGEST: Final[str] = _GEN.DIGEST
TAGS: Final[tuple[str, ...]] = _GEN.TAGS
MAX_FIELDS: Final[int] = _GEN.MAX_FIELDS
ENUMS: Final[dict[str, tuple[str, ...]]] = _GEN.ENUMS
ENUM_BY_ID: Final[dict[int, str]] = _GEN.ENUM_BY_ID
SCHEMAS: Final[dict[int, tuple[str, tuple[tuple[str, int, int, bool], ...]]]] = _GEN.SCHEMAS
VERBS: Final[dict[str, tuple[int, str, int, bool]]] = _GEN.VERBS


class Tag(IntEnum):
    """A field's wire shape. `TEXTS` carries `irregex_text[]`, `ROWS` nests whole rows."""

    TEXT = 0
    I64 = 1
    F64 = 2
    BOOL = 3
    ENUM = 4
    TEXTS = 5
    ROWS = 6


if tuple(tag.name.lower() for tag in Tag) != TAGS:
    msg = f"value tags renumbered in the contract: {TAGS} — regenerate this mirror"
    raise ImportError(msg)


class Field(NamedTuple):
    """One declared field. `nested` is a schema id for `ROWS`, an enum id for `ENUM`, else 0."""

    name: str
    tag: Tag
    nested: int
    optional: bool


SCHEMA_ID: Final[dict[str, int]] = {name: sid for sid, (name, _) in SCHEMAS.items()}

_FIELDS: Final[dict[int, tuple[Field, ...]]] = {
    sid: tuple(Field(n, Tag(t), nested, opt) for n, t, nested, opt in spec)
    for sid, (_, spec) in SCHEMAS.items()
}


def fields(schema: int) -> tuple[Field, ...]:
    """The declared fields of `schema`, in the order its values arrive."""
    try:
        return _FIELDS[schema]
    except KeyError:
        msg = f"unknown row schema id {schema}; this table declares 1..{len(SCHEMAS)}"
        raise KeyError(msg) from None


def schema_name(schema: int) -> str:
    """The contract's name for `schema` — what a drift report has to be able to say."""
    return SCHEMAS[schema][0] if schema in SCHEMAS else f"schema#{schema}"


def verb_schema(verb: str) -> int:
    """The row schema `verb` streams. A verb reusing a schema costs no new surface."""
    return VERBS[verb][2]
