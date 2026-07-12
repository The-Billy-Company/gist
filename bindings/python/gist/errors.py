"""Typed failures for the GIST search API (ADR-352).

Every failure is a value a caller can catch — a bad pattern never terminates the
host process the way the engine's own CLI `die()`/exit would in-process.
"""

from __future__ import annotations


class GistError(Exception):
    """Base for every GIST search failure."""


class GistNotFoundError(GistError):
    """The `gist` binary could not be located (env `GIST_BIN`, PATH, or the
    repo's `zig-out/bin/gist`). Build it with `make install-gist`."""


class UnsupportedPatternError(GistError):
    """The pattern or flag combination is outside GIST's linear-time engine
    (e.g. PCRE2 lookaround/backreferences, `-U` multiline) — the engine exited 2
    and named the ripgrep fallback on stderr."""


class SearchFailedError(GistError):
    """The engine exited 2 for an I/O or walk reason (an unreadable directory,
    a missing explicit path) — fail-loud, never a silent empty result."""
