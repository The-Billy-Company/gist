"""Cross-language eligibility parity (ADR-352 rung 2.5 · plan Phase 3).

`session.warm_eligible` (a cheap pure-Python predicate on `SearchRequest`) and
`src/runtime/session/request.zig::classify` (the daemon's argv authority) are two
independent projections of ONE contract: which requests the resident path may
answer warm. They take different inputs — request fields vs an rg argv — so they
cannot share code, only agree. This suite is the mechanical guard the plan
demands: it lowers each request to the real argv (`to_argv()` + pattern + paths),
runs the built `gist` binary with `GIST_DEBUG_WARM=1` (which prints the classify
verdict *before* dialing, so the oracle is daemon-independent), and asserts BOTH
sides land on the same DECLARED verdict — so neither can drift, and the test can
never pass by both mislabeling the same shape.
"""

from __future__ import annotations

import os
import shutil
import subprocess

import pytest

import gist
from gist import warm_eligible
from gist.request import SearchEngine, SearchRequest


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
    # A tiny tree so the cold search a rejected argv still runs (after the verdict
    # print) stays instant; the verdict is emitted before any walk regardless.
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n")
    return tmp_path


# Every eligible clause `classify` accepts: literal / caseless / plain-regex, over
# the rootless default tree with no scoping and no rich flag.
_ELIGIBLE: list[SearchRequest] = [
    SearchRequest(pattern="TODO"),
    SearchRequest(pattern="TODO", fixed=True),
    SearchRequest(pattern="TODO", ignore_case=True),
    SearchRequest(pattern="TODO", fixed=True, ignore_case=True),
    SearchRequest(pattern=r"def\s+\w+"),  # plain (linear) regex, still warm
]

# One request per ineligible DIMENSION — every field/scope that must fall to cold,
# plus the pattern-shape boundary (`\n`) that `warm_eligible` used to miss.
_INELIGIBLE: list[SearchRequest] = [
    SearchRequest(pattern="TODO", paths=(".",)),  # even `.` (cold `./`-prefixes)
    SearchRequest(pattern="TODO", paths=("services",)),  # a foreign/subtree root
    SearchRequest(pattern="TODO", globs=("*.py",)),
    SearchRequest(pattern="TODO", iglobs=("*.PY",)),
    SearchRequest(pattern="TODO", types=("py",)),
    SearchRequest(pattern="TODO", not_types=("py",)),
    SearchRequest(pattern="TODO", smart_case=True),
    SearchRequest(pattern="TODO", word=True),
    SearchRequest(pattern="TODO", invert=True),
    SearchRequest(pattern="TODO", hidden=True),
    SearchRequest(pattern="TODO", no_ignore=True),
    SearchRequest(pattern="TODO", follow=True),
    SearchRequest(pattern="TODO", no_index=True),
    SearchRequest(pattern="TODO", before=2),
    SearchRequest(pattern="TODO", after=2),
    SearchRequest(pattern="TODO", context=2),
    SearchRequest(pattern="TODO", max_count=3),
    SearchRequest(pattern="TODO", max_depth=2),
    SearchRequest(pattern="TODO", multiline=True),
    SearchRequest(pattern="TODO", multiline_dotall=True),
    SearchRequest(pattern="TODO", unicode=False),
    SearchRequest(pattern="TODO", unicode=True),
    SearchRequest(pattern="TODO", engine=SearchEngine.AUTO),
    SearchRequest(pattern="TODO", engine=SearchEngine.PCRE2),
    SearchRequest(pattern="TODO", extra_flags=("-P",)),
    SearchRequest(pattern="multi\nline"),  # a `\n` pattern steps outside per-line
]


def _binary_verdict(req: SearchRequest, cwd) -> bool:
    """The built classifier's verdict for `req`, read from `GIST_DEBUG_WARM`.

    Lowers the request to the exact argv the CLI accepts and runs it with
    auto-spawn off (hermetic: no lingering daemon). The `[eligible]` /
    `[ineligible]` line is printed before any dial or walk, so this is the pure
    classify verdict — no daemon required.
    """
    argv = [gist.binary(), *req.to_argv(), req.pattern, *req.paths]
    env = {**os.environ, "GIST_DEBUG_WARM": "1", "GIST_NO_AUTOSERVE": "1"}
    proc = subprocess.run(  # noqa: S603 — trusted binary, list argv, no shell
        argv, cwd=str(cwd), env=env, capture_output=True, text=True
    )
    if "gist: [eligible]" in proc.stderr:
        return True
    if "gist: [ineligible]" in proc.stderr:
        return False
    pytest.fail(f"no classify verdict for {argv!r}: {proc.stderr!r}")


@needs_gist
@pytest.mark.parametrize("req", _ELIGIBLE, ids=lambda r: f"warm:{'|'.join(r.to_argv()) or 'bare'}")
def test_eligible_shapes_agree(corpus, req: SearchRequest) -> None:
    # Both projections must call this WARM — anchoring the suite so it can't pass
    # by both sides declaring everything cold.
    assert warm_eligible(req) is True
    assert _binary_verdict(req, corpus) is True


@needs_gist
@pytest.mark.parametrize(
    "req", _INELIGIBLE, ids=lambda r: f"cold:{'|'.join([*r.to_argv(), *r.paths]) or r.pattern!r}"
)
def test_ineligible_shapes_agree(corpus, req: SearchRequest) -> None:
    # Every rich dimension must fall to cold on BOTH sides.
    assert warm_eligible(req) is False
    assert _binary_verdict(req, corpus) is False


def test_pattern_shape_boundary_is_cold_without_a_binary() -> None:
    # A `\n`/NUL/empty pattern steps outside rg's per-line model (a NUL can't be
    # passed through argv, so it is pinned here only): `warm_eligible` must decline
    # it exactly as `classify` does, independent of any built binary.
    assert warm_eligible(SearchRequest(pattern="a\nb")) is False
    assert warm_eligible(SearchRequest(pattern="a\x00b")) is False
    assert warm_eligible(SearchRequest(pattern="")) is False
