"""Every function `gist._native.CDEF` declares must be spelled as `gist.h` spells it.

The mirror is hand-maintained and cffi resolves an ABI-mode symbol lazily — so a
stale name is invisible until the call, and invisible *entirely* if the tier that
would make the call declines for want of a library. Nothing but a text-to-text
comparison catches it.

This is the gist half of a gate the substrate runs over its own half: `irgx.h`
there, `gist.h` here, each in the repo that publishes the header. Splitting it
that way is what lets either repo's suite run with nothing else checked out.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path

import pytest

from gist import _native

_COMMENT = re.compile(r"/\*.*?\*/|//[^\n]*", re.S)
_LINKAGE = re.compile(r'extern\s*"C"|[{}]')
_TOKEN = re.compile(r"[A-Za-z_]\w*|\*+|\[\]|\.\.\.")
_DECL = re.compile(r"^(?P<ret>[\w\s*]+?)\b(?P<name>\w+)\s*\((?P<params>.*)\)$", re.S)


def _header() -> Path:
    """`include/gist.h`, found at whichever ancestor holds it.

    Probed rather than counted: a source checkout, an editable install, and a
    monorepo vendoring put a different number of directories above this file.
    """
    here = Path(__file__).resolve()
    for base in here.parents:
        if (candidate := base / "include" / "gist.h").is_file():
            return candidate
    return here.parents[3] / "include" / "gist.h"


def _preprocessor_free(source: str) -> str:
    """Drop `#...` directives, continuations included.

    They carry no semicolon, so a `#define` above a declaration would otherwise
    land in the same chunk as the declaration and hide it — and `extern "C" {`
    would hide whichever declaration happens to come first.
    """
    kept, continuing = [], False
    for line in source.splitlines():
        if continuing or line.lstrip().startswith("#"):
            continuing = line.rstrip().endswith("\\")
            continue
        kept.append(line)
    return _LINKAGE.sub(" ", "\n".join(kept))


def _types(params: str) -> tuple[str, ...]:
    """The parameter list reduced to its types, one flat token stream.

    A parameter's trailing identifier is its name — documentation, not contract —
    so it is dropped, while a lone `void` or a type-only parameter is kept whole.
    """
    out: list[str] = []
    for param in params.split(","):
        tokens = _TOKEN.findall(" ".join(param.split()))
        if not tokens:
            continue
        if len(tokens) > 1 and re.fullmatch(r"[A-Za-z_]\w*", tokens[-1]) and tokens[-1] != "void":
            tokens = tokens[:-1]
        out.extend(tokens)
    return tuple(out)


def _functions(source: str) -> dict[str, tuple[str, tuple[str, ...]]]:
    """`{name: (return type, parameter types)}` for every function declared."""
    found: dict[str, tuple[str, tuple[str, ...]]] = {}
    for statement in _preprocessor_free(_COMMENT.sub(" ", source)).split(";"):
        text = " ".join(statement.split())
        if not text or text.startswith("typedef") or "(" not in text:
            continue
        if (match := _DECL.match(text)) is None:
            continue
        found[match["name"]] = (" ".join(match["ret"].split()), _types(match["params"]))
    return found


@functools.cache
def _declared() -> dict[str, tuple[str, tuple[str, ...]]]:
    path = _header()
    if not path.is_file():
        pytest.fail(
            f"include/gist.h not found (looked at {path}). The mirror cannot be checked "
            f"against a header that is not there."
        )
    return _functions(path.read_text(encoding="utf-8"))


@functools.cache
def _mirrored() -> dict[str, tuple[str, tuple[str, ...]]]:
    return _functions(_native.CDEF)


def test_the_mirror_declares_something() -> None:
    """Guard the extractor: a regex that matched nothing would pass every case below."""
    mirrored = _mirrored()
    for anchor in ("gist_open", "gist_search", "gist_search_cursor", "gist_run"):
        assert anchor in mirrored, f"the extractor found no {anchor} in the mirror"


def test_the_mirror_claims_nothing_of_the_substrate() -> None:
    """This half declares gist's symbols only; `irgx_*` belongs to `irgx.contract.abi`.

    The two texts are concatenated at `cdef` time, so a duplicate declaration
    would be a cffi error rather than silent drift — but the reason to keep them
    disjoint is the gate above it: a substrate symbol mirrored here would be
    checked against gist.h, which declares several of them only because it
    consumes them.
    """
    intruders = sorted(n for n in _mirrored() if n.startswith("irgx_"))
    assert not intruders, f"gist's mirror declares substrate symbols: {intruders}"


@pytest.mark.parametrize("name", sorted(_mirrored()))
def test_every_mirrored_function_matches_its_header(name: str) -> None:
    declared = _declared()
    assert name in declared, (
        f"the cffi mirror declares {name}, which gist.h does not. Either it was "
        f"renamed (the mirror is stale) or it never existed (cffi will resolve it "
        f"lazily and fail at the call site instead of here)."
    )
    want_ret, want_params = declared[name]
    got_ret, got_params = _mirrored()[name]
    assert got_params == want_params, (
        f"{name}: the mirror takes {got_params}, the header declares {want_params}"
    )
    assert got_ret == want_ret, (
        f"{name}: the mirror returns {got_ret!r}, the header declares {want_ret!r}"
    )
