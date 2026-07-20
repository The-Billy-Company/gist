"""In-process FFI transport parity (ADR-352 rung 3).

Proves the cffi transport (`gist/_ffi.py` over `libirregex`) is byte-identical to
the certified cold subprocess — same `run`/`files`/`count` answers, same record
ORDER, same submatch offsets — and that it reconciles writes (read-your-writes)
and declines an unsupported pattern to cold instead of aborting. Since the cold
path is itself certified against ripgrep, FFI ≡ cold ≡ rg transitively.

Skipped when the shared library or `cffi` is unavailable: the in-process
transport is an OPTIONAL accelerator; the package stays pure-Python without it.
Each test `chdir`s into a fresh corpus because relative FFI roots resolve from
the process CWD — the exact base a cold run with `cwd` set there uses, so paths
agree without binding-side normalization.
"""

from __future__ import annotations

import pytest

import irregex
from irregex import _ffi, engine
from irregex.request import SearchEngine, SearchRequest


pytestmark = pytest.mark.skipif(not _ffi.available(), reason="libirregex/cffi unavailable")


@pytest.fixture
def corpus(tmp_path, monkeypatch):
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n# TODO trailing\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\nplain text\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("x = 1  # todo lowercase\nTODO upper TODO twice\n")
    # -w adverse shapes: substring hits, rejected-then-valid on one line,
    # -F adjacent repeats, Unicode neighbors, and a punctuation-only match.
    (tmp_path / "w.txt").write_text("run runner\nrerun run\naa aaa\naaaa\nérun 中run\na . b\n.dot\n")
    (tmp_path / "unicode.txt").write_text("café\nCAFÉ\n")
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
        SearchRequest(pattern="run", fixed=True, word=True),  # -F -w occurrence filter
        SearchRequest(pattern="run", word=True),  # regex-body -w span filter
        SearchRequest(pattern="run", ignore_case=True, word=True),  # -w composes with -i
        SearchRequest(pattern="aa", fixed=True, word=True),  # adjacent repeats, non-overlap
        SearchRequest(pattern=r"\.", word=True),  # punctuation-only word match
        SearchRequest(pattern="x*", word=True),  # zero-width spans never word-match
        SearchRequest(pattern="TODO", max_count=1),  # per-file line cap
        SearchRequest(pattern="TODO", max_count=0),  # explicit match-nothing
        SearchRequest(pattern="TODO", quiet=True),  # existence-only, no records
        SearchRequest(pattern="todo", smart_case=True),  # lowercase folds
        SearchRequest(pattern="TODO", smart_case=True),  # uppercase stays exact
        SearchRequest(pattern="café", fixed=True, ignore_case=True, unicode=True),
        SearchRequest(pattern="café", fixed=True, ignore_case=True, unicode=False),
        SearchRequest(pattern="run", fixed=True, word=True, unicode=False),
        SearchRequest(pattern="TODO", engine=SearchEngine.AUTO),
        SearchRequest(pattern="TODO", invert=True),
        SearchRequest(pattern="TODO", invert=True, max_count=1),
        SearchRequest(pattern="TODO", before=1),
        SearchRequest(pattern="TODO", after=1),
        SearchRequest(pattern="TODO", context=1),
        SearchRequest(pattern="TODO", invert=True, context=1),
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
    ci_count, plain_count = _ffi.count(ci, cwd=None), _ffi.count(req, cwd=None)
    assert ci_count is not None
    assert plain_count is not None
    assert ci_count > plain_count  # -i pulls in 'todo'


@pytest.mark.parametrize(
    "req",
    [
        SearchRequest(pattern="TODO", max_count=1),
        SearchRequest(pattern="TODO", max_count=0),
        SearchRequest(pattern="TODO", quiet=True),
    ],
)
def test_quiet_and_max_count_faces_equal_cold(corpus, req: SearchRequest) -> None:
    assert _ffi.files(req, cwd=None) == engine.files(req, cwd=None)
    assert _ffi.count(req, cwd=None) == engine.count(req, cwd=None)


@pytest.mark.parametrize(
    "req",
    [
        SearchRequest(pattern="TODO", invert=True),
        SearchRequest(pattern="TODO", invert=True, max_count=1),
        SearchRequest(pattern="TODO", invert=True, quiet=True),
        SearchRequest(pattern=r".*", invert=True),
        SearchRequest(pattern="absent_needle_xyzzy", invert=True),
    ],
)
def test_invert_faces_equal_cold(corpus, req: SearchRequest) -> None:
    assert _ffi.run(req, cwd=None) == engine.run(req, cwd=None)
    assert _ffi.files(req, cwd=None) == engine.files(req, cwd=None)
    assert _ffi.count(req, cwd=None) == engine.count(req, cwd=None)


@pytest.mark.parametrize(
    "req",
    [
        SearchRequest(pattern="TODO", context=2),
        SearchRequest(pattern="TODO", before=1, context=3),
        SearchRequest(pattern="TODO", after=1, max_count=1),
        SearchRequest(pattern="TODO", invert=True, context=1),
    ],
)
def test_context_is_stream_only_and_all_faces_equal_cold(corpus, req: SearchRequest) -> None:
    assert _ffi.run(req, cwd=None) == engine.run(req, cwd=None)
    assert _ffi.files(req, cwd=None) == engine.files(req, cwd=None)
    assert _ffi.count(req, cwd=None) == engine.count(req, cwd=None)


def test_word_files_and_count_equal_cold(corpus) -> None:
    word = SearchRequest(pattern="run", fixed=True, word=True)
    assert _ffi.files(word, cwd=None) == engine.files(word, cwd=None)
    assert _ffi.count(word, cwd=None) == engine.count(word, cwd=None)
    # -w strictly narrows the plain answer (`runner`/`rerun`/`érun` lines drop).
    plain = SearchRequest(pattern="run", fixed=True)
    plain_count, word_count = _ffi.count(plain, cwd=None), _ffi.count(word, cwd=None)
    assert plain_count is not None
    assert word_count is not None
    assert plain_count > word_count


def test_smart_case_resolves_in_engine(corpus) -> None:
    folded = SearchRequest(pattern="todo", smart_case=True)
    exact = SearchRequest(pattern="TODO", smart_case=True)
    assert _ffi.count(folded, cwd=None) == engine.count(folded, cwd=None)
    assert _ffi.count(exact, cwd=None) == engine.count(exact, cwd=None)
    folded_count, exact_count = _ffi.count(folded, cwd=None), _ffi.count(exact, cwd=None)
    assert folded_count is not None
    assert exact_count is not None
    assert folded_count > exact_count


def test_explicit_unicode_mode_resolves_in_engine(corpus) -> None:
    unicode = SearchRequest(pattern="café", fixed=True, ignore_case=True, unicode=True)
    ascii = SearchRequest(pattern="café", fixed=True, ignore_case=True, unicode=False)
    assert _ffi.count(unicode, cwd=None) == engine.count(unicode, cwd=None) == 2
    assert _ffi.count(ascii, cwd=None) == engine.count(ascii, cwd=None) == 1

    unicode_word = SearchRequest(pattern="run", fixed=True, word=True, unicode=True)
    ascii_word = SearchRequest(pattern="run", fixed=True, word=True, unicode=False)
    assert _ffi.count(unicode_word, cwd=None) == engine.count(unicode_word, cwd=None)
    assert _ffi.count(ascii_word, cwd=None) == engine.count(ascii_word, cwd=None)
    ascii_count = _ffi.count(ascii_word, cwd=None)
    unicode_count = _ffi.count(unicode_word, cwd=None)
    assert ascii_count is not None
    assert unicode_count is not None
    assert ascii_count > unicode_count


@pytest.mark.parametrize("paths", [("pkg",), (".",), ("a.py",)])
def test_explicit_roots_equal_cold(corpus, paths: tuple[str, ...]) -> None:
    req = SearchRequest(pattern="TODO", paths=paths)
    warm = _ffi.run(req, cwd=None)
    assert warm is not None
    assert warm == engine.run(req, cwd=None)
    assert _ffi.files(req, cwd=None) == engine.files(req, cwd=None)
    assert _ffi.count(req, cwd=None) == engine.count(req, cwd=None)


def test_absolute_root_equals_cold_and_handle_scope_isolated(corpus) -> None:
    scoped = SearchRequest(pattern="TODO", paths=(str(corpus / "pkg"),))
    rootless = SearchRequest(pattern="TODO")
    assert _ffi.run(scoped, cwd=None) == engine.run(scoped, cwd=None)
    scoped_count = _ffi.count(scoped, cwd=None)
    rootless_count = _ffi.count(rootless, cwd=None)
    assert scoped_count is not None
    assert rootless_count is not None
    assert scoped_count == engine.count(scoped, cwd=None)
    assert rootless_count == engine.count(rootless, cwd=None)
    assert rootless_count > scoped_count


def test_explicit_root_handle_cache_is_bounded(corpus) -> None:
    for i in range(_ffi._MAX_HANDLES + 2):
        root = corpus / f"scope-{i}"
        root.mkdir()
        (root / "one.txt").write_text("no marker\n")
        assert _ffi.count(SearchRequest(pattern="TODO", paths=(str(root),)), cwd=None) == 0
    assert len(_ffi._handles) <= _ffi._MAX_HANDLES


def test_session_run_is_warm_and_matches_cold(corpus) -> None:
    # `Session.run` gains a warm transport for the first time (UDS only ever did
    # files/count) — it must equal the cold `--json` matches exactly.
    with irregex.Session(cwd=None) as s:
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
    with irregex.Session(cwd=None) as s:
        req = SearchRequest(pattern=r"(?=lookahead)", engine=SearchEngine.PCRE2)
        assert s.run(req) is not None


def test_auto_uses_ffi_only_for_linear_compatible_patterns(corpus) -> None:
    linear = SearchRequest(pattern="TODO", engine=SearchEngine.AUTO)
    assert _ffi.run(linear, cwd=None) == engine.run(linear, cwd=None)

    pcre = SearchRequest(pattern=r"(?=lookahead)", engine=SearchEngine.AUTO)
    assert _ffi.run(pcre, cwd=None) is None
    with irregex.Session(cwd=None) as session:
        assert session.run(pcre) == engine.run(pcre, cwd=None)
