"""Persistent resident-session client (ADR-352 rung 2.5). A long-lived Unix-socket connection to a `gist serve` daemon, reused across many queries so an eligible request answers warm — without re-paying the cold subprocess's process + index-mmap + candidate-read startup on every call. This is the Python leg of the same wire protocol `src/session/protocol.zig` defines and the Zig CLI client speaks; the daemon is the single source of truth, so both clients frame-match by construction. Fail-open, always: a `Session` that cannot connect, whose request is ineligible, or that receives a `decline` transparently falls back to the certified cold subprocess (`engine.files`/`engine.count`) and returns the byte-identical answer. The daemon is a pure accelerator — it never adds a failure mode a caller must handle, only removes latency when one is listening."""

from __future__ import annotations

from contextlib import suppress
from dataclasses import dataclass
import os
from pathlib import Path
import socket
import struct

from . import engine
from .request import Match, Ranked, SearchEngine, SearchRequest


PROTOCOL_VERSION = 1
DEFAULT_SOCKET = ".local/gist-verify/gistd.sock"

# Opcodes — mirror `protocol.zig::Opcode`.
_OP_HELLO, _OP_READY, _OP_QUERY, _OP_RESULT, _OP_DECLINE = 1, 2, 3, 4, 5
_OP_ERR, _OP_SHUTDOWN, _OP_STATUS, _OP_PING, _OP_PONG = 6, 7, 8, 9, 10

# Mode bytes — `request.Mode` enum order (files, count).
_MODE_FILES, _MODE_COUNT = 0, 1
# Query flag bits — `protocol.zig::flag_*`.
_FLAG_FIXED, _FLAG_IGNORE_CASE = 1 << 0, 1 << 1

_MAX_FRAME = 16 << 20  # matches `protocol.max_frame`; a hostile/looping peer cap.

# The rich request fields that make a query ineligible for the warm fast path
# (the daemon serves only default-roots `-l`/`-c`, literal/plain-regex, ±case).
# Any of these set → cold. Mirrors `session/request.zig::classify`.
_INELIGIBLE_FIELDS = (
    "smart_case", "word", "invert", "hidden", "no_ignore", "follow", "no_index",
    "before", "after", "context", "max_count", "max_depth", "multiline",
    "multiline_dotall",
)


@dataclass(frozen=True, slots=True)
class SessionGeneration:
    """Identity of the daemon, connection, and resident index generation."""

    daemon: int
    session: int
    index: str

    def same_resident_index(self, other: SessionGeneration) -> bool:
        """Whether two handshakes address the same daemon/index snapshot."""
        return (self.daemon, self.index) == (other.daemon, other.index)


def default_socket_path() -> str:
    """`$GIST_SESSION_SOCK`, else the per-repo default beside the index."""
    return os.environ.get("GIST_SESSION_SOCK") or DEFAULT_SOCKET


def warm_eligible(request: SearchRequest) -> bool:
    """True iff the resident daemon can answer `request` byte-identically to cold: default roots, no rich flags, no extra argv, no glob/type scoping."""
    if request.paths or request.globs or request.iglobs or request.types or request.not_types:
        return False
    if request.extra_flags:
        return False
    return (
        request.engine is SearchEngine.LINEAR
        and request.unicode is None
        and not any(getattr(request, f) for f in _INELIGIBLE_FIELDS)
    )


class Session:
    """One reusable daemon connection. Not thread-safe: give each thread its own `Session` (the connection carries one in-flight request at a time)."""

    def __init__(self, socket_path: str | None = None, *, cwd: str | os.PathLike[str] | None = None) -> None:
        """Bind to ``socket_path`` (or the default) under optional ``cwd``."""
        self._path = socket_path or default_socket_path()
        self._cwd = cwd
        self._sock: socket.socket | None = None
        self._generation: SessionGeneration | None = None
        self._last_generation: SessionGeneration | None = None
        self._generation_changed = False

    # ── connection lifecycle ──

    def _connect(self) -> socket.socket | None:
        """Open + handshake, or None if no daemon / a version mismatch (→ cold)."""
        path = Path(self._path)
        if not path.is_absolute():
            path = Path(self._cwd or Path.cwd()) / path
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
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
        except OSError, _WireError:
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
        timeout: float = engine.DEFAULT_TIMEOUT,
    ) -> list[Match]:
        """Return full structured matches through the authoritative cold path."""
        return engine.run(request, cwd=self._cwd, timeout=timeout)

    def files(self, request: SearchRequest, *, timeout: float = engine.DEFAULT_TIMEOUT) -> list[str]:
        """Paths of files with ≥1 matching line (`-l`), sorted — warm if the daemon serves it, else the byte-identical cold answer."""
        warm = self._query(request, _MODE_FILES) if warm_eligible(request) else None
        if isinstance(warm, list):
            return sorted(warm)
        return engine.files(request, cwd=self._cwd, timeout=timeout)

    def count(self, request: SearchRequest, *, timeout: float = engine.DEFAULT_TIMEOUT) -> int:
        """Total matching lines across the tree — warm if served, else cold."""
        warm = self._query(request, _MODE_COUNT) if warm_eligible(request) else None
        if isinstance(warm, int):
            return warm
        return engine.count(request, cwd=self._cwd, timeout=timeout)

    def rank(
        self,
        request: SearchRequest,
        *,
        limit: int = 20,
        timeout: float = engine.DEFAULT_TIMEOUT,
    ) -> list[Ranked]:
        """Return the engine's ranked view through the authoritative cold path."""
        return engine.rank(request, limit=limit, cwd=self._cwd, timeout=timeout)

    def _query(self, request: SearchRequest, mode: int) -> list[str] | int | None:
        """One request/response over the (reconnecting) connection. None on any miss — no daemon, `decline`/`err`, or a wire hiccup — so the caller runs cold. A dropped connection is retried once (a daemon may have restarted)."""
        for _ in range(2):
            s = self._ensure()
            if s is None:
                return None
            try:
                flags = (_FLAG_FIXED if request.fixed else 0) | (_FLAG_IGNORE_CASE if request.ignore_case else 0)
                body = bytes([mode, flags]) + request.pattern.encode()
                _send(s, _OP_QUERY, body)
                op, payload = _recv(s)
            except (OSError, _WireError) as _:
                self._drop()
                continue  # stale connection → reconnect + retry once
            if op != _OP_RESULT:
                return None  # decline / err → cold
            return _decode_result(payload, mode)
        return None


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
    if len(payload) < 21 or payload[0] != PROTOCOL_VERSION:
        return None
    daemon, session, length = struct.unpack("<QQI", payload[1:21])
    if len(payload) != 21 + length:
        return None
    return SessionGeneration(
        daemon=daemon,
        session=session,
        index=payload[21:].decode(errors="surrogateescape"),
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
