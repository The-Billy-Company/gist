"""In-process FFI transport parity (ADR-352 rung 3).

Proves the cffi transport (`gist/_ffi.py` over `libirregex`) is byte-identical to
the certified cold subprocess — same `run`/`files`/`count` answers, same record
ORDER, same submatch offsets — and that it reconciles writes (read-your-writes)
and declines an unsupported pattern to cold instead of aborting. Since the cold
path is itself certified against ripgrep, FFI ≡ cold ≡ rg transitively.

Skipped when the shared library or `cffi` is unavailable: the in-process
transport is an OPTIONAL accelerator; the package stays pure-Python without it.
Each test `chdir`s into a fresh corpus because the FFI walks the rootless
process CWD — the exact tree a rootless cold run walks with `cwd` set there, so
paths agree with no normalization.
"""

from __future__ import annotations

import pytest

import gist
from gist import _ffi, engine
from gist.request import SearchRequest


pytestmark = pytest.mark.skipif(not _ffi.available(), reason="libirregex/cffi unavailable")


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n# TODO trailing\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\nplain text\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("x = 1  # todo lowercase\nTODO upper TODO twice\n")
    monkeypatch.chdir(tmp_path)
    return tmp_path


@pytest.mark.parametrize(
    "req",
    [
        SearchRequest(pattern="TODO"),  # plain regex literal
        SearchRequest(pattern="TODO", fixed=True),  # -F literal fast path
        SearchRequest(pattern="TODO", ignore_case=True),  # -i fold
        SearchRequest(pattern=r"def\s+\w+"),  # real regex
        SearchRequest(pattern=r"T[O]DO"),  # regex span path (char class)
        SearchRequest(pattern="absent_needle_xyzzy"),  # no match → []
    ],
)
def test_run_equals_cold(corpus, req: SearchRequest) -> None:
    warm = _ffi.run(req, cwd=None)
    cold = engine.run(req, cwd=None)
    assert warm is not None  # eligible + lib present → served warm
    # Byte parity: identical order, path, line number, text, and submatch spans.
    assert warm == cold


def test_files_and_count_equal_cold(corpus) -> None:
    req = SearchRequest(pattern="TODO")
    assert _ffi.files(req, cwd=None) == engine.files(req, cwd=None)
    assert _ffi.count(req, cwd=None) == engine.count(req, cwd=None)
    ci = SearchRequest(pattern="TODO", ignore_case=True)
    assert _ffi.count(ci, cwd=None) == engine.count(ci, cwd=None)
    assert _ffi.count(ci, cwd=None) > _ffi.count(req, cwd=None)  # -i pulls in 'todo'


def test_session_run_is_warm_and_matches_cold(corpus) -> None:
    # `Session.run` gains a warm transport for the first time (UDS only ever did
    # files/count) — it must equal the cold `--json` matches exactly.
    with gist.Session(cwd=None) as s:
        warm = s.run(SearchRequest(pattern="TODO"))
    assert warm == engine.run(SearchRequest(pattern="TODO"), cwd=None)


def test_abi_version_parity() -> None:
    # The loaded library's C-ABI symbol must equal the version the loader gates
    # on (else `_load` declines and `available()` is False) — the guard that
    # stops a stale header/library pair from being driven with wrong offsets.
    loaded = _ffi._load()
    assert loaded is not None
    _ffi_mod, lib = loaded
    assert lib.irregex_abi_version() == _ffi._ABI_VERSION


def test_read_your_writes(corpus) -> None:
    req = SearchRequest(pattern="FRESHNEEDLE")
    assert _ffi.run(req, cwd=None) == []  # opens the warm handle; corpus has none
    (corpus / "new.py").write_text("FRESHNEEDLE appears\n")
    warm = _ffi.run(req, cwd=None)  # SAME cached handle must reconcile the write
    assert warm is not None
    assert any(m.path.endswith("new.py") for m in warm)
    assert warm == engine.run(req, cwd=None)


def test_deletion_is_reconciled(corpus) -> None:
    req = SearchRequest(pattern="TODO", fixed=True)
    assert any(m.path.endswith("a.py") for m in (_ffi.run(req, cwd=None) or []))
    (corpus / "a.py").unlink()
    warm = _ffi.run(req, cwd=None)
    assert warm is not None
    assert not any(m.path.endswith("a.py") for m in warm)
    assert warm == engine.run(req, cwd=None)


def test_unsupported_pattern_declines_to_cold(corpus) -> None:
    # A pattern outside gist's linear-time syntax → IRREGEX_STALE → None (the caller
    # answers cold), never a crashed host. This is the property ADR-352 gated on.
    assert _ffi.run(SearchRequest(pattern=r"(?=lookahead)"), cwd=None) is None
    # The Session fails open: it still returns the cold answer for such a pattern.
    with gist.Session(cwd=None) as s:
        assert s.run(SearchRequest(pattern=r"(?=lookahead)", engine="pcre2")) is not None
