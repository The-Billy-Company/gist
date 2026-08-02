"""The mirror in `gist._contract` must not drift from `contract/surface.toml`,
nor the routed producer from the header that declares it.

These claims are about *gist* — its published names, its agent seam, its `gist.h`
— so they are gated here, in the repo that owns all three. They used to run in
the substrate's suite, which meant the engine could not test itself without a
gist checkout beside it to read the canonical file and the header from.

Reading the contract **fails closed**. An installed wheel legitimately ships
without the repo file, but a test run happens in a checkout, and a locator that
silently resolves to a path which stopped existing turns every assertion below
into a no-op behind a green suite.
"""

from __future__ import annotations

import functools
import shutil
import tomllib

import pytest

from gist import _contract, _native
from irgx.contract import abi as substrate
from irgx.runtime import analytic as analytic_runtime
from irgx.runtime import shell as engine
from irgx.runtime.errors import GistNotFoundError


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        engine.binary()
    except GistNotFoundError:
        return False
    return True


_HAVE_BINARY = _binary_available()


@functools.cache
def _surface() -> dict:
    path = _contract.contract_path("surface")
    if not path.is_file():
        raise AssertionError(
            f"contract surface.toml not found at {path}; the parity gate cannot run without it"
        )
    with path.open("rb") as f:
        return tomllib.load(f)


@functools.cache
def _analytic() -> dict:
    """The substrate's analytic contract, which is what routes a verb to a producer."""
    path = substrate.contract_path("analytic")
    if not path.is_file():
        raise AssertionError(f"contract analytic.toml not found at {path}")
    with path.open("rb") as f:
        return tomllib.load(f)["analytic"]


def test_package_names_mirror_toml() -> None:
    package = _surface()["package"]
    assert package["dist"] == _contract.PACKAGE_DIST
    assert package["import"] == _contract.PACKAGE_IMPORT


def test_tool_boundary_mirror_matches_toml() -> None:
    boundary = _surface()["tool_boundary"]
    assert boundary["aliases"] == _contract.ALIASES
    assert frozenset(boundary["routing_keys"]) == _contract.ROUTING_KEYS


def test_routing_keys_are_not_request_options() -> None:
    """A recognized-but-ignored key that is also a real option would be silently honored."""
    assert _contract.ROUTING_KEYS.isdisjoint(substrate.REQUEST_OPTIONS)


def test_gists_own_producer_is_a_symbol_its_header_declares() -> None:
    """`gist_run` is spelled the same in the contract and in `include/gist.h`.

    Contract-versus-generated-table parity cannot catch a misspelling, because
    both sides are lowered from the same string: a typo'd `gist_runn` agrees with
    itself and then resolves to nothing at run time, silently demoting the verb to
    the subprocess tier forever. Only a second, independent spelling can catch it,
    and the header is one.
    """
    producers = _analytic()["producers"]
    header = (
        _contract.contract_path("surface").parent.parent / "include" / producers["gist"]["header"]
    )
    if not header.is_file():
        raise AssertionError(
            f"{header} not found; the gate cannot check the entry symbol's spelling"
        )
    declared = header.read_text(encoding="utf-8")
    assert f"{producers['gist']['entry']}(" in declared, (
        f"the contract routes verbs to {producers['gist']['entry']}, which {header.name} does not declare"
    )


@pytest.mark.skipif(not _native.available(), reason="libgist/cffi unavailable")
def test_every_gist_verb_resolves_in_the_loaded_library() -> None:
    """Each entry symbol the contract routes to gist is really exported by libgist.

    A symbol that resolves to nothing is not an error at any layer — the ladder
    reads it as a declinature and answers cold — so nothing but an assertion
    notices. This is the check that `libgist` is a real library rather than a thin
    one: its own producer is not optional the way a sibling's is.
    """
    plane = analytic_runtime._plane("gist")
    assert plane is not None, "libgist loaded but exports no analytic plane"
    _ffi, lib = plane
    analytic = _analytic()
    gist_entry = analytic["producers"]["gist"]["entry"]
    assert hasattr(lib, gist_entry), f"the loaded library exports no {gist_entry}"
    for verb, spec in analytic["verbs"].items():
        if spec["producer"] != "gist":
            continue
        assert hasattr(lib, analytic_runtime._run_symbol(verb)), f"{verb} routes nowhere"


@pytest.mark.skipif(not _HAVE_BINARY, reason="no gist binary available")
def test_engine_version_matches_contract() -> None:
    """The driven binary is the engine this package mirrors, not some other build."""
    assert engine.version() == substrate.ENGINE_VERSION
