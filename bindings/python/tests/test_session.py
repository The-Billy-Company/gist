"""Persistent resident-session client tests (ADR-352 rung 2.5).

Three layers: the pure `warm_eligible` classifier (no binary), fail-open when no
daemon is listening (must equal the cold answer), and a real round-trip against a
spawned subtree daemon — the Python leg of the same wire protocol the Zig client
and `serve_test.zig` exercise, proving a warm query decodes end-to-end and agrees
with cold.
"""

from __future__ import annotations

import os
import shutil
import socket
import struct
import subprocess
import tempfile
import time

import pytest

import gist
from gist.request import SearchEngine, SearchRequest
from gist.session import PROTOCOL_VERSION, SessionGeneration, _decode_ready


def _binary_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        gist.binary()
    except gist.GistNotFoundError:
        return False
    return True


needs_gist = pytest.mark.skipif(not _binary_available(), reason="no gist binary")


@pytest.fixture
def corpus(tmp_path):
    (tmp_path / "a.py").write_text("def alpha():\n    return TODO\n")
    (tmp_path / "b.py").write_text("class Beta:\n    pass  # TODO later\n")
    (tmp_path / "c.txt").write_text("no marker here\nplain text\n")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "d.py").write_text("x = 1  # todo lowercase\nTODO upper\n")
    return tmp_path


def _norm(paths) -> set[str]:
    return {p.removeprefix("./") for p in paths}


# ─────────────────────────── pure classifier ───────────────────────────


def test_warm_eligible_accepts_default_roots_literal() -> None:
    assert gist.warm_eligible(SearchRequest(pattern="TODO"))
    assert gist.warm_eligible(SearchRequest(pattern="TODO", fixed=True, ignore_case=True))


@pytest.mark.parametrize(
    "req",
    [
        SearchRequest(pattern="x", paths=("services",)),  # scoped roots
        SearchRequest(pattern="x", globs=("*.py",)),  # glob scoping
        SearchRequest(pattern="x", types=("py",)),  # type scoping
        SearchRequest(pattern="x", context=2),  # context lines
        SearchRequest(pattern="x", word=True),  # rich flag
        SearchRequest(pattern="x", invert=True),
        SearchRequest(pattern="x", max_count=3),
        SearchRequest(pattern="x", extra_flags=("-P",)),  # raw argv
        SearchRequest(pattern="x", engine=SearchEngine.AUTO),
        SearchRequest(pattern="x", multiline=True),
        SearchRequest(pattern="x", unicode=False),
    ],
)
def test_warm_eligible_rejects_rich_requests(req: SearchRequest) -> None:
    assert not gist.warm_eligible(req)


def test_ready_frame_decodes_all_generations() -> None:
    payload = (
        bytes([PROTOCOL_VERSION])
        + struct.pack("<QQI", 7, 42, len(b"gen-abc"))
        + b"gen-abc"
    )
    assert _decode_ready(payload) == SessionGeneration(7, 42, "gen-abc")
    assert _decode_ready(payload[:-1]) is None


# ─────────────────────────── fail-open (no daemon) ───────────────────────────


@needs_gist
def test_no_daemon_falls_back_to_cold(corpus) -> None:
    # A socket path that nothing is listening on → the session must transparently
    # produce the byte-identical cold answer, never raise.
    sock = str(corpus / "nonexistent.sock")
    with gist.Session(sock, cwd=corpus) as s:
        warm = s.files(SearchRequest(pattern="TODO", paths=(".",)))
    cold = gist.files("TODO", paths=(".",), cwd=corpus)
    assert warm == cold
    assert any(p.endswith("a.py") for p in warm)


# ─────────────────────────── round-trip (live daemon) ───────────────────────────


def _wait_for_socket(path: str, proc: subprocess.Popen, timeout: float = 15.0) -> bool:
    """Poll until the daemon's socket accepts a connection (or it dies)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return False
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as probe:
                probe.connect(path)
            return True
        except OSError:
            time.sleep(0.02)
    return False


@needs_gist
def test_round_trip_matches_cold(corpus) -> None:
    # The socket must live under a short dir: macOS caps a UNIX sun_path at
    # ~104 bytes and pytest's tmp_path blows past it. The daemon still serves
    # the (long-path) corpus as its root — only the bind address is length-bound.
    sock_dir = tempfile.mkdtemp(prefix="gistd-")
    sock = os.path.join(sock_dir, "g.sock")
    proc = subprocess.Popen(  # noqa: S603 — fixed argv, no shell
        [gist.binary(), "serve", "."],
        cwd=corpus,
        env={**os.environ, "GIST_SESSION_SOCK": sock},
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        if not _wait_for_socket(sock, proc):
            pytest.skip("daemon did not come up")
        with gist.Session(sock, cwd=corpus) as s:
            assert s.connect()
            initial = s.generation
            assert initial is not None
            assert initial.daemon > 0
            assert initial.session > 0
            assert isinstance(initial.index, str)
            assert s.refresh_generation() == initial
            assert not s.generation_changed
            # Warm files/count over default roots (the daemon serves ".").
            warm_files = s.files(SearchRequest(pattern="TODO"))
            warm_count = s.count(SearchRequest(pattern="TODO"))
            warm_ci = s.count(SearchRequest(pattern="TODO", ignore_case=True))
        # Cold oracle over the same subtree ".".
        cold_files = gist.files("TODO", paths=(".",), cwd=corpus)
        cold_count = gist.count("TODO", paths=(".",), cwd=corpus)
        cold_ci = gist.count("TODO", ignore_case=True, paths=(".",), cwd=corpus)
        assert _norm(warm_files) == _norm(cold_files)
        assert warm_count == cold_count
        assert warm_ci == cold_ci
        assert warm_ci > warm_count  # 'todo' lowercase pulled in by -i
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        shutil.rmtree(sock_dir, ignore_errors=True)
