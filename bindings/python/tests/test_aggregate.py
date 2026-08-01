"""Result-side aggregation over GIST matches.

Two layers, mirroring the rest of the suite. The pure layer drives `tally`
over synthetic `Match` records — no binary, so it always runs and pins the
grouping/ranking/skip-context contract exactly. The integration layer runs
`gist.summary` over a throwaway corpus through the real engine and asserts the
aggregate agrees with the flat `search` it is derived from.
"""

from __future__ import annotations

import shutil

import pytest

import gist
from gist.exact.aggregate import Group, Tally, resolve_axis, tally
from irregex.request import Match, MatchKind, Submatch


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        gist.binary()
    except gist.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")


def _m(
    path: str, line: int, text: str, *, hit: str | None = None, kind: MatchKind = MatchKind.MATCH
) -> Match:
    """A synthetic match; `hit` (a substring of `text`) becomes its submatch."""
    subs: tuple[Submatch, ...] = ()
    if hit is not None:
        start = text.index(hit)
        subs = (Submatch(text=hit, start=start, end=start + len(hit)),)
    return Match(path=path, line_number=line, text=text, kind=kind, submatches=subs)


# ─────────────────────────── pure aggregation (no binary) ───────────────────────────


def test_tally_ranks_buckets_by_descending_count() -> None:
    matches = [
        _m("a.py", 1, "TODO one", hit="TODO"),
        _m("a.py", 2, "TODO two", hit="TODO"),
        _m("b.py", 9, "TODO solo", hit="TODO"),
    ]
    t = tally(matches, by="file")
    assert [(g.key, g.count) for g in t] == [("a.py", 2), ("b.py", 1)]
    assert t.total == 3
    assert t.files == 2


def test_ties_break_by_key_ascending() -> None:
    t = tally([_m("z.py", 1, "x", hit="x"), _m("a.py", 1, "x", hit="x")], by="file")
    assert [g.key for g in t] == ["a.py", "z.py"]


def test_context_lines_never_inflate_a_tally() -> None:
    matches = [
        _m("a.py", 5, "hit", hit="hit"),
        _m("a.py", 4, "neighbor above", kind=MatchKind.CONTEXT),
        _m("a.py", 6, "neighbor below", kind=MatchKind.CONTEXT),
    ]
    t = tally(matches, by="file")
    assert t.total == 1
    assert t.groups[0].count == 1


def test_by_dir_groups_across_files() -> None:
    matches = [
        _m("svc/api/a.py", 1, "p", hit="p"),
        _m("svc/api/b.py", 1, "p", hit="p"),
        _m("svc/web/c.py", 1, "p", hit="p"),
    ]
    t = tally(matches, by="dir")
    top = t.groups[0]
    assert top.key == "svc/api"
    assert top.count == 2
    assert top.files == 2  # a bucket can span multiple files on a dir axis


def test_by_extension_axis() -> None:
    t = tally(
        [_m("a.py", 1, "p", hit="p"), _m("b.go", 1, "p", hit="p"), _m("c.py", 1, "p", hit="p")],
        by="ext",
    )
    assert t.groups[0].key == ".py"
    assert t.groups[0].count == 2


def test_by_match_text_groups_distinct_tokens() -> None:
    """The axis for "what distinct tokens did this pattern hit"."""
    matches = [
        _m("x.md", 1, "see RFC-2119 here", hit="RFC-2119"),
        _m("y.md", 1, "also RFC-2119", hit="RFC-2119"),
        _m("z.md", 1, "and RFC-7231", hit="RFC-7231"),
    ]
    t = tally(matches, by="match")
    assert [(g.key, g.count) for g in t] == [("RFC-2119", 2), ("RFC-7231", 1)]


def test_custom_callable_axis() -> None:
    t = tally(
        [_m("a.py", 1, "p", hit="p"), _m("b.py", 2, "p", hit="p")],
        by=lambda m: "even" if m.line_number % 2 == 0 else "odd",
    )
    assert {g.key for g in t} == {"odd", "even"}


def test_unknown_named_axis_is_a_loud_error() -> None:
    with pytest.raises(ValueError, match="unknown group axis"):
        resolve_axis("directory")  # typo for "dir"


def test_tally_helpers() -> None:
    t = tally([_m(f"f{i}.py", 1, "p", hit="p") for i in range(4)], by="file")
    assert len(t) == 4
    assert len(t.top(2)) == 2
    assert t.top(0) == t.groups  # n<=0 means "all"
    assert t.get("f2.py") is not None
    assert t.get("nope.py") is None


def test_empty_input_is_an_empty_tally() -> None:
    t = tally([], by="file")
    assert isinstance(t, Tally)
    assert len(t) == 0
    assert t.total == 0
    assert t.files == 0


def test_group_and_tally_are_frozen() -> None:
    """Frozen dataclasses: neither Group.key nor Tally.groups may be reassigned."""
    g = Group(key="k", matches=())
    with pytest.raises((AttributeError, TypeError)):
        g.key = "other"
    t = Tally(groups=(g,))
    with pytest.raises((AttributeError, TypeError)):
        t.groups = ()
    # Mutation must not silently succeed — identity and ranking stay pinned.
    assert t.groups[0].key == "k"
    assert t.total == 0


# ─────────────────────────── integration (real engine) ───────────────────────────


@pytest.fixture
def corpus(tmp_path):
    (tmp_path / "a.py").write_text("TODO one\nTODO two\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("TODO nested\n")
    return tmp_path


@needs_gist
def test_summary_by_file_agrees_with_flat_search(corpus) -> None:
    """The aggregate is derived from `search`, so the two must agree exactly:
    every bucket's count sums to the flat match total, and the ranking puts the
    busiest file first.
    """
    flat = gist.search("TODO", cwd=corpus)
    t = gist.summary("TODO", by="file", cwd=corpus)
    assert t.total == len(flat)
    assert t.groups[0].key.endswith("a.py")  # a.py has two TODOs → the head
    assert t.groups[0].count == 2


@needs_gist
def test_summary_by_dir_concentrates_the_root(corpus) -> None:
    t = gist.summary("TODO", by="dir", cwd=corpus)
    # a.py + b.py sit at the corpus root; pkg/d.py under pkg/ — the root bucket wins.
    assert t.groups[0].count == 3


@needs_gist
def test_summary_forwards_search_options(corpus) -> None:
    """`types=` scoping flows through summary into the underlying request: the
    `.py` files match and the `.txt` file is pruned before it can enter the
    tally, so the ext axis has exactly one `.py` bucket.
    """
    t = gist.summary("TODO", by="ext", types=["py"], cwd=corpus)
    assert [g.key for g in t.groups] == [".py"]
    assert t.total == 4  # a.py x2, b.py x1, pkg/d.py x1
