"""Cross-language eligibility parity (ADR-352 rung 2.5).

`session.warm_eligible` (a cheap pure-Python predicate on `SearchRequest`) and
`src/surface/exec/session/request.zig::classify` (the daemon's argv authority) are two
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

import irregex
from irregex import warm_eligible
from irregex.request import SearchEngine, SearchRequest
from irregex.session import ffi_eligible


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
def corpus(tmp_path):
    # A tiny tree so the cold search a rejected argv still runs (after the verdict
    # print) stays instant; the verdict is emitted before any walk regardless.
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n")
    return tmp_path


# Every eligible clause `classify` accepts: literal / caseless / plain-regex, over
# the rootless default tree with no scoping and no rich flag. v2: smart_case is
# UDS-eligible (the raw bit crosses the wire; the Zig session resolves it) —
# with an uppercase AND a lowercase pattern, since the verdict must not depend
# on the resolution (that happens server-side, at compile time).
_ELIGIBLE: list[SearchRequest] = [
    SearchRequest(pattern="TODO"),
    SearchRequest(pattern="TODO", fixed=True),
    SearchRequest(pattern="TODO", ignore_case=True),
    SearchRequest(pattern="TODO", fixed=True, ignore_case=True),
    SearchRequest(pattern=r"def\s+\w+"),  # plain (linear) regex, still warm
    SearchRequest(pattern="TODO", smart_case=True),  # uppercase → resolves sensitive
    SearchRequest(pattern="todo", smart_case=True),  # lowercase → resolves caseless
    SearchRequest(pattern="todo", fixed=True, smart_case=True),
    # v2 lane 2: -w is warm-eligible (the session applies cold's post-match
    # word rule), alone and composed with -F / -i / -S.
    SearchRequest(pattern="TODO", word=True),
    SearchRequest(pattern="TODO", fixed=True, word=True),
    SearchRequest(pattern="todo", ignore_case=True, word=True),
    SearchRequest(pattern="todo", smart_case=True, word=True),
    # v2 lane 4: -q (existence early-halt) and -m N/-m0 (per-file cap) are
    # UDS-eligible — the session halts at the first match / caps per file, and
    # `-m0` short-circuits to the cold-mirrored no-match. Alone and composed.
    SearchRequest(pattern="TODO", quiet=True),
    SearchRequest(pattern="TODO", fixed=True, quiet=True),
    SearchRequest(pattern="todo", ignore_case=True, quiet=True),
    SearchRequest(pattern="TODO", word=True, quiet=True),
    SearchRequest(pattern="TODO", max_count=3),
    SearchRequest(pattern="TODO", max_count=1),
    SearchRequest(pattern="TODO", max_count=0),  # rg's `-m0`: matches nothing
    SearchRequest(pattern="todo", ignore_case=True, max_count=2),
    SearchRequest(pattern="TODO", word=True, max_count=2),
    # v2 lane 3b: -v is warm-eligible (the session answers the `lines(f) −
    # matches(f)` set-complement, sound under the trigram index), alone and
    # composed with -F / -i / -w / -m N across every mode.
    SearchRequest(pattern="TODO", invert=True),
    SearchRequest(pattern="TODO", fixed=True, invert=True),
    SearchRequest(pattern="todo", ignore_case=True, invert=True),
    SearchRequest(pattern="TODO", word=True, invert=True),
    SearchRequest(pattern="TODO", invert=True, max_count=2),
]

# Cold on BOTH sides — a dimension neither the pure predicate nor the built
# classifier serves warm, plus the pattern-shape boundary (`\n`) `warm_eligible`
# used to miss. (`.` is cold because cold `./`-prefixes it; `--iglob`/`-T`/
# `--hidden`/`-uu`/`-L`/`--no-index`/`--max-depth`/multiline/explicit-unicode/
# `--engine=auto` all sit outside `classify`'s fast path — see `request.zig`.)
_INELIGIBLE: list[SearchRequest] = [
    SearchRequest(pattern="TODO", paths=(".",)),  # even `.` (cold `./`-prefixes)
    SearchRequest(pattern="TODO", iglobs=("*.PY",)),
    SearchRequest(pattern="TODO", not_types=("py",)),
    SearchRequest(pattern="TODO", hidden=True),
    SearchRequest(pattern="TODO", no_ignore=True),
    SearchRequest(pattern="TODO", follow=True),
    SearchRequest(pattern="TODO", no_index=True),
    SearchRequest(pattern="TODO", max_depth=2),
    SearchRequest(pattern="TODO", multiline=True),
    SearchRequest(pattern="TODO", multiline_dotall=True),
    SearchRequest(pattern="TODO", unicode=False),
    SearchRequest(pattern="TODO", unicode=True),
    SearchRequest(pattern="TODO", engine=SearchEngine.AUTO),
    SearchRequest(pattern="multi\nline"),  # a `\n` pattern steps outside per-line
]

# The one-directional gap: dimensions the built classifier (and the daemon it
# gates) DO serve warm — scoped roots, `-g` globs, `-t` types, `-A`/`-B`/`-C`
# context, and `-P`/`--pcre2` — but which the pure-Python UDS `warm_eligible`
# predicate deliberately declines (`session.py::_INELIGIBLE_FIELDS`, mirrored by
# `bindings/rust` and `tests/test_session.py::test_warm_eligible_rejects_rich_requests`).
# Declining is SOUND: `warm_eligible ⟹ classify eligible` is the safety-critical
# direction (never send the daemon a warm query it must decline), and a declined
# request is answered on the certified cold path — or, for roots/context, in
# process via the wider FFI predicate (`ffi_eligible`). The reverse (warm serves
# everything the binary does) is an optimization, not a correctness property, so
# the UDS predicate keeps a narrow, table-free surface: `-t` alone would force
# the ~230-row Zig type registry (`corpus/scope/types.zig`) into the binding,
# a cross-language duplication that would drift. This list mechanically guards
# the subset in BOTH directions — narrowing the binary, or widening the
# predicate to serve one of these, trips the assertion and demands the pair move
# together.
_BINDING_COLD_BINARY_WARM: list[SearchRequest] = [
    SearchRequest(pattern="TODO", paths=("services",)),  # a clean relative subtree root
    SearchRequest(pattern="TODO", globs=("*.py",)),  # `-g` include glob
    SearchRequest(pattern="TODO", types=("py",)),  # `-t` type scope (Zig-only registry)
    SearchRequest(pattern="TODO", before=2),  # `-B` context
    SearchRequest(pattern="TODO", after=2),  # `-A` context
    SearchRequest(pattern="TODO", context=2),  # `-C` context
    SearchRequest(pattern="TODO", engine=SearchEngine.PCRE2),  # `-P` PCRE2 engine
    SearchRequest(pattern="TODO", extra_flags=("-P",)),  # raw `-P` argv
]


def _binary_verdict(req: SearchRequest, cwd) -> bool:
    """The built classifier's verdict for `req`, read from `GIST_DEBUG_WARM`.

    Lowers the request to the exact argv the CLI accepts and runs it with
    auto-spawn off (hermetic: no lingering daemon). The `[eligible]` /
    `[ineligible]` line is printed before any dial or walk, so this is the pure
    classify verdict — no daemon required.
    """
    argv = [irregex.binary(), *req.to_argv(), req.pattern, *req.paths]
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


@needs_gist
@pytest.mark.parametrize(
    "req",
    _BINDING_COLD_BINARY_WARM,
    ids=lambda r: f"gap:{'|'.join([*r.to_argv(), *r.paths]) or r.pattern!r}",
)
def test_binding_declines_what_binary_serves_warm(corpus, req: SearchRequest) -> None:
    # The sound one-directional gap: the pure UDS predicate declines (→ cold /
    # FFI) exactly where the built classifier would serve warm. Guarded in BOTH
    # directions — if the binary is narrowed to decline one of these, or the
    # predicate widened to accept one, this fails and the pair must move to the
    # matching list together (never silently drift).
    assert warm_eligible(req) is False
    assert _binary_verdict(req, corpus) is True


def test_pattern_shape_boundary_is_cold_without_a_binary() -> None:
    # A `\n`/NUL/empty pattern steps outside rg's per-line model (a NUL can't be
    # passed through argv, so it is pinned here only): `warm_eligible` must decline
    # it exactly as `classify` does, independent of any built binary.
    assert warm_eligible(SearchRequest(pattern="a\nb")) is False
    assert warm_eligible(SearchRequest(pattern="a\x00b")) is False
    assert warm_eligible(SearchRequest(pattern="")) is False


def test_ffi_predicate_extends_uds_with_roots_unicode_and_auto() -> None:
    # The in-process options ABI carries the complete UDS request subset, and
    # irregex_open additionally accepts explicit root arrays.
    smart = SearchRequest(pattern="todo", smart_case=True)
    assert warm_eligible(smart) is True
    assert ffi_eligible(smart) is True
    # -w IS lowered into the C flags (IRREGEX_WORD), so it stays FFI-eligible.
    assert ffi_eligible(SearchRequest(pattern="TODO", word=True)) is True
    # The size-checked options entry safely lowers -q and -m N, including
    # falsy -m0; none may be lost to a truthiness sweep.
    for ffi_option in (
        SearchRequest(pattern="TODO", quiet=True),
        SearchRequest(pattern="TODO", max_count=3),
        SearchRequest(pattern="TODO", max_count=0),
    ):
        assert warm_eligible(ffi_option) is True
        assert ffi_eligible(ffi_option) is True
    for req in _ELIGIBLE:
        assert ffi_eligible(req) is warm_eligible(req)
    # The FFI options ABI + `irregex_open` root array extend the UDS subset with
    # invert, `-A`/`-B`/`-C` context, explicit roots, explicit Unicode, and the
    # linear arm of `engine="auto"` — but NOT `-g`/`-t` globs (no glob ABI) or
    # `-P` (no PCRE ABI), so those stay FFI-cold even though the daemon serves
    # them warm. The predicate agrees on that split for every cold-BOTH and
    # binding-cold-binary-warm dimension.
    for req in (*_INELIGIBLE, *_BINDING_COLD_BINARY_WARM):
        ffi_extension = (
            req.invert
            or bool(req.before or req.after or req.context)
            or bool(req.paths)
            or req.unicode is not None
            or req.engine is SearchEngine.AUTO
        )
        assert ffi_eligible(req) is ffi_extension
    assert ffi_eligible(SearchRequest(pattern="TODO", paths=("",))) is False
    assert ffi_eligible(SearchRequest(pattern="TODO", paths=("bad\x00root",))) is False
