"""One decoder for every analytic row the kernel can emit (ADR-377).

The engine no longer hands Python a verb-shaped JSON object; it hands back a
positional `irregex_value` array plus a schema id, and `contract/table.py` says
what the positions mean. So this module is the *whole* decode layer — seventeen
verbs, twenty-two row types, one walk — and adding a verb to the contract costs
zero Python.

Three things here are load-bearing rather than plumbing:

  * **Absent is not zero.** A row carries a presence mask; bit *i* clear means
    field *i* was never measured. For `distance` that distinction is the whole
    answer, because `0.0` means *identical*. `Row.masked` folds the mask into
    `ABSENT`, and an absent optional field falls to its declared default — an
    absent *required* field is a kernel bug and raises.
  * **An unknown enum ordinal stays unknown.** A library newer than this table
    can send an ordinal past the end of `ENUMS[name]`. Guessing the nearest
    variant would silently mislabel a grade, so the field decodes to `Unknown`,
    which compares equal to nothing and prints as `grade#7`.
  * **Row types are grown from the table, not written out.** `record` resolves a
    schema to a frozen `slots=True` dataclass built from its fields; `mixin`
    grafts domain behavior onto one by name. A verb module that already owns a
    public row type registers it with `bind`, which fails at import if its
    fields have drifted from the contract.
"""

from __future__ import annotations

from dataclasses import (
    MISSING,
    dataclass,
    field as dc_field,
    fields as dataclass_fields,
    make_dataclass,
)
from functools import cache
from typing import TYPE_CHECKING, Any, Final

from ..contract import table
from ..contract.table import Tag
from .errors import RowDecodeError


if TYPE_CHECKING:
    from collections.abc import Callable, Iterable, Iterator


class _Absent:
    """The presence mask said this field was never measured."""

    __slots__ = ()

    def __repr__(self) -> str:
        """`ABSENT` — distinguishable from `None`, which a schema may legitimately mean."""
        return "ABSENT"

    def __bool__(self) -> bool:
        """Falsy, so `value or default` reads naturally at a call site."""
        return False


#: Sentinel for a field the presence mask marked absent. Not `None`: an optional
#: field's *declared* default is often `None`, and conflating the two would make
#: "the engine didn't measure it" indistinguishable from "it measured nothing".
ABSENT: Final = _Absent()


@dataclass(frozen=True, slots=True)
class Unknown:
    """An enum ordinal this binding's table does not name — a library ahead of the generated mirror. Kept as a value so the row still decodes and the gap is visible instead of guessed."""

    enum: str
    ordinal: int

    def __str__(self) -> str:
        """`grade#7`."""
        return f"{self.enum}#{self.ordinal}"

    def meets(self, _floor: object) -> bool:
        """Never satisfies a floor — an unnamed grade cannot be claimed to clear a bar."""
        return False


@dataclass(frozen=True, slots=True)
class Row:
    """One raw analytic row: a schema id and its values in declared order.

    The intermediate representation both transports produce — the native cursor
    from an `irregex_row`, the subprocess tier from an NDJSON object — so the
    decoder below is the only code that knows what a row *means*.
    """

    schema: int
    values: tuple[object, ...]

    @classmethod
    def masked(cls, schema: int, values: Iterable[object], present: int) -> Row:
        """Build a row from a value array and the engine's presence mask (bit *i* set = field *i* measured)."""
        return cls(schema, tuple(v if present >> i & 1 else ABSENT for i, v in enumerate(values)))


@cache
def _typed() -> dict[str, type[str]]:
    """Enum ids resolve to the package's own calibrated types where one exists, so a decoded grade is comparable (`row.grade.meets("strong")`) rather than a bare string; enums with no Python counterpart keep their contract label. Resolved on first use because those types live in packages that stand on this one."""
    from ..contract.grades import Channel, Grade
    from ..exact.request import RankKind

    return {"grade": Grade, "channel": Channel, "rank_kind": RankKind}


_ANNOTATION: Final[dict[Tag, str]] = {
    Tag.TEXT: "str",
    Tag.I64: "int",
    Tag.F64: "float",
    Tag.BOOL: "bool",
    Tag.ENUM: "str | Unknown",
    Tag.TEXTS: "tuple[str, ...]",
    Tag.ROWS: "tuple[object, ...]",
}

_EMPTY: Final = frozenset({Tag.TEXTS, Tag.ROWS})

_MIXINS: dict[str, type] = {}
_BOUND: dict[int, type] = {}
_BOUND_NAMES: set[str] = set()
# Per-bound-class stand-ins for an absent field, where the public type predates
# this plane and spells absence as `""` rather than as a default.
_ABSENT_AS: dict[int, dict[str, object]] = {}


def mixin[C: type](schema: str) -> Callable[[C], C]:
    """Graft behavior onto the row type generated for `schema`.

    The decorated class becomes a base of the generated dataclass, so properties
    and dunders land on the row without anyone restating its fields. Declare it
    `__slots__ = ()` — the generated dataclass is `slots=True` and a base with a
    `__dict__` would silently give that away. Must be applied before the first
    row of that schema decodes.
    """

    def register(cls: C) -> C:
        if schema in _BOUND_NAMES or schema in _MIXINS:
            msg = f"row behavior for {schema!r} is already registered"
            raise RuntimeError(msg)
        _MIXINS[schema] = cls
        return cls

    return register


def bind[C: type](
    schema: str,
    *,
    extra: tuple[str, ...] = (),
    absent: dict[str, object] | None = None,
) -> Callable[[C], C]:
    """Adopt a hand-declared frozen dataclass as `schema`'s row type.

    For the row types that were public API before this plane existed. The
    decorated class must declare every field the schema does — checked here, at
    import, so a contract change is an ImportError rather than a mis-decoded
    field two layers down. Declaration *order* is free: rows are constructed by
    keyword, and these classes chose their argument order for readers years
    before the schemas existed.

    `extra` names fields the schema does not describe (values the *verb* supplies,
    like the pattern text behind a `pattern_id`, or a grade this side calibrates);
    they need defaults, since a decoded row cannot fill them. `absent` gives an
    optional field the stand-in its published type already documents — several of
    these classes spell "not measured" as `""`, and giving them dataclass
    defaults instead would break positional construction for callers that predate
    the plane.
    """
    stand_ins = absent or {}

    def register(cls: C) -> C:
        sid = table.SCHEMA_ID.get(schema)
        if sid is None:
            msg = f"no row schema named {schema!r} in the contract"
            raise ImportError(msg)
        spec = table.fields(sid)
        declared = dataclass_fields(cls)
        names = {f.name for f in declared}
        if names != {f.name for f in spec} | set(extra):
            msg = (
                f"{cls.__name__} has drifted from row schema {schema!r}: "
                f"declares {sorted(names)}, contract says "
                f"{sorted({f.name for f in spec} | set(extra))}"
            )
            raise ImportError(msg)
        defaulted = {
            f.name
            for f in declared
            if f.default is not MISSING or f.default_factory is not MISSING  # type: ignore[misc]
        }
        if unhandled := sorted({f.name for f in spec if f.optional} - defaulted - set(stand_ins)):
            msg = (
                f"{cls.__name__}: optional schema fields need a default or an "
                f"`absent=` stand-in: {unhandled}"
            )
            raise ImportError(msg)
        if strays := sorted(set(extra) - defaulted):
            msg = f"{cls.__name__}: fields outside the schema need defaults: {strays}"
            raise ImportError(msg)
        _BOUND[sid] = cls
        _BOUND_NAMES.add(schema)
        if stand_ins:
            _ABSENT_AS[sid] = stand_ins
        return cls

    return register


def row_type(schema: int) -> type:
    """The frozen dataclass `schema` decodes into — bound, or generated from its fields on first use."""
    if (bound := _BOUND.get(schema)) is not None:
        return bound
    name = table.schema_name(schema)
    spec = table.fields(schema)
    generated = make_dataclass(
        "".join(part.capitalize() for part in name.split("_")),
        [
            (f.name, _ANNOTATION[f.tag], _default(f.tag))
            if f.optional
            else (f.name, _ANNOTATION[f.tag])
            for f in spec
        ],
        bases=(_MIXINS[name],) if name in _MIXINS else (),
        frozen=True,
        slots=True,
        kw_only=True,
        module=__name__,
    )
    generated.__doc__ = f"Row schema {schema} ({name}), grown from contract/search_api.toml."
    _BOUND[schema] = generated
    return generated


def _default(tag: Tag) -> Any:
    """An optional field's stand-in: an empty tuple for a collection, `None` for a scalar. Never a zero, which would be a measurement."""
    return dc_field(default_factory=tuple) if tag in _EMPTY else dc_field(default=None)


def record(row: Row) -> Any:
    """Decode one row into its typed record, recursing through nested row fields.

    Values are read positionally against the schema, so nothing depends on a key
    name surviving a transport. `kw_only` construction means the schema may
    declare an optional field before a required one — as `attribution` does —
    without the field order having to be rearranged to please dataclass rules.
    """
    spec = table.fields(row.schema)
    if len(row.values) != len(spec):
        msg = (
            f"row schema {table.schema_name(row.schema)} declares {len(spec)} fields, "
            f"row carried {len(row.values)} values"
        )
        raise RowDecodeError(msg)
    stand_ins = _ABSENT_AS.get(row.schema, {})
    args: dict[str, object] = {}
    for field, value in zip(spec, row.values, strict=True):
        if value is ABSENT:
            if not field.optional:
                msg = (
                    f"required field {table.schema_name(row.schema)}.{field.name} "
                    f"arrived absent — the presence mask contradicts the contract"
                )
                raise RowDecodeError(msg)
            if field.name in stand_ins:
                args[field.name] = stand_ins[field.name]
            continue
        args[field.name] = _coerce(field.tag, field.nested, value)
    return row_type(row.schema)(**args)


def records(rows: Iterable[Row]) -> Iterator[Any]:
    """Decode a stream of rows lazily."""
    return (record(r) for r in rows)


def _coerce(tag: Tag, nested: int, value: object) -> object:
    """One value into its declared shape. Nested rows recurse; enums resolve through their variant table."""
    match tag:
        case Tag.TEXT:
            return value if isinstance(value, str) else str(value)
        case Tag.I64:
            return int(value)  # type: ignore[arg-type]
        case Tag.F64:
            return float(value)  # type: ignore[arg-type]
        case Tag.BOOL:
            return bool(value)
        case Tag.ENUM:
            return variant(nested, int(value))  # type: ignore[arg-type]
        case Tag.TEXTS:
            return tuple(str(v) for v in value)  # type: ignore[union-attr]
        case Tag.ROWS:
            return tuple(record(r) for r in value)  # type: ignore[union-attr]


def variant(enum: int, ordinal: int) -> str | Unknown:
    """Resolve an enum ordinal to its calibrated Python type, its contract label, or `Unknown` when the library names a variant this table does not."""
    name = table.ENUM_BY_ID.get(enum, f"enum#{enum}")
    labels = table.ENUMS.get(name, ())
    if not 0 <= ordinal < len(labels):
        return Unknown(name, ordinal)
    label = labels[ordinal]
    if (typed := _typed().get(name)) is not None:
        return typed(label)
    return label
