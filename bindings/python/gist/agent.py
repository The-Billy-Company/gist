"""Agent-facing request mapping (ADR-352).

Billy operating a user's machine and a coding agent working a repository are the
same actor; both express "find these matches in this tree" as one
`SearchRequest`. This module maps the loosely-typed request an agent tool
forwards (a plain dict, as it arrives over a tool boundary) into that one shape.

It deliberately does **not** execute or route: *where* the repository lives —
this host, a sandbox, or a bridged user machine — is the tool layer's
place-routing decision. One semantic API does not require one transport
(ADR-352). Local callers hand the mapped request straight to `gist.run`; a
place-routed caller ships the identical request to the owning machine.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from .contract import ALIASES, REQUEST_OPTIONS, ROUTING_KEYS
from .request import SearchRequest


if TYPE_CHECKING:
    from collections.abc import Mapping


_LIST_FIELDS = frozenset({"paths", "globs", "iglobs", "types", "not_types"})


def request_from_tool(payload: Mapping[str, object]) -> SearchRequest:
    """Build a `SearchRequest` from an agent / code-place tool payload.

    Billy's `fs_search(place, query, glob, context_lines, semantic, at)` and a
    coding agent's search call are the same actor asking "find these matches in
    this tree". This normalizes that request into the one `SearchRequest`:

    - **aliases** (`query`→`pattern`, `glob`→`globs`, `context_lines`→`context`)
      let the tool's own vocabulary map straight in;
    - **routing keys** (`place`, `at`, `semantic`) are recognized and *dropped* —
      *where* the tree lives and *how* it's ranked is the place adapter's call,
      not GIST's (one semantic API, many transports);
    - any other unknown key is a hard error, so a typo can't silently no-op a
      scoped search.

    List-valued options accept a single string or an iterable of strings.
    """
    normalized: dict[str, object] = {}
    for raw_key, value in payload.items():
        if raw_key in ROUTING_KEYS:
            continue  # place/transport routing lives outside GIST
        key = ALIASES.get(raw_key, raw_key)
        normalized[key] = value

    if not normalized.get("pattern"):
        msg = "search request requires a non-empty 'pattern' (or 'query')"
        raise ValueError(msg)
    unknown = set(normalized) - REQUEST_OPTIONS
    if unknown:
        msg = f"unknown search option(s): {sorted(unknown)}"
        raise ValueError(msg)

    kwargs: dict[str, object] = {}
    for key, value in normalized.items():
        if key in _LIST_FIELDS:
            kwargs[key] = (value,) if isinstance(value, str) else tuple(value)
        else:
            kwargs[key] = value
    return SearchRequest(**kwargs)
