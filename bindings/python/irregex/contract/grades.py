"""The kinship calibration, importable — a Python mirror of `src/surface/cli/grade.zig`.

A distance is not an answer. `similar` returning 0.7813 *looks* like a result,
but it sits past the line where kinship stops meaning "related" and starts
meaning "both files are Zig". The CLI tells a human so on stderr; a library
caller cannot read stderr, so the same calibration lives here as values:

  * `Channel` — which kinship question is being asked, named for what it finds
    rather than the metric behind it. Both vocabularies parse (`--as copies` and
    `--lens bytes` are one channel), so a caller who learned the CLI is never
    stranded.
  * `Grade` — where a score falls on that channel's bands, so a caller can tell
    a real twin from statistical background without memorizing cut points.

Polarity differs by channel and is load-bearing: `copies`/`shapes`/`any` score a
DISTANCE (lower is closer) while `twins` scores a GAP (higher is stronger), so
one threshold spelling for both would silently invert. `score()` and
`grade_of()` make that explicit rather than remembered.

The bands are the engine's, not a second opinion: `tests/test_grade_parity.py`
reads `grade.zig` and asserts every cut point and alias matches.
"""

from __future__ import annotations

from enum import StrEnum
import math


class Channel(StrEnum):
    """Which kinship question a verb is answering."""

    COPIES = "copies"  # LZJD distance over raw bytes — copy-paste and its drift
    TWINS = "twins"  # bytes − structure — same skeleton, renamed vocabulary
    SHAPES = "shapes"  # normalized-structure silhouette — shared skeleton
    ANY = "any"  # min(copies, shapes) — close in EITHER channel counts

    @property
    def metric(self) -> str:
        """The underlying metric's name — also the legacy `--lens` spelling."""
        return _METRIC[self]

    @property
    def higher_is_stronger(self) -> bool:
        """True for gap channels (`twins`), False for distance channels."""
        return self is Channel.TWINS

    def score(self, byte_distance: float, structure_distance: float) -> float:
        """This channel's score from a pair's two measured distances — the one definition of what each channel means. `copies` ignores `structure_distance`."""
        match self:
            case Channel.COPIES:
                return byte_distance
            case Channel.SHAPES:
                return structure_distance
            case Channel.TWINS:
                return byte_distance - structure_distance
            case _:
                return min(byte_distance, structure_distance)

    @classmethod
    def parse(cls, value: str | Channel) -> Channel:
        """Accept the user-facing vocabulary *and* the metric names it replaced (`bytes`→`copies`, `echo`→`twins`, `structure`→`shapes`, `fused`→`any`). An unknown spelling is a loud `ValueError`, never a silent fallback to the default channel."""
        if isinstance(value, Channel):
            return value
        try:
            return cls(value)
        except ValueError:
            pass
        if (aliased := _ALIASES.get(value)) is not None:
            return aliased
        known = ", ".join([*(c.value for c in cls), *_ALIASES])
        msg = f"unknown kinship channel {value!r}; use one of {known}"
        raise ValueError(msg)


_METRIC: dict[Channel, str] = {
    Channel.COPIES: "bytes",
    Channel.TWINS: "echo",
    Channel.SHAPES: "structure",
    Channel.ANY: "fused",
}
_ALIASES: dict[str, Channel] = {metric: channel for channel, metric in _METRIC.items()}


class Grade(StrEnum):
    """Where a score falls on its channel's calibrated bands, strongest first."""

    IDENTICAL = "identical"  # distance channels only: same bytes or same skeleton
    STRONG = "strong"  # a real relation — the `--max-distance 0.25` band
    MODERATE = "moderate"  # related, worth a look, not a fork
    WEAK = "weak"  # past "same language, same house style"
    NONE = "none"  # background; reporting this as a result is reporting noise

    @property
    def rank(self) -> int:
        """Position in the strongest-first order (0 = `identical`)."""
        return _ORDER.index(self)

    def meets(self, floor: Grade) -> bool:
        """Is this grade at least as strong as `floor`? The `min_grade` predicate."""
        return self.rank <= Grade(floor).rank


_ORDER: tuple[Grade, ...] = (
    Grade.IDENTICAL,
    Grade.STRONG,
    Grade.MODERATE,
    Grade.WEAK,
    Grade.NONE,
)

# Distance cut points are the ones the tool documents and defaults to: 0.05
# "near-exact copy", 0.25 "same thing, drifted" (the dups/clusters admission
# default), 0.50 "shares style, not substance". Gap cut points scale from the
# 0.15 `--min-echo` floor, below which a structure-close pair is sample noise.
_DISTANCE_BANDS: tuple[tuple[float, Grade], ...] = (
    (0.05, Grade.IDENTICAL),
    (0.25, Grade.STRONG),
    (0.50, Grade.MODERATE),
    (0.75, Grade.WEAK),
)
# A gap is never `identical`: two byte-identical files share every fingerprint,
# so their gap is zero — the weakest twin evidence there is, not the strongest.
_GAP_BANDS: tuple[tuple[float, Grade], ...] = (
    (0.45, Grade.STRONG),
    (0.30, Grade.MODERATE),
    (0.15, Grade.WEAK),
)


def grade_of(channel: Channel | str, score: float) -> Grade:
    """Grade `score` on `channel`'s calibrated bands. NaN grades as `none`."""
    resolved = Channel.parse(channel)
    if math.isnan(score):
        return Grade.NONE
    if resolved.higher_is_stronger:
        return next((g for floor, g in _GAP_BANDS if score >= floor), Grade.NONE)
    return next((g for ceiling, g in _DISTANCE_BANDS if score <= ceiling), Grade.NONE)
