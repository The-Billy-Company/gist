"""Behavioral + rg-parity tests for the importable search API (ADR-352).

These drive the real `gist` binary over a throwaway corpus, so they skip cleanly
where no binary is built. The parity tests additionally require `rg` on PATH and
assert GIST's discovery set is byte-equivalent to ripgrep's — the correctness
contract the whole kernel rests on.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

import gist
from gist.errors import UnsupportedPatternError
from gist.request import MatchKind, SearchRequest


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        gist.binary()
    except gist.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")
needs_rg = pytest.mark.skipif(shutil.which("rg") is None, reason="no rg on PATH")


@pytest.fixture
def corpus(tmp_path):
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\nplain text\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("x = 1  # todo lowercase\nTODO upper\n")
    return tmp_path


@needs_gist
def test_search_returns_structured_matches(corpus) -> None:
    matches = gist.search("TODO", cwd=corpus)
    assert matches, "expected TODO matches"
    assert all(m.kind is MatchKind.MATCH for m in matches)
    hit = next(m for m in matches if m.path.endswith("a.py"))
    assert hit.line_number == 2
    assert "TODO" in hit.text
    assert hit.column >= 1
    assert hit.submatches
    assert hit.submatches[0].text == "TODO"


@needs_gist
def test_files_lists_matching_paths(corpus) -> None:
    hits = gist.files("TODO", cwd=corpus)
    assert any(p.endswith("a.py") for p in hits)
    assert not any(p.endswith("c.txt") for p in hits)


@needs_gist
def test_count_sums_matching_lines(corpus) -> None:
    # a.py:1, b.py:1, pkg/d.py:1 (uppercase TODO) — lowercase 'todo' excluded.
    assert gist.count("TODO", cwd=corpus) == 3


@needs_gist
def test_ignore_case_widens(corpus) -> None:
    assert gist.count("TODO", ignore_case=True, cwd=corpus) == 4


@needs_gist
def test_no_match_is_empty_not_error(corpus) -> None:
    assert gist.search("zzz_no_such_token_zzz", cwd=corpus) == []


@needs_gist
def test_unsupported_pattern_raises_not_kills(corpus) -> None:
    # PCRE2 lookaround is outside GIST's linear-time engine → typed error,
    # never a dead host process.
    with pytest.raises(UnsupportedPatternError):
        gist.run(SearchRequest(pattern="foo", extra_flags=("-P",)), cwd=corpus)


@needs_gist
def test_context_lines_are_context_kind(corpus) -> None:
    matches = gist.search("alpha", before=1, after=1, cwd=corpus)
    assert any(m.kind is MatchKind.CONTEXT for m in matches)


@needs_gist
@needs_rg
def test_files_parity_with_ripgrep(corpus) -> None:
    for pattern in ("TODO", r"def\s+\w+", "class"):
        gist_hits = set(gist.files(pattern, cwd=corpus))
        proc = subprocess.run(  # noqa: S603 — fixed argv
            [shutil.which("rg"), "-l", pattern, "."],
            capture_output=True,
            text=True,
            cwd=corpus,
            check=False,
        )
        rg_hits = {ln.removeprefix("./") for ln in proc.stdout.splitlines() if ln}
        gist_norm = {p.removeprefix("./") for p in gist_hits}
        assert gist_norm == rg_hits, f"discovery drift on {pattern!r}"
