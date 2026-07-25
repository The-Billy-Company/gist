"""Behavioral tests for the kinship face and the batched pattern sweep.

Six kinship verbs over two granularities (`similar` / `dups` / `clusters` /
`echoes` over files, `concepts` / `fragments` over functions) plus the exact
multi-pattern walk (`patterns` / `pattern_counts`). These drive the real binaries
over a throwaway corpus, so they skip cleanly where none is built — the same
discipline as `test_search.py`.

Oracles are independent: attribution is checked against single-pattern searches
through the established `irregex.files` face, and the fork family is checked
against the fixture's own construction — never against the verb's own output.
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


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    # Two near-identical Python files (one renamed identifier), one unrelated
    # Zig file, one file matching several patterns. `GIST_DIR` is redirected so
    # these never read or write the developer's own artifacts.
    py_a = "\n".join(
        f"def handler_{i}(request):\n    return route(request, {i})" for i in range(40)
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
    """One function with enough body to carry a structural signal."""
    return (
        f"def {name}_{n}(request, ctx):\n"
        "    total = 0\n"
        "    for item in request.items:\n"
        f"        if item.kind == {n}:\n"
        f"            total += {verb}(item, ctx)\n"
        "    if total > 100:\n"
        '        raise ValueError("too big")\n'
        "    return total\n"
    )


@pytest.fixture
def families(tmp_path, monkeypatch):
    """Two modules of the same twelve functions under different names.

    The function-granularity verbs compare *fragments*, and a two-line body
    carries no structural signal to compare — the engine reports zero candidates
    rather than pretending. So this fixture gives each function a real body, which
    is also what makes it a fair test of the renamed-twin claim.
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


@needs_gist
def test_similar_ranks_the_near_twin_first(corpus):
    out = irregex.similar("a.py", roots=["."], top=3, cwd=corpus)
    assert out, "expected at least one neighbor"
    # The target itself never appears; its rename-twin ranks first, closer
    # than either unrelated file.
    assert out[0].path.removeprefix("./") == "b.py"
    assert out[0].distance < 1.0
    # distances ascend
    assert all(x.distance <= y.distance for x, y in pairwise(out))


@needs_gist
def test_dups_finds_the_pair_and_orders_it(corpus):
    pairs = irregex.dups(roots=["."], max_distance=0.8, cwd=corpus)
    names = [{p.a.removeprefix("./"), p.b.removeprefix("./")} for p in pairs]
    assert {"a.py", "b.py"} in names
    unrelated = {"c.zig", "hits.txt"}
    assert not any(n & unrelated for n in names)


@needs_gist
def test_every_row_carries_the_calibrated_grade_for_its_score(corpus):
    """The band, not the bare number, is what a caller can branch on."""
    out = irregex.similar("a.py", roots=["."], top=3, cwd=corpus)
    for row in out:
        assert row.grade is irregex.grade_of(row.channel, row.distance)
    # Grades are monotone in the ranking: the rename-twin cannot be graded
    # weaker than a file that shares nothing with the probe.
    assert out[0].grade.rank <= out[-1].grade.rank
    assert out[-1].grade is irregex.Grade.NONE, "an unrelated file is background"


@needs_gist
def test_an_engine_side_floor_agrees_with_filtering_after_the_fact(corpus):
    """`min_grade=` withholds rows in the kernel; `at_least` filters them here. They must be the same set — otherwise the cheap path would quietly answer differently."""
    everything = irregex.similar("a.py", roots=["."], top=10, cwd=corpus)
    withheld = irregex.similar("a.py", roots=["."], top=10, min_grade="moderate", cwd=corpus)
    assert [r.path for r in withheld] == [r.path for r in everything.at_least("moderate")]


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
    assert [r.path for r in shapes] == [r.path for r in metric]
    assert shapes[0].path.removeprefix("./") == "b.py"
    with pytest.raises(ValueError, match="unknown kinship channel"):
        irregex.similar("a.py", channel="sideways", roots=["."], cwd=corpus)


@needs_gist
def test_clusters_return_the_family_not_the_pair_list(corpus):
    families = irregex.clusters(roots=["."], max_distance=0.8, min_size=2, cwd=corpus)
    members = [{p.removeprefix("./") for p in f.paths} for f in families]
    assert {"a.py", "b.py"} in members
    for family in families:
        assert family.size == len(family.paths) >= 2
        assert 0.0 <= family.max_distance <= 0.8


@needs_gist
def test_echoes_find_the_renamed_twin_by_its_shape(families):
    pairs = irregex.echoes(roots=["."], min_echo=0.02, top=10, cwd=families)
    found = [{p.a.removeprefix("./"), p.b.removeprefix("./")} for p in pairs]
    assert {"a.py", "b.py"} in found, f"got {found}"
    for pair in pairs:
        # The gap is the ranking signal, and it is exactly what the name says.
        assert pair.echo == pytest.approx(pair.byte_distance - pair.structure_distance, abs=1e-3)
    assert all(x.echo >= y.echo for x, y in pairwise(pairs))


@needs_gist
def test_concepts_group_functions_and_regions_read_back(families):
    grouped = irregex.concepts(roots=["."], min_lines=3, min_size=2, top=5, cwd=families)
    assert grouped, "two modules of the same twelve functions must form a concept"
    first = grouped[0]
    assert first.size >= 2
    assert first.repeated_lines > 0
    assert len(first.paths) == 2, "the family must span both modules"
    # Region coordinates have to point at the code they claim.
    body = first.members[0].read(cwd=families)
    assert body.strip(), "a region must have source"
    assert body.count("\n") == first.members[0].lines


@needs_gist
def test_fragments_retrieve_functions_nearest_a_description(families):
    hits = irregex.fragments(
        "for item in request.items: total += route(item, ctx)", roots=["."], top=5, cwd=families
    )
    assert hits, "expected nearest function fragments"
    assert all(h.distance is not None for h in hits)
    assert all(x.distance <= y.distance for x, y in pairwise(hits))
    assert "for item in request.items" in hits[0].read(cwd=families)


@needs_gist
def test_concepts_rejects_a_channel_it_has_no_lens_for(corpus):
    with pytest.raises(ValueError, match="no 'any' channel"):
        irregex.concepts(channel="any", roots=["."], cwd=corpus)


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
