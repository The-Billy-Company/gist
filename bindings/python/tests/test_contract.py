"""The contract mirror in `irregex.contract` must not drift from the canonical
`contract/search_api.toml`, nor from the driven binary (ADR-352).
"""

from __future__ import annotations

import shutil
import tomllib

import pytest

import irregex
from irregex import contract
from irregex.request import SearchRequest


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        irregex.binary()
    except irregex.GistNotFoundError:
        return False
    return True


_HAVE_BINARY = _binary_available()


def _load_toml() -> dict:
    path = contract.contract_path()
    if not path.is_file():
        pytest.skip(f"canonical contract TOML not present at {path}")
    with path.open("rb") as f:
        return tomllib.load(f)


def test_meta_mirror_matches_toml() -> None:
    meta = _load_toml()["meta"]
    assert meta["abi_version"] == contract.ABI_VERSION
    assert meta["engine_version"] == contract.ENGINE_VERSION
    assert meta["package_dist"] == contract.PACKAGE_DIST
    assert meta["package_import"] == contract.PACKAGE_IMPORT


def test_request_options_mirror_matches_toml() -> None:
    toml = _load_toml()
    assert frozenset(toml["request_options"]) == contract.REQUEST_OPTIONS


def test_request_options_match_dataclass_fields() -> None:
    """Every contract option is a real `SearchRequest` field, and every request
    field (bar the escape hatch) is a contract option.
    """
    fields = set(SearchRequest.__dataclass_fields__) - {"extra_flags"}
    assert fields == contract.REQUEST_OPTIONS


def test_match_kinds_and_exit_codes_mirror_toml() -> None:
    toml = _load_toml()
    assert frozenset(toml["match_kinds"]) == contract.MATCH_KINDS
    codes = toml["exit_codes"]
    assert codes["matched"]["code"] == contract.EXIT_MATCHED
    assert codes["no_match"]["code"] == contract.EXIT_NO_MATCH
    assert codes["error"]["code"] == contract.EXIT_ERROR


def test_tool_boundary_mirror_matches_toml() -> None:
    """The agent / code-place seam (aliases + routing keys) must not drift."""
    boundary = _load_toml()["tool_boundary"]
    assert boundary["aliases"] == contract.ALIASES
    assert frozenset(boundary["routing_keys"]) == contract.ROUTING_KEYS
    # Every alias target is a real request option; routing keys are not options.
    assert set(contract.ALIASES.values()) <= contract.REQUEST_OPTIONS
    assert contract.ROUTING_KEYS.isdisjoint(contract.REQUEST_OPTIONS)


@pytest.mark.skipif(not _HAVE_BINARY, reason="no gist binary available")
def test_engine_version_matches_contract() -> None:
    assert irregex.version() == contract.ENGINE_VERSION
