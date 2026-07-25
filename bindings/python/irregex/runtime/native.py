"""In-process cffi transport for the warm search session (ADR-352 rung 3).

`dlopen`s `libirregex.{dylib,so}` in ABI mode (no C compiler, dev headers, or
per-Python build) and drives the `irregex_open` / `irregex_search` /
`irregex_close` C ABI (`../../../include/irregex.h`,
implemented in `src/surface/ffi/session.zig`). It holds one corpus WARM in this
very process — no subprocess, Unix socket, `stdout`, or `exit` — and streams
full `Match` records over a callback: the same record SET the cold `gist --json`
stream produces, each file's lines in the same order, but canonicalized to
`pathLess` file order (cold's parallel/discovery file order is a certified
degree of freedom — see `resident.zig`).

**Fail-open by construction.** Every entry returns `None` (never raises) when
the library is absent, `cffi` is missing, the ABI version disagrees, the corpus
can't open, or the engine returns `IRREGEX_STALE` (an unsupported pattern) — so the
caller answers cold and the in-process path is a pure accelerator that never
adds a failure mode. Opt out entirely with `GIST_NO_FFI`.

**Exact roots only.** A handle opens either the rootless CWD walk (`nroots == 0`)
or the request's explicit root array. Handles are cached by `(process CWD,
roots)` and used only when the caller's effective `cwd` is the process CWD —
otherwise the cold subprocess answers. This preserves path rendering without
binding-side normalization.
"""

from __future__ import annotations

import contextlib
import os
from pathlib import Path
import sys
import threading
from typing import TYPE_CHECKING

from ..contract import abi
from ..exact.request import Match, MatchKind, Submatch


if TYPE_CHECKING:
    from cffi import FFI

    from ..exact.request import SearchRequest


# The C-ABI symbol version the loader gates on (`root.zig::abi`). ABI 2 is the
# open/search/close interface whose match callback (`irregex_match_fn`) returns
# an `i32` abort code — the breaking signature change that stepped it 1 → 2
# (ADR-352). This is the same integer the contract's `search_api.toml`
# `[meta].abi_version` (`gist.ABI_VERSION`) mirrors; the semantic contract
# revision and format axes version independently. Callbacks below always return
# 0 (CONTINUE) — the Python API wants every match — so the abort path is
# exercised only by future consumers.
_ABI_VERSION = 2
_CONTINUE = 0  # a match-callback return of 0 keeps the stream going
_FLAG_FIXED, _FLAG_IGNORE_CASE, _FLAG_WORD, _FLAG_QUIET = 1 << 0, 1 << 1, 1 << 2, 1 << 3
_FLAG_MAX_COUNT, _FLAG_SMART_CASE = 1 << 4, 1 << 5
_FLAG_NO_UNICODE, _FLAG_INVERT = 1 << 6, 1 << 7
_GIST_OK = 0  # ran, no match; a negative status (e.g. IRREGEX_STALE=-1) → cold.


def _dylib_name() -> str:
    if sys.platform == "darwin":
        return "libirregex.dylib"
    if sys.platform == "win32":
        return "gist.dll"
    return "libirregex.so"


def _resolve_lib() -> str | None:
    """`$GIST_LIB` override, else the kernel's built `zig-out/lib/libirregex.<ext>`.

    Returns None (→ cold) when neither is present, mirroring `lamina/_loader.py`
    but never raising — the FFI is optional here.
    """
    override = os.environ.get("GIST_LIB")
    if override:
        return override if Path(override).is_file() else None
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / "zig-out" / "lib" / _dylib_name()
        if candidate.is_file():
            return str(candidate)
        if (parent / "build.zig").is_file():
            return None  # in the kernel tree but unbuilt — cold until `zig build`
    return None


# The loaded (ffi, lib) pair, computed once. `Ellipsis` = "not yet attempted".
_loaded: tuple[FFI, object] | None = None
_load_attempted = False
_load_lock = threading.Lock()


def _load() -> tuple[FFI, object] | None:
    """`dlopen` the shared library once (thread-safe, cached). None on any miss."""
    global _loaded, _load_attempted
    if _load_attempted:
        return _loaded
    with _load_lock:
        if _load_attempted:
            return _loaded
        _loaded = _try_load()
        _load_attempted = True
        return _loaded


def _try_load() -> tuple[FFI, object] | None:
    if os.environ.get("GIST_NO_FFI") is not None:
        return None
    lib_path = _resolve_lib()
    if lib_path is None:
        return None
    try:
        from cffi import FFI
    except ImportError:
        return None
    ffi = FFI()
    ffi.cdef(abi.CDEF + abi.ANALYTIC_CDEF)
    try:
        lib = ffi.dlopen(lib_path)
        # Resolve the required search entry eagerly; a stale library declines
        # here (AttributeError) instead of raising on the first query.
        _ = lib.irregex_search
        if lib.irregex_abi_version() != _ABI_VERSION:
            return None  # header/library ABI drift — decline, answer cold
    except AttributeError, OSError:
        return None
    return (ffi, lib)


def available() -> bool:
    """Whether the in-process transport can be used (library loaded, ABI matches)."""
    return _load() is not None


def exports(*names: str) -> bool:
    """Whether the loaded library exports every named symbol.

    The analytic plane is additive, so a library built before it landed answers
    the exact ABI perfectly and simply has no `irregex_analytic_run`. cffi
    resolves an ABI-mode symbol on first attribute access, which makes this the
    honest probe — and its absence a declinature, never an error.
    """
    loaded = _load()
    if loaded is None:
        return False
    try:
        for name in names:
            getattr(loaded[1], name)
    except AttributeError:
        return False
    return True


def load() -> tuple[FFI, object] | None:
    """Return the loaded `(ffi, lib)` pair, or None if unavailable.

    None when the in-process library is absent / ABI-skewed. The idiomatic
    `Engine`/`Cursor` surface (`cursor.py`) drives the pull-cursor symbols off
    this same handle the push session uses.
    """
    return _load()


class Handle:
    """A warm in-process corpus over one exact root tuple.

    Guarded by a lock: the Zig session serializes its own queries, and the
    lock also covers the per-handle arena the Zig `search` resets before
    taking that lock, so concurrent Python callers on one handle stay
    correct. `close` frees the corpus + index; a dropped `Handle` also frees
    them via `__del__`.
    """

    def __init__(self, ffi: FFI, lib: object, roots: tuple[str, ...]) -> None:
        self._ffi = ffi
        self._lib = lib
        self._lock = threading.Lock()
        out = ffi.new("irregex_session **")
        # Keep each C string alive through open; Zig copies the root bytes into
        # session-owned storage before returning.
        root_bufs = [ffi.new("char[]", os.fsencode(root)) for root in roots]
        root_ptr = ffi.new("char *[]", root_bufs) if root_bufs else ffi.NULL
        rc = lib.irregex_open(root_ptr, len(root_bufs), out)
        self._session = out[0] if rc == _GIST_OK else ffi.NULL

    def ok(self) -> bool:
        """Whether the corpus opened (else the caller answers cold)."""
        return bool(self._session)

    def _invoke(
        self, request: SearchRequest, callback: object, *, include_context: bool = True
    ) -> int | None:
        """Drive one `irregex_search` under the handle lock.

        None if closed, else the raw status (negative = the caller answers
        cold).
        """
        pattern = request.pattern.encode()
        flags = (
            (_FLAG_FIXED if request.fixed else 0)
            | (_FLAG_IGNORE_CASE if request.ignore_case else 0)
            | (_FLAG_SMART_CASE if request.smart_case else 0)
            | (_FLAG_NO_UNICODE if request.unicode is False else 0)
            | (_FLAG_WORD if request.word else 0)
            | (_FLAG_INVERT if request.invert else 0)
            | (_FLAG_QUIET if request.quiet else 0)
            | (_FLAG_MAX_COUNT if request.max_count is not None else 0)
        )
        before, after = (
            (request.before, request.after)
            if request.before or request.after
            else (request.context, request.context)
        )
        if not include_context:
            before = after = 0
        options = self._ffi.new(
            "irregex_search_options *",
            {
                "struct_size": self._ffi.sizeof("irregex_search_options"),
                "flags": flags,
                "max_count": request.max_count or 0,
                "before_context": before,
                "after_context": after,
            },
        )
        with self._lock:
            if not self._session:
                return None
            return self._lib.irregex_search(
                self._session, pattern, len(pattern), options, callback, self._ffi.NULL
            )

    def search(self, request: SearchRequest) -> list[Match] | None:
        """Full `Match` records for `request` over the warm corpus, in `pathLess` file order.

        Returns None to fall back cold (closed handle, or a `IRREGEX_STALE`/error
        status from an unsupported pattern).
        """
        ffi = self._ffi
        out: list[Match] = []

        @ffi.callback("int32_t(void *, const irregex_match *)")
        def on_match(_ctx: object, m: object) -> int:
            subs = tuple(
                Submatch(text=_decode(ffi.buffer(s.text, s.len)), start=s.start, end=s.end)
                for s in (m.submatches[i] for i in range(m.nsubmatches))
            )
            # The Zig line view excludes `\n` but may keep a trailing `\r`; strip
            # it to match the cold parser's `.removesuffix("\n").removesuffix("\r")`.
            text = _decode(ffi.buffer(m.line, m.line_len)).removesuffix("\r")
            out.append(
                Match(
                    path=_decode(ffi.buffer(m.path, m.path_len)),
                    line_number=m.line_number,
                    text=text,
                    kind=MatchKind.CONTEXT if m.kind == 1 else MatchKind.MATCH,
                    submatches=subs,
                )
            )
            return _CONTINUE

        rc = self._invoke(request, on_match)
        return out if rc is not None and rc >= 0 else None

    def count(self, request: SearchRequest) -> int | None:
        """Total matching LINES (the `-c` answer) without materializing records."""
        ffi = self._ffi
        tally = [0]

        @ffi.callback("int32_t(void *, const irregex_match *)")
        def on_match(_ctx: object, _m: object) -> int:
            tally[0] += 1
            return _CONTINUE

        rc = self._invoke(request, on_match, include_context=False)
        return tally[0] if rc is not None and rc >= 0 else None

    def files(self, request: SearchRequest) -> list[str] | None:
        """Sorted distinct paths with ≥1 match (the `-l` answer), no records."""
        ffi = self._ffi
        seen: set[str] = set()

        @ffi.callback("int32_t(void *, const irregex_match *)")
        def on_match(_ctx: object, m: object) -> int:
            seen.add(_decode(ffi.buffer(m.path, m.path_len)))
            return _CONTINUE

        rc = self._invoke(request, on_match, include_context=False)
        return sorted(seen) if rc is not None and rc >= 0 else None

    def close(self) -> None:
        """Free the warm corpus, index, and handle (idempotent)."""
        with self._lock:
            if self._session:
                self._lib.irregex_close(self._session)
                self._session = self._ffi.NULL

    def __del__(self) -> None:
        with contextlib.suppress(Exception):  # teardown must never raise
            self.close()


def _decode(buf: object) -> str:
    """Decode aliased engine bytes as UTF-8.

    Surrogate-escapes any invalid bytes (as `session.py` decodes wire paths)
    so a non-UTF-8 blob never raises.
    """
    return bytes(buf).decode("utf-8", errors="surrogateescape")


# Warm handles are keyed by process CWD + the exact root tuple, so neither a
# `chdir` nor a differently-scoped request can reuse the wrong corpus. Bound the
# cache: root scopes may be user-provided, and warm state must not grow without
# limit. Handles reconcile on every query, preserving read-your-writes.
_MAX_HANDLES = 8
_handles: dict[tuple[str, tuple[str, ...]], Handle | None] = {}
_handles_lock = threading.Lock()


def _handle_for(request: SearchRequest) -> Handle | None:
    loaded = _load()
    if loaded is None:
        return None
    key = (str(Path.cwd()), request.paths)
    with _handles_lock:
        if key in _handles:
            return _handles[key]
        ffi, lib = loaded
        handle: Handle | None = Handle(ffi, lib, request.paths)
        if not handle.ok():
            handle = None
        if len(_handles) >= _MAX_HANDLES:
            evicted = _handles.pop(next(iter(_handles)))
            if evicted is not None:
                evicted.close()
        _handles[key] = handle
        return handle


def _uses_process_cwd(cwd: str | os.PathLike[str] | None) -> bool:
    """Whether `cwd` resolves to this process's CWD.

    Relative explicit roots and the rootless walk resolve against process CWD;
    this must equal the cold subprocess's child CWD.
    """
    if cwd is None:
        return True
    return Path(cwd).resolve() == Path.cwd().resolve()


def _eligible_handle(request: SearchRequest, cwd: str | os.PathLike[str] | None) -> Handle | None:
    """The warm handle to serve `request` in-process, or None (→ cold).

    Declines unless the request is FFI-eligible AND `cwd` is the process CWD.
    """
    # Lazy import avoids a cycle (session imports _ffi). `ffi_eligible` is the
    # STRICT predicate: the options ABI carries the complete warm request
    # subset; every later unsupported family must decline here, never be
    # silently dropped.
    from .daemon import ffi_eligible

    if not ffi_eligible(request) or not _uses_process_cwd(cwd):
        return None
    return _handle_for(request)


def run(request: SearchRequest, *, cwd: str | os.PathLike[str] | None) -> list[Match] | None:
    """In-process `Match` records for `request` (cold `--json` order).

    Returns None to answer cold.
    """
    handle = _eligible_handle(request, cwd)
    return handle.search(request) if handle is not None else None


def count(request: SearchRequest, *, cwd: str | os.PathLike[str] | None) -> int | None:
    """In-process total matching lines for `request`, or None to answer cold."""
    handle = _eligible_handle(request, cwd)
    return handle.count(request) if handle is not None else None


def files(request: SearchRequest, *, cwd: str | os.PathLike[str] | None) -> list[str] | None:
    """In-process sorted matching paths for `request`, or None to answer cold."""
    handle = _eligible_handle(request, cwd)
    return handle.files(request) if handle is not None else None
