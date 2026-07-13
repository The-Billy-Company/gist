"""Persistent resident-session client (ADR-352 rung 2.5).

A long-lived Unix-socket connection to a `gist serve` daemon, reused across many
queries so an eligible request answers warm — without re-paying the cold
subprocess's process + index-mmap + candidate-read startup on every call. This is
the Python leg of the same wire protocol `src/session/protocol.zig` defines and
the Zig CLI client speaks; the daemon is the single source of truth, so both
clients frame-match by construction.

Fail-open, always: a `Session` that cannot connect, whose request is ineligible,
or that receives a `decline` transparently falls back to the certified cold
subprocess (`engine.files`/`engine.count`) and returns the byte-identical answer.
The daemon is a pure accelerator — it never adds a failure mode a caller must
handle, only removes latency when one is listening.
"""

from __future__ import annotations

import os
from pathlib import Path
import socket
import struct

from . import engine
from .request import SearchRequest


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
    "before", "after", "context", "max_count", "max_depth",
)


def default_socket_path() -> str:
    """`$GIST_SESSION_SOCK`, else the per-repo default beside the index."""
    return os.environ.get("GIST_SESSION_SOCK") or DEFAULT_SOCKET


def warm_eligible(request: SearchRequest) -> bool:
    """True iff the resident daemon can answer `request` byte-identically to
    cold: default roots, no rich flags, no extra argv, no glob/type scoping."""
    if request.paths or request.globs or request.iglobs or request.types or request.not_types:
        return False
    if request.extra_flags:
        return False
    return not any(getattr(request, f) for f in _INELIGIBLE_FIELDS)


class Session:
    """One reusable daemon connection. Not thread-safe: give each thread its own
    `Session` (the connection carries one in-flight request at a time)."""

    def __init__(self, socket_path: str | None = None, *, cwd: str | os.PathLike[str] | None = None) -> None:
        self._path = socket_path or default_socket_path()
        self._cwd = cwd
        self._sock: socket.socket | None = None

    # ── connection lifecycle ──

    def _connect(self) -> socket.socket | None:
        """Open + handshake, or None if no daemon / a version mismatch (→ cold)."""
        path = self._path
        if not os.path.isabs(path):
            path = str(Path(self._cwd or Path.cwd()) / path)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
            _send(s, _OP_HELLO, bytes([PROTOCOL_VERSION]))
            op, payload = _recv(s)
            if op != _OP_READY or not payload or payload[0] != PROTOCOL_VERSION:
                s.close()
                return None
        except (OSError, _WireError):
            s.close()
            return None
        return s

    def _ensure(self) -> socket.socket | None:
        if self._sock is None:
            self._sock = self._connect()
        return self._sock

    def _drop(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def close(self) -> None:
        """Close the connection (the daemon keeps running; only `shutdown` stops it)."""
        self._drop()

    def __enter__(self) -> Session:
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()

    # ── queries (warm, fail-open to cold) ──

    def files(self, request: SearchRequest, *, timeout: float = engine.DEFAULT_TIMEOUT) -> list[str]:
        """Paths of files with ≥1 matching line (`-l`), sorted — warm if the
        daemon serves it, else the byte-identical cold answer."""
        warm = self._query(request, _MODE_FILES) if warm_eligible(request) else None
        if warm is not None:
            return sorted(warm)
        return engine.files(request, cwd=self._cwd, timeout=timeout)

    def count(self, request: SearchRequest, *, timeout: float = engine.DEFAULT_TIMEOUT) -> int:
        """Total matching lines across the tree — warm if served, else cold."""
        warm = self._query(request, _MODE_COUNT) if warm_eligible(request) else None
        if warm is not None:
            return warm
        return engine.count(request, cwd=self._cwd, timeout=timeout)

    def _query(self, request: SearchRequest, mode: int) -> list[str] | int | None:
        """One request/response over the (reconnecting) connection. None on any
        miss — no daemon, `decline`/`err`, or a wire hiccup — so the caller runs
        cold. A dropped connection is retried once (a daemon may have restarted)."""
        for _ in range(2):
            s = self._ensure()
            if s is None:
                return None
            try:
                flags = (_FLAG_FIXED if request.fixed else 0) | (_FLAG_IGNORE_CASE if request.ignore_case else 0)
                body = bytes([mode, flags]) + request.pattern.encode()
                _send(s, _OP_QUERY, body)
                op, payload = _recv(s)
            except (OSError, _WireError):
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
            raise _WireError("connection closed")
        buf += chunk
    return bytes(buf)


def _recv(s: socket.socket) -> tuple[int, bytes]:
    (length,) = struct.unpack("<I", _recv_exact(s, 4))
    if length == 0 or length > _MAX_FRAME:
        raise _WireError(f"bad frame length {length}")
    body = _recv_exact(s, length)
    return body[0], body[1:]


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
