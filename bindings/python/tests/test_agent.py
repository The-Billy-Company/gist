"""The agent / code-place adapter maps one request shape (plan step 5).

`request_from_tool` is the single seam that turns a tool-boundary payload —
An agent `fs_search(place, query, glob, context_lines, semantic, at)` or a coding
agent's search call — into the unified `SearchRequest`, while leaving *where the
tree lives* and *how it's ranked* to the place adapter (outside GIST).
"""

from __future__ import annotations

import pytest

from gist import request_from_tool
from irregex.request import SearchRequest


def test_canonical_fields_pass_through() -> None:
    req = request_from_tool({"pattern": "TODO", "paths": ["services"], "ignore_case": True})
    assert req == SearchRequest(pattern="TODO", paths=("services",), ignore_case=True)


def test_fs_search_vocabulary_is_aliased() -> None:
    """`query`/`glob`/`context_lines` are fs_search's names for the canonical
    `pattern`/`globs`/`context` options.
    """
    req = request_from_tool({"query": "panic", "glob": "*.go", "context_lines": 2})
    assert req.pattern == "panic"
    assert req.globs == ("*.go",)
    assert req.context == 2


def test_routing_keys_are_dropped_not_errors() -> None:
    """place/at/semantic select the transport + ranking — the place adapter's
    call, not GIST's. The mapper recognizes and ignores them.
    """
    req = request_from_tool({"query": "foo", "place": "machine", "at": "home", "semantic": True})
    assert req == SearchRequest(pattern="foo")


def test_single_glob_string_becomes_tuple() -> None:
    assert request_from_tool({"pattern": "x", "globs": "*.py"}).globs == ("*.py",)
    assert request_from_tool({"pattern": "x", "globs": ["*.py", "*.pyi"]}).globs == (
        "*.py",
        "*.pyi",
    )


def test_missing_pattern_is_a_loud_error() -> None:
    """agent.py: pattern|query must be non-empty — no silent default."""
    with pytest.raises(ValueError, match="non-empty") as missing:
        request_from_tool({"glob": "*.py"})
    assert "pattern" in str(missing.value)
    with pytest.raises(ValueError, match="non-empty"):
        request_from_tool({"query": ""})


def test_unknown_option_is_a_loud_error() -> None:
    """A typo can't silently no-op a scoped search — but a routing key is fine."""
    with pytest.raises(ValueError, match="unknown search option") as exc:
        request_from_tool({"pattern": "x", "gloob": "*.py"})
    assert "gloob" in str(exc.value)
    # Routing keys remain ignored (place adapter owns them), not hard errors.
    assert request_from_tool({"pattern": "x", "place": "machine"}) == SearchRequest(pattern="x")


def test_alias_and_canonical_agree() -> None:
    """`query` and `pattern` produce the identical request."""
    assert request_from_tool({"query": "z"}) == request_from_tool({"pattern": "z"})
