"""Idiomatic in-process `Engine` / `Cursor` over the pull-cursor C ABI (ADR-352).

The top-level `irregex.search(...)` helpers answer a *one-shot* query and pick a
transport (in-process FFI when eligible, else the certified subprocess). This
module is the other shape a host wants: a **warm engine held open** across many
queries, each producing a **pull `Cursor`** the caller iterates at its own pace.

It drives the pull-cursor symbols (`irregex_engine_open` / `irregex_search_cursor`
/ `irregex_cursor_next` / `_next_batch` / `_close`, plus `irregex_cancel_*`) — the
callback-free sibling of the push session `native.Handle` uses. Because no
C-to-Python callback runs during a pull, **cffi releases the GIL for the whole
native scan**, so one thread can `cancel()` a `search()` another thread is
blocked in.

Ownership and lifetime:

  * `Engine` owns the warm corpus + index + I/O pool; it is a context manager and
    serializes `search()` (the resident engine is single-writer), but a
    materialized `Cursor` owns its records in a private arena and is independent
    of the engine — iterating cursors is lock-free and safe in parallel.
  * `Cursor` yields `Match` records **copied by default** (each is a plain owned
    dataclass, valid after the cursor closes); `batches()` amortizes the native
    crossing by pulling many records per call. Both are context managers.
  * `CancelToken` is an explicit, thread-safe stop shared into `search(cancel=…)`.

Failures map to the same typed hierarchy as the rest of the package: a missing /
ABI-skewed native library raises `GistNotFoundError`, an unsupported pattern (a
lookaround the linear engine declines) raises `UnsupportedPatternError`, and a
structurally unrepresentable option raises `GistError` — a bad query is always a
catchable value, never a process death.
"""

from __future__ import annotations

import contextlib
import os
import threading
from typing import TYPE_CHECKING

from ..runtime import native
from ..runtime.errors import GistError, GistNotFoundError, UnsupportedPatternError
from .request import Match, MatchKind, SearchEngine, SearchRequest, Submatch


if TYPE_CHECKING:
    from collections.abc import Iterator

    from cffi import FFI


# Mirrors `contract.Status`: negative = "declined safely."
_OK, _MATCH = 0, 1
_STALE, _OOM, _OPEN_FAILED, _INVALID = -1, -2, -3, -4

# The default records-per-native-call for `Cursor` iteration and `batches()`.
# Chosen to amortize the FFI crossing without holding a large transient view
# buffer; override per call on `batches(size=…)`.
DEFAULT_BATCH = 64

# Request options the pull-cursor ABI has no field for (so they can't be
# silently dropped): corpus-shaping walk flags and the whole-document matcher.
# `before`/`after`/`context`, case, word, invert, quiet, and `max_count` ARE
# carried, so they are absent here.
_UNREPRESENTABLE = (
    "hidden",
    "no_ignore",
    "follow",
    "no_index",
    "max_depth",
    "multiline",
    "multiline_dotall",
)


def _require_abi() -> tuple[FFI, object]:
    """The loaded `(ffi, lib)` with the pull-cursor symbols present, or raise.

    The Engine/Cursor surface is in-process by definition — unlike the top-level
    helpers there is no subprocess to fall back to, so an absent or ABI-skewed
    library is a loud `GistNotFoundError` (build it with `make install-gist`).
    """
    loaded = native.load()
    if loaded is None:
        msg = (
            "the native gist library is unavailable or ABI-skewed; "
            "build it with `make install-gist` (or set $GIST_LIB)"
        )
        raise GistNotFoundError(msg)
    _, lib = loaded
    # A same-ABI library predating the cursor symbols still declines cleanly here
    # (cffi raises AttributeError for a missing symbol, which hasattr folds to False).
    if not hasattr(lib, "irregex_search_cursor"):
        msg = "the native library lacks the pull-cursor ABI"
        raise GistNotFoundError(msg)
    return loaded


def _flags(req: SearchRequest) -> int:
    """The `irregex_search_request.flags` bitset for the representable subset."""
    return (
        (native._FLAG_FIXED if req.fixed else 0)
        | (native._FLAG_IGNORE_CASE if req.ignore_case else 0)
        | (native._FLAG_SMART_CASE if req.smart_case else 0)
        | (native._FLAG_NO_UNICODE if req.unicode is False else 0)
        | (native._FLAG_WORD if req.word else 0)
        | (native._FLAG_INVERT if req.invert else 0)
        | (native._FLAG_QUIET if req.quiet else 0)
        | (native._FLAG_MAX_COUNT if req.max_count is not None else 0)
    )


def _reject_unrepresentable(req: SearchRequest) -> None:
    """Raise `GistError` for any option the cursor ABI cannot honor.

    Fail loud rather than answer a subtly different query than the caller asked
    — the mirror of the engine's own fail-closed `IRREGEX_INVALID` posture.
    """
    bad = [name for name in _UNREPRESENTABLE if getattr(req, name)]
    if req.globs or req.iglobs or req.types or req.not_types:
        bad.append("glob/type scoping")
    if req.extra_flags:
        bad.append("extra_flags")
    if req.engine is SearchEngine.PCRE2:
        bad.append("engine='pcre2'")
    if bad:
        msg = (
            f"the in-process cursor cannot honor {', '.join(bad)}; "
            "use irregex.search(...) for the full CLI surface"
        )
        raise GistError(msg)


def _to_match(ffi: FFI, m: object) -> Match:
    """Copy one borrowed `irregex_match` view into an owned `Match` dataclass."""
    subs = tuple(
        Submatch(text=_decode(ffi.buffer(s.text, s.len)), start=s.start, end=s.end)
        for s in (m.submatches[i] for i in range(m.nsubmatches))
    )
    # The engine's line view excludes '\n' but may retain a trailing '\r'; strip
    # it to match the cold `--json` parser exactly.
    text = _decode(ffi.buffer(m.line, m.line_len)).removesuffix("\r")
    return Match(
        path=_decode(ffi.buffer(m.path, m.path_len)),
        line_number=m.line_number,
        text=text,
        kind=MatchKind.CONTEXT if m.kind == 1 else MatchKind.MATCH,
        submatches=subs,
    )


def _decode(buf: object) -> str:
    """Decode aliased engine bytes as UTF-8, surrogate-escaping invalid bytes."""
    return bytes(buf).decode("utf-8", errors="surrogateescape")


class CancelToken:
    """A thread-safe cooperative stop shared into `Engine.search(cancel=…)`.

    One thread may `cancel()` while another is blocked in `search()` (the native
    scan runs with the GIL released); the scan stops at its next record boundary,
    keeping whatever it gathered so far. Idempotent `close()` frees the native
    token; a token is reusable across searches until closed.
    """

    __slots__ = ("_ffi", "_lib", "_token")

    def __init__(self) -> None:
        """Allocate a native cancellation token."""
        self._ffi, self._lib = _require_abi()
        out = self._ffi.new("irregex_cancel **")
        if self._lib.irregex_cancel_new(out) != _OK:
            msg = "could not allocate a cancellation token"
            raise GistError(msg)
        self._token = out[0]

    def cancel(self) -> None:
        """Request cancellation of any in-flight search using this token."""
        if self._token:
            self._lib.irregex_cancel_request(self._token)

    def close(self) -> None:
        """Free the native token (idempotent)."""
        token, self._token = self._token, self._ffi.NULL
        if token:
            self._lib.irregex_cancel_free(token)

    def __enter__(self) -> CancelToken:
        """Return self for ``with CancelToken() as tok:``."""
        return self

    def __exit__(self, *_exc: object) -> None:
        """Close the token on context exit."""
        self.close()

    def __del__(self) -> None:
        """Best-effort free if the caller never closed."""
        with contextlib.suppress(Exception):
            self.close()


class Cursor:
    """A pull result handle over one search: an iterator of owned `Match` records.

    Iterate it directly for record-at-a-time consumption, or call `batches()` to
    amortize the native crossing over many records per call. Records are copied
    into owned dataclasses, so they outlive the cursor; `close()` frees the
    native record buffer (also done on GC and context-manager exit).
    """

    __slots__ = ("_cursor", "_engine", "_ffi", "_lib", "_matched")

    def __init__(self, ffi: FFI, lib: object, engine: Engine, handle: object) -> None:
        """Wrap a native cursor handle owned by *engine*."""
        self._ffi = ffi
        self._lib = lib
        self._engine = engine  # retained so the engine outlives its cursors
        self._cursor = handle
        self._matched: bool | None = None

    @property
    def matched(self) -> bool:
        """Whether any file matched (cold's exit-code boolean).

        True even if a budget cut the scan short. Stable for the cursor's lifetime.
        """
        if self._matched is None:
            self._matched = bool(self._lib.irregex_cursor_matched(self._cursor))
        return self._matched

    def __iter__(self) -> Cursor:
        """Iterate match records one at a time."""
        return self

    def __next__(self) -> Match:
        """Return the next match, or raise ``StopIteration`` when exhausted."""
        if not self._cursor:
            raise StopIteration
        rec = self._ffi.new("irregex_match *")
        status = self._lib.irregex_cursor_next(self._cursor, rec)
        if status == _MATCH:
            return _to_match(self._ffi, rec)
        if status == _OK:
            raise StopIteration
        raise _status_error(status, "cursor advance")

    def batches(self, size: int = DEFAULT_BATCH) -> Iterator[list[Match]]:
        """Yield lists of up to `size` records, each filled by one native call.

        The same records `__iter__` yields, chunked to trade per-record call
        overhead for a larger transient view buffer. Each list is fully copied
        into owned `Match` records before the next native call.
        """
        if size < 1:
            msg = "batch size must be >= 1"
            raise ValueError(msg)
        buf = self._ffi.new("irregex_match[]", size)
        written = self._ffi.new("size_t *")
        while self._cursor:
            status = self._lib.irregex_cursor_next_batch(self._cursor, buf, size, written)
            if status == _MATCH:
                yield [_to_match(self._ffi, buf[i]) for i in range(written[0])]
                continue
            if status == _OK:
                return
            raise _status_error(status, "cursor batch")

    def close(self) -> None:
        """Free the native cursor and its record buffer (idempotent)."""
        cursor, self._cursor = self._cursor, self._ffi.NULL
        if cursor:
            self._lib.irregex_cursor_close(cursor)

    def __enter__(self) -> Cursor:
        """Return self for ``with cursor:``."""
        return self

    def __exit__(self, *_exc: object) -> None:
        """Close the cursor on context exit."""
        self.close()

    def __del__(self) -> None:
        """Best-effort free if the caller never closed."""
        with contextlib.suppress(Exception):
            self.close()


class Engine:
    """A warm in-process corpus queried many times, each yielding a pull `Cursor`.

    Open it over zero or more roots (no roots = the rootless CWD walk, exactly the
    tree a bare `gist <pattern>` scans). Use it as a context manager; `search()`
    is serialized (the resident engine is single-writer), but the cursors it
    returns are independent and iterable in parallel.
    """

    __slots__ = ("_engine", "_ffi", "_lib", "_lock")

    def __init__(self, *paths: str | os.PathLike[str]) -> None:
        """Open a warm engine over *paths* (empty = rootless CWD walk)."""
        self._ffi, self._lib = _require_abi()
        self._lock = threading.Lock()
        out = self._ffi.new("irregex_engine **")
        root_bufs = [self._ffi.new("char[]", os.fsencode(os.fspath(p))) for p in paths]
        root_ptr = self._ffi.new("char *[]", root_bufs) if root_bufs else self._ffi.NULL
        status = self._lib.irregex_engine_open(root_ptr, len(root_bufs), out)
        if status != _OK:
            raise _status_error(status, "engine open")
        self._engine = out[0]

    @classmethod
    def open(cls, *paths: str | os.PathLike[str]) -> Engine:
        """Alias for the constructor, reading as `Engine.open("services/backend")`."""
        return cls(*paths)

    def cancel_token(self) -> CancelToken:
        """A fresh cancellation token for use with `search(cancel=…)`."""
        return CancelToken()

    def search(
        self,
        pattern: str,
        *,
        cancel: CancelToken | None = None,
        timeout: float | None = None,
        max_results: int | None = None,
        **options: object,
    ) -> Cursor:
        """Search `pattern` over the warm corpus, returning a pull `Cursor`.

        Keyword `options` are `SearchRequest` fields (`fixed`, `ignore_case`,
        `word`, `before`, `after`, `max_count`, …). `timeout` (seconds) and
        `max_results` are per-operation budgets honored at record boundaries;
        `cancel` is a `CancelToken` another thread may trip.
        """
        return self.run(
            SearchRequest(pattern=pattern, **options),
            cancel=cancel,
            timeout=timeout,
            max_results=max_results,
        )

    def run(
        self,
        request: SearchRequest,
        *,
        cancel: CancelToken | None = None,
        timeout: float | None = None,
        max_results: int | None = None,
    ) -> Cursor:
        """Run a prebuilt `SearchRequest`, returning a pull `Cursor`.

        `request.paths` are ignored — roots belong to the engine (`Engine.open`).
        """
        _reject_unrepresentable(request)
        ffi = self._ffi
        pattern = request.pattern.encode()
        # A `uint8_t[]` cdata (kept alive through the call) the struct's
        # `const uint8_t *pattern` field points at; the trailing NUL cffi appends
        # is ignored because `pattern_len` is the authoritative length.
        pat_buf = ffi.new("uint8_t[]", pattern)
        before, after = (
            (request.before, request.after)
            if request.before or request.after
            else (request.context, request.context)
        )
        req = ffi.new(
            "irregex_search_request *",
            {
                "struct_size": ffi.sizeof("irregex_search_request"),
                "flags": _flags(request),
                "max_count": request.max_count or 0,
                "before_context": before,
                "after_context": after,
                "pattern": pat_buf,
                "pattern_len": len(pattern),
                "timeout_ns": int(timeout * 1e9) if timeout is not None else 0,
                "max_results": max_results or 0,
                "cancel": cancel._token if cancel is not None else ffi.NULL,
            },
        )
        out = ffi.new("irregex_cursor **")
        with self._lock:
            if not self._engine:
                msg = "engine is closed"
                raise GistError(msg)
            status = self._lib.irregex_search_cursor(self._engine, req, out)
        if status != _OK:
            raise _status_error(status, f"search {request.pattern!r}")
        return Cursor(ffi, self._lib, self, out[0])

    def close(self) -> None:
        """Free the warm corpus, index, and I/O pool (idempotent).

        Cursors already materialized own their records and remain valid.
        """
        with self._lock:
            engine, self._engine = self._engine, self._ffi.NULL
            if engine:
                self._lib.irregex_engine_close(engine)

    def __enter__(self) -> Engine:
        """Return self for ``with Engine(...) as eng:``."""
        return self

    def __exit__(self, *_exc: object) -> None:
        """Close the engine on context exit."""
        self.close()

    def __del__(self) -> None:
        """Best-effort free if the caller never closed."""
        with contextlib.suppress(Exception):
            self.close()


def _status_error(status: int, what: str) -> Exception:
    """Map a negative native status to the typed exception hierarchy."""
    if status == _STALE:
        return UnsupportedPatternError(
            f"{what}: pattern is outside the linear-time engine "
            "(use irregex.search with engine='auto'/'pcre2' for lookaround)"
        )
    if status == _OOM:
        return MemoryError(f"{what}: native out of memory")
    return GistError(f"{what}: native status {status}")
