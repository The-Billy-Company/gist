"""The Python calibration must be the Zig calibration, proven from the Zig source.

`irregex/grade.py` is a mirror of `src/kernel/kinship/metric/channel.zig`, and a
mirror is a liability the moment it drifts: a caller filtering on
`min_grade="strong"` would silently mean something different from the same flag
on the CLI. So the oracle here is the kernel source — channel aliases, band cut
points, polarity, and the enum orderings are *parsed out of `channel.zig`* and
compared against the Python values. Nothing is asserted against a number typed
twice.

Calibration lives in the kernel rather than in the renderer because the bands are
a property of the metric: the repetition kernel grades a family edge with the same
cut points the CLI prints. `surface/cli/grade.zig` re-exports them.

If the kernel re-calibrates a band, these fail until the mirror follows. That is
the point.
"""

from __future__ import annotations

from pathlib import Path
import re

import pytest

from irregex.contract.grades import Channel, Grade, grade_of


ZIG = (
    Path(__file__).resolve().parents[3] / "src" / "kernel" / "kinship" / "metric" / "channel.zig"
)

pytestmark = pytest.mark.skipif(not ZIG.is_file(), reason="kernel source not present")


def _source() -> str:
    return ZIG.read_text(encoding="utf-8")


def _enum_members(name: str) -> list[str]:
    """Tag names of `pub const <name> = enum { … }`, in declaration order."""
    body = re.search(rf"pub const {name} = enum \{{(.*?)\n\}};", _source(), re.DOTALL)
    assert body, f"could not locate the {name} enum"
    return re.findall(r"^    (\w+),$", body.group(1), re.MULTILINE)


def _bands(head: str, comparison: str) -> list[tuple[float, str]]:
    """`(cut_point, grade)` pairs from the `of()` arm introduced by `head`, in evaluation order. An arm ends at the next arm's head or at the switch's closing brace, so the final one parses like the rest."""
    arm = re.search(
        rf"\n        {re.escape(head)} => if \(score {comparison}(.*?)\n(?:        \.|    \}})",
        _source(),
        re.DOTALL,
    )
    assert arm, f"could not locate the {head} arm"
    return [
        (float(cut), grade)
        for cut, grade in re.findall(
            r"(\d+\.\d+)\)\s*\.(\w+)", "score " + comparison + arm.group(1)
        )
    ]


def test_channel_tags_and_order_match() -> None:
    assert [c.value for c in Channel] == _enum_members("Channel")


def test_grade_tags_and_strongest_first_order_match() -> None:
    tags = _enum_members("Grade")
    assert [g.value for g in Grade] == tags
    # `meets` is `@intFromEnum(self) <= @intFromEnum(floor)` in Zig, so the
    # declaration order *is* the confidence order.
    assert [Grade(t).rank for t in tags] == list(range(len(tags)))


def test_every_alias_the_kernel_accepts_parses_here() -> None:
    table = re.findall(r'\.\{ "(\w+)", Channel\.(\w+) \}', _source())
    assert len(table) >= len(list(Channel)) * 2, "expected both vocabularies in the parse table"
    for spelling, tag in table:
        assert Channel.parse(spelling) is Channel(tag)
    # And a spelling the kernel rejects is rejected here, loudly rather than by
    # falling back to a default channel.
    with pytest.raises(ValueError, match="unknown kinship channel"):
        Channel.parse("sideways")


def test_metric_names_match_the_kernel() -> None:
    # Scoped to `metric()` on purpose: `quantity()` is a second tag→string
    # switch, and a whole-file scan would compare the two vocabularies.
    arms = re.search(r"pub fn metric.*?\n    \}", _source(), re.DOTALL)
    assert arms, "could not locate metric()"
    found = re.findall(r"\.(\w+) => \"(\w+)\",", arms.group(0))
    assert len(found) == len(list(Channel)), "every channel names its metric"
    for tag, metric in found:
        assert Channel(tag).metric == metric


def test_polarity_matches_the_kernel() -> None:
    arm = re.search(r"([\w., ]+) => \.stronger,", _source())
    assert arm, "could not locate polarity"
    stronger = set(re.findall(r"\.(\w+)", arm.group(1)))
    assert stronger, "the stronger-polarity arm named no channel"
    for channel in Channel:
        assert channel.higher_is_stronger == (channel.value in stronger)


def test_pairwise_and_quantity_match_the_kernel() -> None:
    # `recall` is the one non-pairwise channel, and the kernel says so by
    # excluding it rather than by listing the others.
    excluded = re.search(r"return self != \.(\w+);", _source())
    assert excluded, "could not locate the pairwise predicate"
    for channel in Channel:
        assert channel.pairwise == (channel.value != excluded.group(1))
    # The score column is named for its polarity, and a downstream filter reads
    # that name — so the spellings must match the kernel exactly.
    arms = re.search(r"pub fn quantity.*?\n    \}", _source(), re.DOTALL)
    assert arms, "could not locate quantity()"
    named: dict[str, str] = {}
    for tags, column in re.findall(r"([\w., ]+) => \"(\w+)\",", arms.group(0)):
        for tag in re.findall(r"\.(\w+)", tags):
            named[tag] = column
    assert named, "quantity() named no columns"
    for channel in Channel:
        assert channel.quantity == named[channel.value]


@pytest.mark.parametrize("channel", [Channel.COPIES, Channel.SHAPES, Channel.ANY])
def test_distance_bands_classify_exactly_as_the_kernel(channel: Channel) -> None:
    bands = _bands(".copies, .shapes, .any", "<=")
    assert bands, "no distance bands parsed"
    for index, (cut, grade) in enumerate(bands):
        # The cut point itself is inclusive…
        assert grade_of(channel, cut) is Grade(grade)
        # …and a hair past it falls to the next band.
        assert grade_of(channel, cut + 1e-6) is not Grade(grade)
        # Midway between cuts stays in this band.
        floor = bands[index - 1][0] if index else 0.0
        assert grade_of(channel, (floor + cut) / 2) is Grade(grade)
    assert grade_of(channel, bands[-1][0] + 0.01) is Grade.NONE


def test_gap_bands_invert_and_never_reach_identical() -> None:
    bands = _bands(".twins", ">=")
    assert bands, "no gap bands parsed"
    for cut, grade in bands:
        assert grade_of(Channel.TWINS, cut) is Grade(grade)
        assert grade_of(Channel.TWINS, cut - 1e-6) is not Grade(grade)
    assert grade_of(Channel.TWINS, bands[-1][0] - 0.01) is Grade.NONE
    # Byte-identical files share every fingerprint, so their gap is zero — the
    # weakest twin evidence there is, not the strongest.
    assert grade_of(Channel.TWINS, 0.0) is Grade.NONE
    assert Grade.IDENTICAL not in {Grade(g) for _, g in bands}


def test_recall_gain_bands_rise_and_do_reach_identical() -> None:
    bands = _bands(".recall", ">=")
    assert bands, "no gain bands parsed"
    for cut, grade in bands:
        assert grade_of(Channel.RECALL, cut) is Grade(grade)
        assert grade_of(Channel.RECALL, cut - 1e-6) is not Grade(grade)
    assert grade_of(Channel.RECALL, bands[-1][0] - 0.01) is Grade.NONE
    # Unlike a gap, a gain *can* mean identical: text the corpus quotes back
    # verbatim costs almost nothing to describe.
    assert Grade.IDENTICAL in {Grade(g) for _, g in bands}
    # And a gain shares nothing with a distance — the same 0.20 that is a strong
    # byte relation is background here, which is why they are separate channels.
    assert grade_of(Channel.RECALL, 0.20) is Grade.NONE
    assert grade_of(Channel.COPIES, 0.20) is Grade.STRONG


def test_channel_score_composes_the_two_measured_distances() -> None:
    # The kernel's `score(bytes, structure)` switch, transcribed as behavior.
    assert Channel.COPIES.score(0.3, 0.9) == 0.3
    assert Channel.SHAPES.score(0.3, 0.9) == 0.9
    assert Channel.TWINS.score(0.9, 0.3) == pytest.approx(0.6)
    assert Channel.ANY.score(0.3, 0.9) == 0.3
    # A pairwise call on the retrieval channel has no answer to give, and says so
    # as NaN — which grades as background rather than as a relation.
    assert grade_of(Channel.RECALL, Channel.RECALL.score(0.3, 0.9)) is Grade.NONE


def test_nan_grades_as_background_not_as_a_relation() -> None:
    assert grade_of(Channel.COPIES, float("nan")) is Grade.NONE
    assert grade_of(Channel.TWINS, float("nan")) is Grade.NONE


def test_meets_is_a_floor_not_an_equality() -> None:
    assert Grade.IDENTICAL.meets(Grade.STRONG)
    assert Grade.STRONG.meets(Grade.STRONG)
    assert not Grade.MODERATE.meets(Grade.STRONG)
    assert Grade.NONE.meets(Grade.NONE)
    # The string spelling a caller would pass through `min_grade=` works too.
    assert Grade.STRONG.meets("moderate")
