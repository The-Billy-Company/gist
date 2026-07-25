"""Behavioral tests for the kinship face and the batched pattern sweep.

Two questions and their axes: the neighbor question (`similar`, over a file, a
function fragment, or text) and the repetition question (`pairs` / `families` /
`distinct`, over a unit and a channel, inside an optional exact filter), plus the
exact multi-pattern walk (`patterns` / `pattern_counts`). These drive the real
binaries over a throwaway corpus, so they skip cleanly where none is built — the
same discipline as `test_search.py`.

Oracles are independent. Attribution is checked against single-pattern searches
through the established `irregex.files` face; the family closure is checked by
running union-find over the *pair* rows in the test rather than trusting the
engine's own grouping; the narrowing filter is checked against an exact search
for the same pattern; and the fixtures are built so the expected answer follows
from their construction. Nothing is asserted against a verb's own output.
"""

from __future__ import annotations

from itertools import pairwise
import shutil

import pytest

import irregex


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        irregex.binary()
    except irregex.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")


def _bare(label: str) -> str:
    """A unit label with the corpus's `./` root prefix removed."""
    return label.removeprefix("./")


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    # Two near-identical Python files (one renamed identifier), one unrelated
    # Zig file, one file matching several patterns. `GIST_DIR` is redirected so
    # these never read or write the developer's own artifacts.
    #
    # Each handler carries DIFFERENT control flow on purpose. One statement
    # repeated forty times normalizes to one shingle repeated forty times, so
    # such a file holds ~5 distinct structure fingerprints however long it is —
    # under the mass floor, and correctly so: it has no structural variety to
    # compare. That made it useless as a renamed-twin fixture for `shapes`.
    py_a = "\n".join(
        f"def handler_{i}(request, ctx):\n"
        f"    seen = {i}\n"
        f"    for item in request.items:\n"
        f"        if item.kind == {i}:\n"
        f"            seen += route(item, ctx)\n"
        f"        elif item.stale:\n"
        f"            continue\n"
        f"    while seen > {i * 3 + 7}:\n"
        f"        seen = route(seen, ctx) - {i}\n"
        f"    return seen"
        for i in range(12)
    )
    (tmp_path / "a.py").write_text(py_a)
    (tmp_path / "b.py").write_text(py_a.replace("route", "dispatch"))
    (tmp_path / "c.zig").write_text(
        'const std = @import("std");\npub fn main() !void {\n'
        + "".join(f'    std.debug.print("{i}", .{{}});\n' for i in range(40))
        + "}\n"
    )
    (tmp_path / "hits.txt").write_text("alpha beta\nbeta only\nneither\nalpha again\n")
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    return tmp_path


def _body(name: str, verb: str, n: int) -> str:
    """One function whose skeleton is unique to `n` within its module.

    Loop nesting cycles every 4 and the tail statement every 3, so across twelve
    functions no two share a shape — which is what makes "the nearest twin of
    `a.py`'s nth function is `b.py`'s nth" a claim the fixture actually entails
    rather than a tie broken by scan order.
    """
    depth = n % 4 + 1
    lines = [f"def {name}_{n}(request, ctx):", "    total = 0"]
    lines += [f"{'    ' * (d + 1)}for item{d} in request.items:" for d in range(depth)]
    lines.append(f"{'    ' * (depth + 1)}total += {verb}(item{depth - 1}, ctx)")
    lines += (
        ["    if total > 100:", '        raise ValueError("too big")'],
        ["    while total > 100:", "        total -= 1"],
        ["    try:", f"        total = {verb}(total, ctx)", "    except ValueError:", "        total = 0"],
    )[n % 3]
    return "\n".join([*lines, "    return total", ""])


@pytest.fixture
def families_corpus(tmp_path, monkeypatch):
    """Two modules of the same twelve functions under different names.

    The function-granularity settings compare *fragments*, and a two-line body
    carries no structural signal to compare — the engine reports zero candidates
    rather than pretending. So this fixture gives each function a real body, which
    is also what makes it a fair test of the renamed-twin claim: `b.py` is `a.py`
    with every identifier renamed and nothing else touched, so each function's
    only structural twin is its counterpart in the other module.
    """
    (tmp_path / "a.py").write_text("\n".join(_body("handler", "route", i) for i in range(12)))
    (tmp_path / "b.py").write_text("\n".join(_body("worker", "dispatch", i) for i in range(12)))
    (tmp_path / "c.zig").write_text(
        'const std = @import("std");\npub fn main() !void {\n'
        + "".join(f'    std.debug.print("{i}", .{{}});\n' for i in range(40))
        + "}\n"
    )
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    return tmp_path


_HELPER = (
    "def normalize_window(rows, floor, ceiling):\n"
    "    kept = []\n"
    "    for row in rows:\n"
    "        if row.value < floor:\n"
    "            continue\n"
    "        if row.value > ceiling:\n"
    "            row = row.clamp(ceiling)\n"
    "        kept.append(row)\n"
    "    return kept\n"
)


@pytest.fixture
def pasted_helper(tmp_path, monkeypatch):
    """Two modules with nothing in common except one copy-pasted helper.

    This is the case a file-level comparison structurally cannot see: the shared
    helper is a few percent of either file's bytes, so the *files* are unrelated
    while one *function* is duplicated verbatim. It is the whole reason the unit
    is an axis rather than a fixed choice.
    """
    for name, verb in (("ledger.py", "settle"), ("router.py", "dispatch")):
        unique = "\n".join(_body(name.removesuffix(".py"), verb, i) for i in range(24))
        (tmp_path / name).write_text(f"{unique}\n\n{_HELPER}")
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    return tmp_path


def _components(pairs: list[irregex.Pair]) -> list[set[str]]:
    """Connected components of a pair list, by union-find — the closure `families` claims to return, derived here independently."""
    parent: dict[str, str] = {}

    def find(x: str) -> str:
        parent.setdefault(x, x)
        while parent[x] != x:
            x = parent[x] = parent[parent[x]]
        return x

    for pair in pairs:
        parent[find(pair.a)] = find(pair.b)
    groups: dict[str, set[str]] = {}
    for node in parent:
        groups.setdefault(find(node), set()).add(node)
    return [g for g in groups.values() if len(g) > 1]


# ── the neighbor question ────────────────────────────────────────────────────


@needs_gist
def test_similar_ranks_the_near_twin_first(corpus):
    out = irregex.similar("a.py", roots=["."], top=3, cwd=corpus)
    assert out, "expected at least one neighbor"
    # The probe itself never appears; its rename-twin ranks first, closer
    # than either unrelated file.
    assert _bare(out[0].unit) == "b.py"
    assert out[0].distance < 1.0
    # distances ascend
    assert all(x.score <= y.score for x, y in pairwise(out))


@needs_gist
def test_a_fragment_probe_compares_functions_without_being_told_to(families_corpus):
    """`path#Lnnn` is a *function* probe, so the unit follows the probe.

    Comparing one function against whole files would ask "which file resembles
    this function?", which is a category error dressed as a number — so the shape
    of the argument, not a flag, decides the unit.
    """
    out = irregex.similar("a.py#L1", roots=["."], top=5, cwd=families_corpus)
    assert out, "expected nearest function fragments"
    # Every answer is a fragment, and the probe's own span is not among them.
    assert all(row.line is not None for row in out)
    assert ("a.py", 1) not in {(_bare(row.unit), row.line) for row in out}
    # The renamed twin of that function lives in the other module.
    assert _bare(out[0].path) == "b.py"


@needs_gist
def test_a_text_probe_is_priced_by_recall_not_by_distance(families_corpus):
    """Prose has no code skeleton, so text with no channel is a retrieval question — and the score that comes back is a coding *gain*, which rises with confidence.

    The adverse half is the point: a line lifted verbatim out of the corpus must
    grade far above a sentence about a subject the corpus has never seen. Ranking
    always returns rows, so without the grade both answers look identical.
    """
    lifted = irregex.similar(
        '        raise ValueError("too big")', roots=["."], cwd=families_corpus
    )
    assert lifted, "expected recall hits"
    assert lifted.channel is irregex.Channel.RECALL
    assert lifted[0].channel is irregex.Channel.RECALL
    # A gain is not a distance, and the row refuses to be read as one.
    assert lifted[0].distance is None
    assert lifted[0].grade is irregex.grade_of(irregex.Channel.RECALL, lifted[0].score)
    assert lifted[0].grade.meets(irregex.Grade.MODERATE)

    absent = irregex.similar(
        "quarterly amortization schedules for leasehold improvements",
        roots=["."],
        cwd=families_corpus,
    )
    assert not absent or not absent[0].grade.meets(irregex.Grade.MODERATE), (
        "a subject the corpus does not contain must not grade as recalled"
    )


@needs_gist
def test_naming_a_channel_turns_the_same_text_into_a_record_probe(families_corpus):
    """With `channel=`, text is fingerprinted and compared like any other record — "what is shaped like this snippet?" — so the answer flips back to a distance."""
    snippet = _body("handler", "route", 3)
    shaped = irregex.similar(snippet, channel="shapes", roots=["."], cwd=families_corpus)
    assert shaped, "expected structural neighbors of the snippet"
    assert shaped.channel is irregex.Channel.SHAPES
    assert shaped[0].distance == shaped[0].score
    assert all(x.score <= y.score for x, y in pairwise(shaped))
    # And the retrieval channel cannot be *asked* for: it is chosen by the shape
    # of the probe, never by a flag.
    with pytest.raises(ValueError, match="probe's shape"):
        irregex.similar("some words", channel="recall", roots=["."], cwd=families_corpus)


@needs_gist
def test_every_row_carries_the_calibrated_grade_for_its_score(corpus):
    """The band, not the bare number, is what a caller can branch on."""
    out = irregex.similar("a.py", roots=["."], top=3, cwd=corpus)
    for row in out:
        assert row.grade is irregex.grade_of(row.channel, row.score)
    # Grades are monotone in the ranking: the rename-twin cannot be graded
    # weaker than a file that shares nothing with the probe.
    assert out[0].grade.rank <= out[-1].grade.rank
    assert out[-1].grade is irregex.Grade.NONE, "an unrelated file is background"


@needs_gist
def test_an_engine_side_floor_agrees_with_filtering_after_the_fact(corpus):
    """`min_grade=` withholds rows in the kernel; `at_least` filters them here. They must be the same set — otherwise the cheap path would quietly answer differently."""
    everything = irregex.similar("a.py", roots=["."], top=10, cwd=corpus)
    withheld = irregex.similar("a.py", roots=["."], top=10, min_grade="moderate", cwd=corpus)
    assert [r.unit for r in withheld] == [r.unit for r in everything.at_least("moderate")]


@needs_gist
def test_a_fully_withheld_answer_is_empty_not_an_exception(corpus):
    """An `identical` floor over a corpus with no identical files withholds every row.

    The engine reports that rg-style — exit 1, "no matches" — which is the answer
    the caller asked for, not a failure. Raising here would force every caller to
    wrap a legitimate empty result in `try`.
    """
    out = irregex.similar("a.py", roots=["."], top=10, min_grade="identical", cwd=corpus)
    assert list(out) == []
    assert out.channel is irregex.Channel.COPIES


@needs_gist
def test_an_answer_reports_the_population_it_was_drawn_from(corpus):
    """ "Nearest of four" and "nearest of twenty thousand" are different claims."""
    out = irregex.similar("a.py", roots=["."], top=3, cwd=corpus)
    assert out.channel is irregex.Channel.COPIES
    assert out.scored is not None
    assert out.scored >= len(out)
    assert isinstance(out.warm, bool)
    # It still behaves as the sequence it wraps.
    assert list(out) == list(out[:])
    assert out == list(out.rows)


@needs_gist
def test_the_channel_selects_what_near_means(corpus):
    """Structure sees past the rename; both CLI vocabularies reach the same channel."""
    shapes = irregex.similar("a.py", channel="shapes", roots=["."], top=3, cwd=corpus)
    metric = irregex.similar("a.py", channel="structure", roots=["."], top=3, cwd=corpus)
    assert [r.unit for r in shapes] == [r.unit for r in metric]
    assert _bare(shapes[0].unit) == "b.py"
    with pytest.raises(ValueError, match="unknown kinship channel"):
        irregex.similar("a.py", channel="sideways", roots=["."], cwd=corpus)


# ── the repetition question ─────────────────────────────────────────────────


@needs_gist
def test_copies_pairs_find_the_duplicate_and_leave_the_strangers_out(corpus):
    found = irregex.pairs(channel="copies", roots=["."], max_distance=0.8, cwd=corpus)
    names = [{_bare(p.a), _bare(p.b)} for p in found]
    assert {"a.py", "b.py"} in names
    unrelated = {"c.zig", "hits.txt"}
    assert not any(n & unrelated for n in names)
    for pair in found:
        assert pair.grade is irregex.grade_of(irregex.Channel.COPIES, pair.score)


@needs_gist
def test_families_are_the_closure_of_the_pairs_not_a_relabelled_pair_list(corpus):
    """A caller acting on repetition acts per family, and every consumer that got a pair list re-derived the closure. So the oracle is that closure, computed here."""
    axes = {"channel": "copies", "roots": ["."], "max_distance": 0.8, "cwd": corpus}
    edges = irregex.pairs(top=100, **axes)
    grouped = irregex.families(min_size=2, top=100, **axes)
    assert {frozenset(f.members) for f in grouped} == {frozenset(c) for c in _components(edges)}
    for family in grouped:
        assert family.size == len(family.members) >= 2
        # The edge is the family's loosest admitted link, so it is graded on the
        # weakest pair rather than on the best one.
        assert family.grade is irregex.grade_of(family.channel, family.edge)
        assert family.edge <= 0.8


@needs_gist
def test_the_twins_channel_reports_the_gap_between_the_two_measurements(families_corpus):
    found = irregex.pairs(roots=["."], min_echo=0.02, top=10, cwd=families_corpus)
    names = [{_bare(p.a), _bare(p.b)} for p in found]
    assert {"a.py", "b.py"} in names, f"got {names}"
    for pair in found:
        # The gap is the ranking signal, and it is exactly what the name says.
        assert pair.score == pytest.approx(pair.byte_distance - pair.structure_distance, abs=1e-3)
    assert all(x.score >= y.score for x, y in pairwise(found))


@needs_gist
def test_the_function_unit_sees_a_pasted_helper_that_file_kinship_cannot(pasted_helper):
    """One duplicated helper inside two otherwise-unrelated modules.

    At file granularity the shared bytes are a rounding error and the files are
    correctly called unrelated. At function granularity the same corpus contains
    a verbatim duplicate. Both answers are right; only the second is actionable,
    which is why the unit is an axis.
    """
    by_file = irregex.pairs(channel="copies", unit="file", roots=["."], cwd=pasted_helper)
    assert not [p for p in by_file if p.grade.meets(irregex.Grade.STRONG)], (
        "two modules sharing one helper are not near-duplicate files"
    )

    by_function = irregex.families(
        channel="copies", unit="function", roots=["."], top=20, cwd=pasted_helper
    )
    helpers = [f for f in by_function if len(f.paths) == 2]
    assert helpers, "the pasted helper must surface as a cross-file family"
    assert {_bare(p) for p in helpers[0].paths} == {"ledger.py", "router.py"}
    assert helpers[0].grade.meets(irregex.Grade.STRONG)
    # Every member names a fragment coordinate, so a caller can open the exact
    # span — and the span the engine points at is the helper it claims.
    for member in helpers[0].members:
        path, _, line = _bare(member).rpartition("#L")
        assert path
        assert line.isdigit()
        declaration = (pasted_helper / path).read_text().splitlines()[int(line) - 1]
        assert declaration.startswith("def normalize_window("), declaration


@needs_gist
def test_distinct_is_the_complement_of_families_with_a_receipt(families_corpus):
    """ "Which of these is genuinely unique?" is otherwise answered by an absence, which is indistinguishable from a threshold that was too tight."""
    axes = {"channel": "copies", "roots": ["."], "max_distance": 0.8, "cwd": families_corpus}
    grouped = irregex.families(min_size=2, top=50, **axes)
    lonely = irregex.distinct(top=50, **axes)
    affiliated = {m for f in grouped for m in f.members}
    assert affiliated, "the fixture's two modules are near-duplicates"
    assert affiliated.isdisjoint({row.unit for row in lonely}), (
        "a unit cannot be both in a family and distinct from everything"
    )
    assert "c.zig" in {_bare(row.unit) for row in lonely}
    for row in lonely:
        # The receipt: what the closest thing was, and how far it missed.
        assert row.nearest is None or row.nearest != row.unit
        assert 0.0 <= row.byte_distance <= 1.0


@needs_gist
def test_matching_asks_the_repetition_question_inside_an_exact_filter(corpus):
    """Narrowing is a modifier: the exact engine picks the population, the compression kernel reasons only inside it, and the two scores never fuse."""
    # Oracle: exactly the files an independent exact search admits.
    admitted = {p.removeprefix("./") for p in irregex.files("dispatch", paths=["."], cwd=corpus)}
    assert admitted == {"b.py"}
    narrowed = irregex.pairs(
        channel="copies", matching=["dispatch"], roots=["."], max_distance=0.9, cwd=corpus
    )
    assert list(narrowed) == [], "one admitted file cannot form a pair"

    both = irregex.pairs(
        channel="copies", matching=["route", "dispatch"], roots=["."], max_distance=0.9, cwd=corpus
    )
    assert [{_bare(p.a), _bare(p.b)} for p in both] == [{"a.py", "b.py"}]
    # `match="all"` requires every pattern in the same unit, which no file here
    # satisfies — a narrowing so tight it empties the population.
    assert (
        list(
            irregex.pairs(
                channel="copies",
                matching=["route", "dispatch"],
                match="all",
                roots=["."],
                max_distance=0.9,
                cwd=corpus,
            )
        )
        == []
    )


@needs_gist
def test_a_sweep_withholds_generated_units_a_probe_keeps_them(tmp_path, monkeypatch):
    """Codegen is the densest structural clone there is, and never a refactor candidate — the fix lives in the template. So a repetition sweep withholds it by default while a probe, which asks about *one* thing, keeps it: "which generated file is closest to this hand-written one" is a real question."""
    body = "\n".join(_body("handler", "route", i) for i in range(12))
    (tmp_path / "a.py").write_text(body)
    (tmp_path / "a.gen.py").write_text(f"# Generated by codegen\n{body}")
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))

    swept = irregex.pairs(channel="copies", roots=["."], max_distance=0.9, cwd=tmp_path)
    assert not any("gen" in p.a or "gen" in p.b for p in swept), (
        "a generated twin is not a consolidation candidate"
    )
    audited = irregex.pairs(
        channel="copies", include_generated=True, roots=["."], max_distance=0.9, cwd=tmp_path
    )
    assert [{_bare(p.a), _bare(p.b)} for p in audited] == [{"a.py", "a.gen.py"}]
    # The probe keeps it without being asked, because it is the answer.
    assert _bare(irregex.similar("a.py", roots=["."], top=1, cwd=tmp_path)[0].unit) == "a.gen.py"


@needs_gist
def test_units_too_small_to_fingerprint_stay_out_of_the_population(tmp_path, monkeypatch):
    """Two one-line re-export files land at distance 0.0000 by arithmetic, not by kinship — an 86-member family of `__init__.py` stubs is the shape this floor exists to refuse. A false `identical` is worse than no row."""
    for name in ("one.py", "two.py", "three.py"):
        (tmp_path / name).write_text("from .core import *\n")
    monkeypatch.setenv("GIST_DIR", str(tmp_path / ".gist"))
    swept = irregex.pairs(channel="copies", roots=["."], max_distance=0.9, cwd=tmp_path)
    assert list(swept) == [], "sub-mass units must not be reported as identical"
    # Lowering the floor deliberately is allowed — the floor is a default, not a
    # rule — and then the arithmetic is visible for what it is.
    forced = irregex.pairs(
        channel="copies", min_mass=1, roots=["."], max_distance=0.9, cwd=tmp_path
    )
    assert forced, "an explicit floor override still measures what is there"


@needs_gist
def test_repetition_refuses_the_retrieval_channel(corpus):
    with pytest.raises(ValueError, match="no 'recall' channel"):
        irregex.pairs(channel="recall", roots=["."], cwd=corpus)


# ── the exact multi-pattern walk ────────────────────────────────────────────


@needs_gist
def test_patterns_attribution_matches_single_pattern_oracle(corpus):
    specs = ["alpha", "beta", "route\\("]
    hits = irregex.patterns(specs, roots=["."], cwd=corpus)
    got = {(h.path, h.line, h.pattern_id) for h in hits}
    # Oracle: one independent single-pattern search per spec.
    want = set()
    for pid, spec in enumerate(specs):
        for m in irregex.search(spec, paths=["."], cwd=corpus):
            want.add((m.path, m.line_number, pid))
    assert got == want


@needs_gist
def test_pattern_counts_group_engine_side(corpus):
    counts = irregex.pattern_counts(["alpha", "beta"], by="pattern", roots=["."], cwd=corpus)
    tally = {c.label: c.count for c in counts}
    assert tally == {"alpha": 2, "beta": 2}
    # descending, label-tiebroken ordering is the loom's contract
    assert counts == sorted(counts, key=lambda c: (-c.count, c.label))


@needs_gist
def test_patterns_requires_a_spec():
    with pytest.raises(ValueError, match="at least one pattern"):
        irregex.patterns([])
