"""The engine's `--rank` view, surfaced into Python.

Two layers. The pure layer drives the scrape + schema decode over captured rank rows —
no binary, so it pins the row grammar (rank index, `path:line`, `[def|use|gen]`,
the per-file count, snippet) and the `def`/`use`/`gen` classification exactly. The
integration layer builds a throwaway index and asserts `gist.rank` reads it back
with the engine's own classification — never a Python reclassifier.
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

import gist
from irgx.request import Ranked, RankKind
from irgx.runtime.decode import records
from irgx.runtime.shell import _scrape_rank


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        gist.binary()
    except gist.GistNotFoundError:
        return False
    return True


def _ranked(stream: str) -> list[Ranked]:
    """The rendered block through the tier it actually travels: scrape to `ranked` rows, then the one generic decoder."""
    return list(records(_scrape_rank(stream)))


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")


# A captured `--rank` stdout block (rank.zig's exact ` N. path:line  [kind]  <count>  snippet`).
_SAMPLE = (
    " 1. bindings/rust/src/request.rs:33  [def]  \u00d711  pub struct SearchRequest {\n"
    " 2. bindings/rust/tests/session.rs:15  [use]  \u00d719  use gist::{SearchRequest};\n"
    " 3. src/server/api/internal/pb/search.pb.go:2227  [gen]  \u00d752  type SearchRequest struct {\n"
)


# ─────────────────────────── pure parser (no binary) ───────────────────────────


def test_parse_rank_reads_every_field() -> None:
    rows = _ranked(_SAMPLE)
    assert len(rows) == 3
    first = rows[0]
    assert first == Ranked(
        path="bindings/rust/src/request.rs",
        line_number=33,
        kind=RankKind.DEF,
        count=11,
        snippet="pub struct SearchRequest {",
    )


def test_parse_rank_classifies_kinds() -> None:
    assert [r.kind for r in _ranked(_SAMPLE)] == [RankKind.DEF, RankKind.USE, RankKind.GEN]


def test_generated_property_flags_only_gen() -> None:
    rows = _ranked(_SAMPLE)
    assert [r.generated for r in rows] == [False, False, True]
    assert [r.path for r in rows if not r.generated] == [
        r.path for r in rows if r.kind is not RankKind.GEN
    ]


def test_parse_rank_ignores_the_stderr_timing_and_blanks() -> None:
    """Timing goes to stderr; stdout is rows only, but a defensive parse must
    still skip any non-row line rather than mis-parse it.
    """
    noisy = _SAMPLE + "\n— 3 ranked matches (top 3) · read 24/26456 candidates · total 48.4 ms\n"
    assert len(_ranked(noisy)) == 3


# ─────────────────────────── integration (real engine + index) ───────────────────────────


@pytest.fixture
def indexed_corpus(tmp_path):
    """A corpus under a real default root (`libs/`) with a freshly built index,
    so `--rank` has the structure it reads. Returns the cwd to search from.
    """
    lib = tmp_path / "libs" / "pkg"
    lib.mkdir(parents=True)
    (tmp_path / "libs" / "a.py").write_text("def widget():\n    return TODO\n")
    (lib / "b.py").write_text("x = TODO\nTODO again\n")
    build = subprocess.run(  # noqa: S603 — fixed argv, no shell
        [gist.binary(), "index"], cwd=tmp_path, capture_output=True, text=True, check=False
    )
    if build.returncode != 0:
        pytest.skip(f"index build failed: {build.stderr.strip()}")
    return tmp_path


@needs_gist
def test_rank_reads_the_index_with_engine_classification(indexed_corpus) -> None:
    rows = gist.rank("TODO", cwd=indexed_corpus, limit=10)
    assert rows, "expected ranked rows over the built index"
    assert all(isinstance(r, Ranked) for r in rows)
    assert all(isinstance(r.kind, RankKind) for r in rows)
    # b.py has two TODOs → it ranks ahead of a.py's one on lexical density.
    assert rows[0].path.endswith("pkg/b.py")
    assert rows[0].count == 2


@needs_gist
def test_rank_forwards_search_options(indexed_corpus) -> None:
    """A `def widget` search resolves the definition; the option flows through."""
    rows = gist.rank("widget", cwd=indexed_corpus, limit=5)
    assert any(r.path.endswith("a.py") and r.kind is RankKind.DEF for r in rows)


@needs_gist
def test_rank_without_index_live_ranks(tmp_path) -> None:
    """No persisted index falls back to the same live corpus, never emptiness."""
    (tmp_path / "libs").mkdir()
    (tmp_path / "libs" / "a.py").write_text("TODO here\n")
    rows = gist.rank("TODO", cwd=tmp_path, limit=5)
    assert len(rows) == 1
    assert rows[0].path == "libs/a.py"
    assert rows[0].count == 1
    assert rows[0].snippet == "TODO here"
