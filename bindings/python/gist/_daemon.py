# MONOLITHIC: tightly-coupled-protocol — one UDS wire contract (framing, handshake, spawn/reap, eligibility) that fragments if split
"""Persistent resident-session client.

Long-lived Unix-socket connection to a `gist serve` daemon. Same wire protocol
as `src/surface/exec/session/conduit/protocol/protocol.zig` / the Zig CLI.
Fail-open: connect miss, ineligible request, or `decline` → cold subprocess
(`shell.files`/`shell.count`).
"""

from __future__ import annotations

import os
import socket
import struct
import subprocess
import time
from contextlib import contextmanager, suppress
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from irgx.request import Match, Ranked, SearchEngine, SearchRequest
from irgx.runtime import shell
from irgx.runtime.errors import GistNotFoundError

from . import _native as native

if TYPE_CHECKING:
    from collections.abc import Iterator


PROTOCOL_VERSION = 9  # must match `protocol.protocol_version`
# READY's fixed prefix: [u8 proto][u64 daemon][u64 session][u64 image][u32 n].
_READY_HEADER = 29
# `$GIST_SESSION_SOCK`, else `$GIST_DIR/gistd.sock` (default `.gist`).
DEFAULT_OUT_DIR = ".gist"


def _default_socket() -> str:
    out_dir = os.environ.get("GIST_DIR", "").rstrip("/") or DEFAULT_OUT_DIR
    return f"{out_dir}/gistd.sock"


# Soft deadline for connect/handshake/query (Zig: `client_io_timeout_ms`).
# `socket.timeout` is an `OSError` → existing wire handlers route to cold.
SESSION_IO_TIMEOUT = 2.0

# Mirror `protocol.zig::Opcode` / `request.Mode` / `flag_*`.
_OP_HELLO, _OP_READY, _OP_QUERY, _OP_RESULT, _OP_DECLINE = 1, 2, 3, 4, 5
_OP_ERR, _OP_SHUTDOWN, _OP_STATUS, _OP_PING, _OP_PONG = 6, 7, 8, 9, 10
_OP_DIAG = 16
_MODE_FILES, _MODE_COUNT = 0, 1
# `smart_case` ships raw; Zig resolves via `effectiveIgnoreCase`. `quiet` is the
# existence early-halt; `max_count` sets bit 7 AND writes a `u64 LE` after the
# flags byte (the only flag carrying a payload — mirror `protocol.zig`).
_FLAG_FIXED, _FLAG_IGNORE_CASE, _FLAG_WORD, _FLAG_SMART_CASE = 1 << 0, 1 << 1, 1 << 3, 1 << 5
_FLAG_INVERT, _FLAG_QUIET, _FLAG_MAX_COUNT = 1 << 4, 1 << 6, 1 << 7
_MAX_FRAME = 16 << 20  # `protocol.max_frame`

# Warm-ineligible fields — projection of `surface/exec/session/answer/request.zig::classify`
# (`tests/test_classify_parity.py`). `quiet`/`max_count`/`invert` are NOT here:
# the UDS daemon and the payload-bearing FFI options entry both serve them
# (existence early-halt, per-file cap, and — lane 3b — the set-complement
# `lines(f) − matches(f)` that keeps `-v` sound under the trigram index).
_INELIGIBLE_FIELDS = (
    "hidden",
    "no_ignore",
    "follow",
    "no_index",
    "before",
    "after",
    "context",
    "max_depth",
    "multiline",
    "multiline_dotall",
)
# The FFI options contract additionally carries the context (before/after) records.
_FFI_INELIGIBLE_FIELDS = tuple(
    field for field in _INELIGIBLE_FIELDS if field not in {"before", "after", "context"}
)


@dataclass(frozen=True, slots=True)
class SessionGeneration:
    """Identity of the daemon, connection, and resident index generation."""

    daemon: int
    session: int
    index: str
    #: The daemon's executable build stamp, latched at its boot. Reported for
    #: observability only: a non-Zig client cannot meaningfully compare itself
    #: against it, so this binding never refuses a handshake on it. `0` means
    #: the daemon could not identify its own image.
    image: int = 0

    def same_resident_index(self, other: SessionGeneration) -> bool:
        """Whether two handshakes address the same daemon/index snapshot."""
        return (self.daemon, self.index) == (other.daemon, other.index)


def default_socket_path() -> str:
    """`$GIST_SESSION_SOCK`, else the per-repo default beside the index."""
    return os.environ.get("GIST_SESSION_SOCK") or _default_socket()


def _eligible(
    request: SearchRequest,
    ineligible_fields: tuple[str, ...],
    *,
    explicit_roots: bool = False,
    explicit_unicode: bool = False,
    auto_engine: bool = False,
) -> bool:
    """The shared eligibility core both transport predicates project through."""
    if not request.pattern or "\n" in request.pattern or "\x00" in request.pattern:
        return False
    if (request.paths and not explicit_roots) or any(
        not path or "\x00" in path for path in request.paths
    ):
        return False
    if request.globs or request.iglobs or request.types or request.not_types:
        return False
    if request.extra_flags:
        return False
    engine_ok = request.engine is SearchEngine.LINEAR or (
        auto_engine and request.engine is SearchEngine.AUTO
    )
    return (
        engine_ok
        and (request.unicode is None or explicit_unicode)
        and not any(getattr(request, f) for f in ineligible_fields)
    )


def warm_eligible(request: SearchRequest) -> bool:
    r"""True iff the resident daemon can answer `request` byte-identically to cold: a single-line, NUL-free, non-empty pattern over default roots, with no rich flags, no extra argv, and no glob/type scoping — ±case including `smart_case` (sent raw; the Zig session resolves it), ±`word` (the session applies cold's exact post-match word rule), ±`invert` (lane 3b: the session answers `-v` by the `lines(f) − matches(f)` set-complement, sound under the trigram index), ±`quiet` (the existence early-halt) and ±`max_count` including `-m0` (the per-file cap, resolved in the resident session). Every clause mirrors `surface/exec/session/answer/request.zig::classify` term-for-term (a `\n`/`\x00` pattern steps outside rg's per-line model, so the warm whole-doc engine could match where cold cannot); `tests/test_classify_parity.py` drives real argv through the built classifier to prove the two never drift."""
    return _eligible(request, _INELIGIBLE_FIELDS)


def ffi_eligible(request: SearchRequest) -> bool:
    """True iff FFI can attempt `request`. Beyond the daemon subset, it serves invert/context records, opens explicit roots, carries Unicode/ASCII mode, and accelerates the linear-compatible arm of `engine="auto"`; `IRGX_STALE` falls through to cold PCRE2."""
    return _eligible(
        request,
        _FFI_INELIGIBLE_FIELDS,
        explicit_roots=True,
        explicit_unicode=True,
        auto_engine=True,
    )


def _socket_listening(path: Path) -> bool:
    """Whether a daemon accepts a connection on ``path`` right now."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(SESSION_IO_TIMEOUT)
    try:
        s.connect(str(path))
        return True
    except OSError:
        return False
    finally:
        s.close()


def ensure_serve(
    *,
    cwd: str | os.PathLike[str] | None = None,
    socket_path: str | None = None,
    timeout: float = 3.0,
) -> bool:
    """Guarantee a `gist serve` daemon is listening on the session socket under ``cwd``.

    Spawns a detached one if none is listening, and returns whether one is
    (now) reachable. Fail-open by construction: a missing binary, a spawn
    error, or a daemon that never binds within ``timeout`` returns ``False``,
    and the caller's `Session` still answers cold. Mirrors the Zig auto-spawn
    (`src/surface/face/gist/daemon/client/spawn.zig`): opt out with ``GIST_NO_AUTOSERVE``, and
    it is herd-safe because the daemon's advisory `flock` admits exactly one
    racer (the losers exit at once without touching the winner's live socket).
    """
    base = Path(cwd) if cwd is not None else Path.cwd()
    sock = Path(socket_path or default_socket_path())
    if not sock.is_absolute():
        sock = base / sock
    if _socket_listening(sock):
        return True
    if os.environ.get("GIST_NO_AUTOSERVE") is not None:
        return False
    try:
        gist_bin = shell.binary()
    except GistNotFoundError:
        return False
    # A bare `gist serve` binds `$GIST_SESSION_SOCK` else the CWD-relative
    # `.gist/gistd.sock` and serves the rootless CWD walk — exactly
    # the tree a rootless query answers cold. Pin the child's bind address only
    # when the caller overrode the default socket.
    env = os.environ if socket_path is None else {**os.environ, "GIST_SESSION_SOCK": str(sock)}
    try:
        subprocess.Popen(  # noqa: S603 — trusted binary, fixed argv, no shell
            [gist_bin, "serve"],
            cwd=str(base),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return False
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if _socket_listening(sock):
            return True
        time.sleep(0.02)
    return False


class Session:
    """One reusable daemon connection. Not thread-safe: give each thread its own `Session` (the connection carries one in-flight request at a time)."""

    def __init__(
        self, socket_path: str | None = None, *, cwd: str | os.PathLike[str] | None = None
    ) -> None:
        """Bind to ``socket_path`` (or the default) under optional ``cwd``."""
        self._path = socket_path or default_socket_path()
        self._cwd = cwd
        self._sock: socket.socket | None = None
        self._generation: SessionGeneration | None = None
        self._last_generation: SessionGeneration | None = None
        self._generation_changed = False

    # ── connection lifecycle ──

    def _connect(self) -> socket.socket | None:
        """Open + handshake, or None if no daemon / a version mismatch (→ cold).

        The deadline stays armed on the socket for the connection's whole
        life, so no later send/recv can park the caller behind a wedged or
        busy daemon either — `socket.timeout` is an `OSError`, which every
        wire path already treats as "answer cold".
        """
        path = Path(self._path)
        if not path.is_absolute():
            path = Path(self._cwd or Path.cwd()) / path
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(SESSION_IO_TIMEOUT)
        try:
            s.connect(str(path))
            _send(s, _OP_HELLO, bytes([PROTOCOL_VERSION]))
            op, payload = _recv(s)
            generation = _decode_ready(payload) if op == _OP_READY else None
            if generation is None:
                s.close()
                return None
        except (OSError, _WireError) as _:
            s.close()
            return None
        previous = self._last_generation
        self._generation = generation
        self._last_generation = generation
        self._generation_changed = previous is not None and generation != previous
        return s

    def _ensure(self) -> socket.socket | None:
        if self._sock is None:
            self._sock = self._connect()
        return self._sock

    def _drop(self) -> None:
        if self._sock is not None:
            with suppress(OSError):
                self._sock.close()
            self._sock = None
            self._generation = None

    @property
    def generation(self) -> SessionGeneration | None:
        """Generation from the active daemon handshake, if connected."""
        return self._generation

    @property
    def generation_changed(self) -> bool:
        """Whether the latest handshake/status observed a new daemon or index."""
        return self._generation_changed

    def connect(self) -> bool:
        """Connect eagerly and capture the daemon/index generation."""
        return self._ensure() is not None

    def refresh_generation(self) -> SessionGeneration | None:
        """Ask the daemon for its current generation, dropping a broken peer."""
        s = self._ensure()
        if s is None:
            return None
        try:
            _send(s, _OP_STATUS, b"")
            op, payload = _recv(s)
            current = _decode_ready(payload) if op == _OP_READY else None
        except (OSError, _WireError):
            self._drop()
            return None
        if current is None:
            self._drop()
            return None
        previous = self._generation
        self._generation = current
        self._last_generation = current
        self._generation_changed = previous is not None and current != previous
        return current

    def close(self) -> None:
        """Close the connection (the daemon keeps running; only `shutdown` stops it)."""
        self._drop()

    def __enter__(self) -> Session:
        """Context-manager enter — returns self."""
        return self

    def __exit__(self, *_exc: object) -> None:
        """Context-manager exit — closes the connection."""
        self.close()

    # ── queries (warm, fail-open to cold) ──

    def run(
        self,
        request: SearchRequest,
        *,
        timeout: float = shell.DEFAULT_TIMEOUT,
    ) -> list[Match]:
        """Full structured matches — served WARM in-process over the FFI when eligible.

        in-process C ABI, no subprocess/socket; else the byte-identical cold
        path. Unlike the UDS transport (files/count only), the in-process
        session answers full `Match` records, so this is the first warm
        `run`.
        """
        ffi_matches = native.run(request, cwd=self._cwd)
        if ffi_matches is not None:
            return ffi_matches
        return shell.run(request, cwd=self._cwd, timeout=timeout)

    def files(self, request: SearchRequest, *, timeout: float = shell.DEFAULT_TIMEOUT) -> list[str]:
        """Paths of files with ≥1 matching line (`-l`), sorted.

        In-process FFI if eligible, else the UDS daemon, else the
        byte-identical cold answer.
        """
        ffi_files = native.files(request, cwd=self._cwd)
        if ffi_files is not None:
            return ffi_files
        warm = self._query(request, _MODE_FILES) if warm_eligible(request) else None
        if isinstance(warm, list):
            return sorted(warm)
        return shell.files(request, cwd=self._cwd, timeout=timeout)

    def count(self, request: SearchRequest, *, timeout: float = shell.DEFAULT_TIMEOUT) -> int:
        """Total matching lines across the tree.

        In-process FFI if eligible, else the UDS daemon, else cold.
        """
        ffi_count = native.count(request, cwd=self._cwd)
        if ffi_count is not None:
            return ffi_count
        warm = self._query(request, _MODE_COUNT) if warm_eligible(request) else None
        if isinstance(warm, int):
            return warm
        return shell.count(request, cwd=self._cwd, timeout=timeout)

    def absent(self, pattern: str, *, fixed: bool = False, ignore_case: bool = False) -> bool:
        """Prefilter for a broad scoped scan.

        ``True`` only when the warm daemon proves ``pattern`` matches
        **nowhere** in the served rootless tree — so any narrower scoped
        form of the same pattern (extra roots, globs, types, exempt paths)
        is empty too, and the caller may skip its authoritative scan.
        ``False`` whenever the pattern is present, no daemon is listening,
        or the daemon declines — so ``False`` always means "run your own
        scan": the accelerator can only *skip provably-empty work*, never
        change an answer. Sound only when the caller's scoped query is a
        pure narrowing of ``(pattern, fixed, ignore_case)`` — no
        match-semantics flags (word, invert, context, multiline, …) — which
        is exactly the shape of the first-party tree-walking lints.
        """
        probe = SearchRequest(pattern=pattern, fixed=fixed, ignore_case=ignore_case)
        ffi_count = native.count(probe, cwd=self._cwd)
        if ffi_count is not None:
            return ffi_count == 0
        if not warm_eligible(probe):
            return False
        return self._query(probe, _MODE_COUNT) == 0

    def rank(
        self,
        request: SearchRequest,
        *,
        limit: int = 20,
        timeout: float = shell.DEFAULT_TIMEOUT,
    ) -> list[Ranked]:
        """Return the engine's ranked view through the authoritative cold path."""
        return shell.rank(request, limit=limit, cwd=self._cwd, timeout=timeout)

    def _query(self, request: SearchRequest, mode: int) -> list[str] | int | None:
        """One request/response over the (reconnecting) connection. None on any miss — no daemon, `decline`/`err`, or a wire hiccup — so the caller runs cold. A dropped connection is retried once (a daemon may have restarted)."""
        for _ in range(2):
            s = self._ensure()
            if s is None:
                return None
            try:
                flags = (
                    (_FLAG_FIXED if request.fixed else 0)
                    | (_FLAG_IGNORE_CASE if request.ignore_case else 0)
                    | (_FLAG_WORD if request.word else 0)
                    | (_FLAG_INVERT if request.invert else 0)
                    | (_FLAG_SMART_CASE if request.smart_case else 0)
                    | (_FLAG_QUIET if request.quiet else 0)
                    | (_FLAG_MAX_COUNT if request.max_count is not None else 0)
                )
                cap = struct.pack("<Q", request.max_count) if request.max_count is not None else b""
                body = bytes([mode, flags]) + cap + request.pattern.encode()
                _send(s, _OP_QUERY, body)
                op, payload = _recv(s)
                while op == _OP_DIAG:
                    os.write(2, payload)
                    op, payload = _recv(s)
            except (OSError, _WireError) as _:
                self._drop()
                continue  # stale connection → reconnect + retry once
            if op != _OP_RESULT:
                return None  # decline / err → cold
            return _decode_result(payload, mode)
        return None


@contextmanager
def opening_session(
    *,
    cwd: str | os.PathLike[str] | None = None,
    socket_path: str | None = None,
) -> Iterator[Session]:
    """Yield a connected `Session` for a batch caller, auto-spawning `gist serve`.

    Spawns via `ensure_serve` when none is listening. The session is
    fail-open: if the daemon never comes up the yielded `Session`
    transparently answers every query cold, so a caller writes its loop
    against one object either way. Closes the connection on exit; the
    daemon keeps running warm for the next batch.
    """
    ensure_serve(cwd=cwd, socket_path=socket_path)
    session = Session(socket_path, cwd=cwd)
    session.connect()
    try:
        yield session
    finally:
        session.close()


# ─────────────────────────── wire codec (pure) ───────────────────────────


class _WireError(Exception):
    """A malformed / oversized / truncated frame — fail closed to cold."""


def _send(s: socket.socket, opcode: int, payload: bytes) -> None:
    frame = struct.pack("<I", 1 + len(payload)) + bytes([opcode]) + payload
    s.sendall(frame)


def _recv_exact(s: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise _WireError
        buf += chunk
    return bytes(buf)


def _recv(s: socket.socket) -> tuple[int, bytes]:
    (length,) = struct.unpack("<I", _recv_exact(s, 4))
    if length == 0 or length > _MAX_FRAME:
        raise _WireError
    body = _recv_exact(s, length)
    return body[0], body[1:]


def _decode_ready(payload: bytes) -> SessionGeneration | None:
    if len(payload) < _READY_HEADER or payload[0] != PROTOCOL_VERSION:
        return None
    daemon, session, image, length = struct.unpack("<QQQI", payload[1:_READY_HEADER])
    if len(payload) != _READY_HEADER + length:
        return None
    return SessionGeneration(
        daemon=daemon,
        session=session,
        index=payload[_READY_HEADER:].decode(errors="surrogateescape"),
        image=image,
    )


def _decode_result(payload: bytes, expect_mode: int) -> list[str] | int | None:
    if not payload or payload[0] != expect_mode:
        return None
    if expect_mode == _MODE_COUNT:
        return struct.unpack("<Q", payload[1:9])[0] if len(payload) >= 9 else None
    # files: [u8 mode][u32 n][ per file: u32 len + bytes ]
    if len(payload) < 5:
        return None
    (n,) = struct.unpack("<I", payload[1:5])
    out: list[str] = []
    off = 5
    for _ in range(n):
        if off + 4 > len(payload):
            return None
        (plen,) = struct.unpack("<I", payload[off : off + 4])
        off += 4
        if off + plen > len(payload):
            return None
        out.append(payload[off : off + plen].decode(errors="surrogateescape"))
        off += plen
    return out
