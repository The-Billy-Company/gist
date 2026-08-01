"""Five parameter families, not seventeen argument lists (ADR-377).

`[analytic.params]` in the contract declares one struct per *kind* of question, so
a caller learns `Kinship` once instead of a bespoke argument list per verb, and
`answer()` can check the family a verb takes before it dispatches.

Two constraints shape every family here:

  * **A threshold of zero is a measurement.** `max_distance=0.0` means
    byte-identical only, so "unset" cannot be spelled as a zero — presence rides
    a flag bit instead.
  * **Text is borrowed, not copied.** `lower` returns the struct pointer *and* the
    buffers it points at; the caller keeps those alive across the call, because
    the kernel reads them in place.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, ClassVar, Protocol

from ..contract import table


if TYPE_CHECKING:
    from collections.abc import Sequence

    from cffi import FFI


# `[analytic]` flag bits (include/irregex.h). Presence bits exist because a
# threshold of 0.0 is a measurement, not an absence.
_HAS_MAX_DISTANCE, _HAS_MIN_ECHO = 1 << 0, 1 << 1
_NO_INDEX, _FIXED, _IGNORE_CASE = 1 << 2, 1 << 3, 1 << 4
_MATCH_ALL, _BY_PATTERN, _BY_FILE, _DISTINCT = 1 << 5, 1 << 6, 1 << 7, 1 << 8


def _ordinal(enum: str, value: object) -> int:
    """A contract label to its wire ordinal, read off the generated enum table so no ordinal is restated here."""
    labels = table.ENUMS[enum]
    if value is None:
        return 0
    text = str(value)
    if text not in labels:
        msg = f"{enum} has no variant {text!r}; the contract declares {labels}"
        raise ValueError(msg)
    return labels.index(text)


class Params(Protocol):
    """One parameter family, able to lower itself into its C struct."""

    family: ClassVar[str]

    def lower(self, ffi: FFI) -> tuple[object, tuple[object, ...]]:
        """The struct pointer plus the buffers it points at, which the caller must keep alive across the call."""
        ...


def _text(ffi: FFI, value: str | None) -> tuple[object, int, tuple[object, ...]]:
    """A str as `(const uint8_t *, len, keepalive)`. cffi's trailing NUL is harmless — `len` is authoritative."""
    if value is None:
        return (ffi.NULL, 0, ())
    raw = value.encode()
    buf = ffi.new("uint8_t[]", raw)
    return (buf, len(raw), (buf,))


def _texts(ffi: FFI, values: Sequence[str]) -> tuple[object, int, tuple[object, ...]]:
    """A pattern list as `irregex_text[]` plus every buffer it borrows."""
    if not values:
        return (ffi.NULL, 0, ())
    bufs = [ffi.new("uint8_t[]", v.encode()) for v in values]
    array = ffi.new("irregex_text[]", len(values))
    for slot, buf, value in zip(array, bufs, values, strict=True):
        slot.ptr, slot.len = buf, len(value.encode())
    return (array, len(values), (array, *bufs))


@dataclass(frozen=True, slots=True)
class Kinship:
    """similar · dups · clusters · echoes · concepts · fragments · distinct. `target=None` is the corpus-wide sweep."""

    family: ClassVar[str] = "kinship"

    target: str | None = None
    channel: str | None = None
    unit: str | None = None
    max_distance: float | None = None
    min_echo: float | None = None
    min_grade: str | None = None
    min_size: int = 0
    min_lines: int = 0
    top: int = 0
    no_index: bool = False
    distinct: bool = False

    def lower(self, ffi: FFI) -> tuple[object, tuple[object, ...]]:
        """Lower into `irregex_kinship_params`."""
        ptr, length, keep = _text(ffi, self.target)
        flags = (
            (_HAS_MAX_DISTANCE if self.max_distance is not None else 0)
            | (_HAS_MIN_ECHO if self.min_echo is not None else 0)
            | (_NO_INDEX if self.no_index else 0)
            | (_DISTINCT if self.distinct else 0)
        )
        return (
            ffi.new(
                "irregex_kinship_params *",
                {
                    "struct_size": ffi.sizeof("irregex_kinship_params"),
                    "flags": flags,
                    "target": ptr,
                    "target_len": length,
                    "channel": _ordinal("channel", self.channel),
                    "unit": _ordinal("unit", self.unit),
                    "max_distance": self.max_distance or 0.0,
                    "min_echo": self.min_echo or 0.0,
                    "min_grade": _ordinal("grade", self.min_grade),
                    "min_size": self.min_size,
                    "min_lines": self.min_lines,
                    "top": self.top,
                },
            ),
            keep,
        )


@dataclass(frozen=True, slots=True)
class Retrieval:
    """recall · pack · quote — free text priced against the corpus."""

    family: ClassVar[str] = "retrieval"

    query: str
    top: int = 0

    def lower(self, ffi: FFI) -> tuple[object, tuple[object, ...]]:
        """Lower into `irregex_retrieval_params`."""
        ptr, length, keep = _text(ffi, self.query)
        return (
            ffi.new(
                "irregex_retrieval_params *",
                {
                    "struct_size": ffi.sizeof("irregex_retrieval_params"),
                    "flags": 0,
                    "query": ptr,
                    "query_len": length,
                    "top": self.top,
                    "reserved": 0,
                },
            ),
            keep,
        )


@dataclass(frozen=True, slots=True)
class Sweep:
    """patterns · pattern_counts — N patterns, one walk, exact per-pattern attribution."""

    family: ClassVar[str] = "sweep"

    patterns: tuple[str, ...]
    under: str | None = None
    top: int = 0
    fixed: bool = False
    ignore_case: bool = False
    by: str | None = None

    def lower(self, ffi: FFI) -> tuple[object, tuple[object, ...]]:
        """Lower into `irregex_sweep_params`. `by` selects the engine-side tally axis (`pattern` · `file`); unset streams hits."""
        array, count, keep = _texts(ffi, self.patterns)
        under, under_len, under_keep = _text(ffi, self.under)
        flags = (
            (_FIXED if self.fixed else 0)
            | (_IGNORE_CASE if self.ignore_case else 0)
            | (_BY_PATTERN if self.by == "pattern" else 0)
            | (_BY_FILE if self.by == "file" else 0)
        )
        return (
            ffi.new(
                "irregex_sweep_params *",
                {
                    "struct_size": ffi.sizeof("irregex_sweep_params"),
                    "flags": flags,
                    "patterns": array,
                    "npatterns": count,
                    "under": under,
                    "under_len": under_len,
                    "top": self.top,
                    "reserved": 0,
                },
            ),
            (*keep, *under_keep),
        )


@dataclass(frozen=True, slots=True)
class Compose:
    """context · family · provenance · blast — an exact pattern set narrows, compression reasons inside it."""

    family: ClassVar[str] = "compose"

    text: str | None = None
    patterns: tuple[str, ...] = ()
    max_distance: float | None = None
    min_echo: float | None = None
    budget: int = 0
    top: int = 0
    match_all: bool = False
    fixed: bool = False
    ignore_case: bool = False

    def lower(self, ffi: FFI) -> tuple[object, tuple[object, ...]]:
        """Lower into `irregex_compose_params`."""
        text, text_len, text_keep = _text(ffi, self.text)
        array, count, keep = _texts(ffi, self.patterns)
        flags = (
            (_HAS_MAX_DISTANCE if self.max_distance is not None else 0)
            | (_HAS_MIN_ECHO if self.min_echo is not None else 0)
            | (_MATCH_ALL if self.match_all else 0)
            | (_FIXED if self.fixed else 0)
            | (_IGNORE_CASE if self.ignore_case else 0)
        )
        return (
            ffi.new(
                "irregex_compose_params *",
                {
                    "struct_size": ffi.sizeof("irregex_compose_params"),
                    "flags": flags,
                    "text": text,
                    "text_len": text_len,
                    "patterns": array,
                    "npatterns": count,
                    "max_distance": self.max_distance or 0.0,
                    "min_echo": self.min_echo or 0.0,
                    "budget": self.budget,
                    "top": self.top,
                },
            ),
            (*text_keep, *keep),
        )


@dataclass(frozen=True, slots=True)
class Rank:
    """rank — the definition-first view, the one exact-plane verb whose answer is analytic rows."""

    family: ClassVar[str] = "rank"

    pattern: str
    top: int = 0
    fixed: bool = False
    ignore_case: bool = False

    def lower(self, ffi: FFI) -> tuple[object, tuple[object, ...]]:
        """Lower into `irregex_rank_params`."""
        ptr, length, keep = _text(ffi, self.pattern)
        flags = (_FIXED if self.fixed else 0) | (_IGNORE_CASE if self.ignore_case else 0)
        return (
            ffi.new(
                "irregex_rank_params *",
                {
                    "struct_size": ffi.sizeof("irregex_rank_params"),
                    "flags": flags,
                    "pattern": ptr,
                    "pattern_len": length,
                    "top": self.top,
                    "reserved": 0,
                },
            ),
            keep,
        )
