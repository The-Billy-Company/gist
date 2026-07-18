"""Behavioral tests for the irregex face (`similar` / `dups` / `patterns`).

These drive the real `gist` binary over a throwaway corpus, so they skip
cleanly where no binary is built — the same discipline as `test_search.py`.
The oracle for attribution is independent single-pattern searches through the
established `gist.files` face, never the verb's own output.
"""

from __future__ import annotations

import shutil

import pytest

import gist


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        gist.binary()
    except gist.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")


@pytest.fixture
def corpus(tmp_path):
    # Two near-identical Python files (one renamed identifier), one unrelated
    # Zig file, one file matching several patterns.
    py_a = "\n".join(
        f"def handler_{i}(request):\n    return route(request, {i})" for i in range(40)
    )
    (tmp_path / "a.py").write_text(py_a)
    (tmp_path / "b.py").write_text(py_a.replace("route", "dispatch"))
    (tmp_path / "c.zig").write_text(
        "const std = @import(\"std\");\npub fn main() !void {\n"
        + "".join(f"    std.debug.print(\"{i}\", .{{}});\n" for i in range(40))
        + "}\n"
    )
    (tmp_path / "hits.txt").write_text("alpha beta\nbeta only\nneither\nalpha again\n")
    return tmp_path


@needs_gist
def test_similar_ranks_the_near_twin_first(corpus):
    out = gist.similar("a.py", roots=["."], top=3, cwd=corpus)
    assert out, "expected at least one neighbor"
    # The target itself never appears; its rename-twin ranks first, closer
    # than either unrelated file.
    assert [s.path.removeprefix("./") for s in out][0] == "b.py"
    assert out[0].distance < 1.0
    # distances ascend
    assert all(x.distance <= y.distance for x, y in zip(out, out[1:], strict=False))


@needs_gist
def test_dups_finds_the_pair_and_orders_it(corpus):
    pairs = gist.dups(roots=["."], max_distance=0.8, cwd=corpus)
    names = [{p.a.removeprefix("./"), p.b.removeprefix("./")} for p in pairs]
    assert {"a.py", "b.py"} in names
    unrelated = {"c.zig", "hits.txt"}
    assert not any(n & unrelated for n in names)


@needs_gist
def test_patterns_attribution_matches_single_pattern_oracle(corpus):
    specs = ["alpha", "beta", "route\\("]
    hits = gist.patterns(specs, roots=["."], cwd=corpus)
    got = {(h.path, h.line, h.pattern_id) for h in hits}
    # Oracle: one independent single-pattern search per spec.
    want = set()
    for pid, spec in enumerate(specs):
        for m in gist.search(spec, paths=["."], cwd=corpus):
            want.add((m.path, m.line_number, pid))
    assert got == want


@needs_gist
def test_pattern_counts_group_engine_side(corpus):
    counts = gist.pattern_counts(["alpha", "beta"], by="pattern", roots=["."], cwd=corpus)
    tally = {c.label: c.count for c in counts}
    assert tally == {"alpha": 2, "beta": 2}
    # descending, label-tiebroken ordering is the loom's contract
    assert counts == sorted(counts, key=lambda c: (-c.count, c.label))


@needs_gist
def test_patterns_requires_a_spec():
    with pytest.raises(ValueError, match="at least one pattern"):
        gist.patterns([])
