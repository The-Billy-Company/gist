"""Behavioral + rg-parity tests for the importable search API (ADR-352).

These drive the real `gist` binary over a throwaway corpus, so they skip cleanly
where no binary is built. The parity tests additionally require `rg` on PATH and
assert GIST's discovery set is byte-equivalent to ripgrep's — the correctness
contract the whole kernel rests on.
"""

from __future__ import annotations

from dataclasses import replace
import shutil
import subprocess

import pytest

import irregex
from irregex.engine import _parse_json
from irregex.errors import UnsupportedPatternError
from irregex.request import MatchKind, SearchEngine, SearchRequest


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        irregex.binary()
    except irregex.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")
needs_rg = pytest.mark.skipif(shutil.which("rg") is None, reason="no rg on PATH")


@pytest.fixture
def corpus(tmp_path):
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO + TODO\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\nplain text\n")
    (tmp_path / "unicode.txt").write_text("CAFÉ\ncafé\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("x = 1  # todo lowercase\nTODO upper\n")
    return tmp_path


@needs_gist
def test_search_returns_structured_matches(corpus) -> None:
    matches = irregex.search("TODO", cwd=corpus)
    assert matches, "expected TODO matches"
    assert all(m.kind is MatchKind.MATCH for m in matches)
    hit = next(m for m in matches if m.path.endswith("a.py"))
    assert hit.line_number == 2
    assert "TODO" in hit.text
    assert hit.column >= 1
    assert hit.submatches
    assert hit.submatches[0].text == "TODO"


@needs_gist
def test_structured_search_is_not_truncated_by_cli_output_budget(corpus, monkeypatch) -> None:
    monkeypatch.setenv("GIST_MAX_OUTPUT_BYTES", "64")
    matches = irregex.search("TODO", cwd=corpus)
    assert {match.path for match in matches} == {"a.py", "b.py", "pkg/d.py"}


@needs_gist
def test_files_lists_matching_paths(corpus) -> None:
    hits = irregex.files("TODO", cwd=corpus)
    assert any(p.endswith("a.py") for p in hits)
    assert not any(p.endswith("c.txt") for p in hits)


@needs_gist
def test_count_sums_matching_lines(corpus) -> None:
    # a.py:1, b.py:1, pkg/d.py:1 (uppercase TODO) — lowercase 'todo' excluded.
    assert irregex.count("TODO", cwd=corpus) == 3


@needs_gist
def test_count_matches_sums_occurrences(corpus) -> None:
    assert irregex.count_matches("TODO", cwd=corpus) == 4


@needs_gist
def test_ignore_case_widens(corpus) -> None:
    assert irregex.count("TODO", ignore_case=True, cwd=corpus) == 4


@needs_gist
def test_no_match_is_empty_not_error(corpus) -> None:
    assert irregex.search("zzz_no_such_token_zzz", cwd=corpus) == []


@needs_gist
def test_unsupported_pattern_raises_not_kills(corpus) -> None:
    pattern = r"(?<=return )TODO"
    with pytest.raises(UnsupportedPatternError):
        irregex.search(pattern, cwd=corpus)
    assert irregex.search(pattern, engine=SearchEngine.PCRE2, cwd=corpus)
    assert irregex.search(pattern, engine="auto", cwd=corpus)


@needs_gist
def test_multiline_dotall_and_unicode_semantics_are_first_class(corpus) -> None:
    matches = irregex.search(r"def alpha.*TODO", multiline_dotall=True, cwd=corpus)
    assert len(matches) == 1
    assert "\n" in matches[0].text
    assert irregex.count("CAFÉ", ignore_case=True, unicode=True, cwd=corpus) == 2
    assert irregex.count("CAFÉ", ignore_case=True, unicode=False, cwd=corpus) == 1


@needs_gist
def test_context_lines_are_context_kind(corpus) -> None:
    matches = irregex.search("alpha", before=1, after=1, cwd=corpus)
    assert any(m.kind is MatchKind.CONTEXT for m in matches)


@needs_gist
@needs_rg
def test_files_parity_with_ripgrep(corpus) -> None:
    for pattern in ("TODO", r"def\s+\w+", "class"):
        gist_hits = set(irregex.files(pattern, cwd=corpus))
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


@needs_gist
@needs_rg
def test_full_structured_match_parity_with_ripgrep(corpus) -> None:
    request = SearchRequest(pattern="TODO", paths=(".",), before=1, after=1)
    gist_matches = irregex.run(request, cwd=corpus)
    proc = subprocess.run(  # noqa: S603 — fixed argv
        [shutil.which("rg"), *request.to_argv(), "--json", "--regexp", request.pattern, "."],
        capture_output=True,
        text=True,
        cwd=corpus,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    rg_matches = _parse_json(proc.stdout)
    normalized = sorted(
        [replace(match, path=match.path.removeprefix("./")) for match in gist_matches],
        key=lambda match: (match.path, match.line_number, match.kind, match.text),
    )
    oracle = sorted(
        [replace(match, path=match.path.removeprefix("./")) for match in rg_matches],
        key=lambda match: (match.path, match.line_number, match.kind, match.text),
    )
    assert normalized == oracle
