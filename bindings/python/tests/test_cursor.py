"""Idiomatic in-process Engine/Cursor tests (ADR-352 pull-cursor surface).

Proves the warm `irregex.Engine` + pull `irregex.Cursor` produce records
byte-identical to the certified cold subprocess (`engine.run`) — same order,
paths, line numbers, text, and submatch spans — so, transitively through the
cold path's own rg certification, Engine ≡ cold ≡ rg. Then it pins the four
hosted invariants the push/`_ffi` transport doesn't expose at this boundary:
`batches()` is the same record stream chunked, a `max_results` budget stops at a
record boundary while still reporting `matched`, a pre-tripped `CancelToken`
yields a clean empty result, and an unsupported pattern / unrepresentable option
raises a *catchable* typed error rather than crashing the host.

Skipped when the shared library or `cffi` is unavailable: the Engine surface is
in-process by definition.
"""

from __future__ import annotations

import threading

import pytest

import irregex
from irregex.exact.request import SearchRequest
from irregex.runtime import native as _ffi, shell as engine


pytestmark = pytest.mark.skipif(not _ffi.available(), reason="libirregex/cffi unavailable")


@pytest.fixture
def corpus(tmp_path):
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n# TODO trailing\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\nplain text\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("x = 1  # todo lowercase\nTODO upper TODO twice\n")
    return tmp_path


def _cold(corpus, **fields) -> list:
    return engine.run(SearchRequest(paths=(str(corpus),), **fields), cwd=None)


@pytest.mark.parametrize(
    "fields",
    [
        {"pattern": "TODO"},
        {"pattern": "TODO", "fixed": True},
        {"pattern": "TODO", "ignore_case": True},
        {"pattern": r"def\s+\w+"},
        {"pattern": "absent_needle_xyzzy"},
        {"pattern": "TODO", "before": 1, "after": 1},
    ],
)
def test_engine_search_equals_cold(corpus, fields) -> None:
    pattern = fields.pop("pattern")
    with irregex.Engine(str(corpus)) as eng:
        warm = list(eng.search(pattern, **fields))
    assert warm == _cold(corpus, pattern=pattern, **fields)


def test_batches_are_the_same_stream_chunked(corpus) -> None:
    with irregex.Engine(str(corpus)) as eng:
        one_at_a_time = list(eng.search("TODO"))
        chunked = [m for batch in eng.search("TODO").batches(size=2) for m in batch]
    assert chunked == one_at_a_time == _cold(corpus, pattern="TODO")
    # Every batch but the last is full (proves the batch call actually fills).
    with irregex.Engine(str(corpus)) as eng:
        sizes = [len(b) for b in eng.search("TODO").batches(size=2)]
    assert all(n == 2 for n in sizes[:-1])
    assert 1 <= sizes[-1] <= 2


def test_max_results_stops_at_a_boundary_but_still_matched(corpus) -> None:
    with irregex.Engine(str(corpus)) as eng:
        cur = eng.search("TODO", max_results=1)
        got = list(cur)
        assert len(got) == 1
        assert cur.matched is True
    # The single record is the first in cold order.
    assert got[0] == _cold(corpus, pattern="TODO")[0]


def test_matched_flag_tracks_any_hit(corpus) -> None:
    with irregex.Engine(str(corpus)) as eng:
        assert eng.search("TODO").matched is True
        empty = eng.search("absent_needle_xyzzy")
        assert list(empty) == []
        assert empty.matched is False


def test_pretripped_cancel_yields_clean_empty(corpus) -> None:
    with irregex.Engine(str(corpus)) as eng, eng.cancel_token() as tok:
        tok.cancel()
        cur = eng.search("TODO", cancel=tok)
        # A pre-tripped token collects nothing (the budget cuts at the first
        # record boundary); `matched` still reflects that the corpus HAS matches
        # (the documented "did any file match, before any budget cut" semantic).
        assert list(cur) == []
        # The engine stays healthy: an uncancelled search still returns the full set.
        assert list(eng.search("TODO")) == _cold(corpus, pattern="TODO")


def test_cancel_from_another_thread_is_safe(corpus) -> None:
    # A concurrent cancel must never crash the host; on this tiny corpus the scan
    # usually completes first, so we assert only the safety + subset property.
    with irregex.Engine(str(corpus)) as eng, eng.cancel_token() as tok:
        barrier = threading.Barrier(2)

        def canceler() -> None:
            barrier.wait()
            tok.cancel()

        t = threading.Thread(target=canceler)
        t.start()
        barrier.wait()
        got = list(eng.search("TODO", cancel=tok))
        t.join()
    assert len(got) <= len(_cold(corpus, pattern="TODO"))


def test_unsupported_pattern_raises_typed_error(corpus) -> None:
    with irregex.Engine(str(corpus)) as eng, pytest.raises(irregex.UnsupportedPatternError):
        eng.search(r"(?=lookahead)")


@pytest.mark.parametrize(
    "fields",
    [
        {"types": ("py",)},
        {"globs": ("*.py",)},
        {"multiline": True},
        {"engine": "pcre2"},
        {"no_ignore": True},
    ],
)
def test_unrepresentable_option_raises(corpus, fields) -> None:
    with irregex.Engine(str(corpus)) as eng, pytest.raises(irregex.GistError):
        eng.search("TODO", **fields)


def test_cursor_records_outlive_engine_and_cursor(corpus) -> None:
    # Records are copied by default, so they stay valid after both handles close.
    eng = irregex.Engine(str(corpus))
    cur = eng.search("TODO")
    records = list(cur)
    cur.close()
    eng.close()
    assert records == _cold(corpus, pattern="TODO")
    assert all(isinstance(m.text, str) for m in records)


def test_rootless_engine_matches_cold_rootless(corpus, monkeypatch) -> None:
    monkeypatch.chdir(corpus)
    with irregex.Engine() as eng:  # no roots -> the rootless CWD walk
        warm = list(eng.search("TODO"))
    assert warm == engine.run(SearchRequest(pattern="TODO"), cwd=None)
