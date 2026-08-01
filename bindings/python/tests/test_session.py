"""Persistent resident-session client tests.

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
from irregex.request import SearchEngine, SearchRequest
from irregex.runtime.daemon import PROTOCOL_VERSION, SessionGeneration, _decode_ready


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
    # v2 lane 2: -w is warm-eligible (the session applies cold's word rule).
    assert gist.warm_eligible(SearchRequest(pattern="TODO", word=True))
    # v2 lane 4: -q and -m N (incl the falsy -m0) are warm-eligible too.
    assert gist.warm_eligible(SearchRequest(pattern="TODO", quiet=True))
    assert gist.warm_eligible(SearchRequest(pattern="TODO", max_count=3))
    assert gist.warm_eligible(SearchRequest(pattern="TODO", max_count=0))
    # v2 lane 3b: -v is warm-eligible (the set-complement, sound under the index).
    assert gist.warm_eligible(SearchRequest(pattern="TODO", invert=True))
    assert gist.warm_eligible(SearchRequest(pattern="TODO", invert=True, word=True))


@pytest.mark.parametrize(
    "req",
    [
        SearchRequest(pattern="x", paths=("services",)),  # scoped roots
        SearchRequest(pattern="x", globs=("*.py",)),  # glob scoping
        SearchRequest(pattern="x", types=("py",)),  # type scoping
        SearchRequest(pattern="x", context=2),  # context lines
        SearchRequest(pattern="x", before=2),  # asymmetric context side
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
        bytes([PROTOCOL_VERSION]) + struct.pack("<QQQI", 7, 42, 99, len(b"gen-abc")) + b"gen-abc"
    )
    assert _decode_ready(payload) == SessionGeneration(7, 42, "gen-abc", image=99)
    assert _decode_ready(payload[:-1]) is None


def test_ready_frame_refuses_a_pre_v9_payload() -> None:
    # A v8 daemon's READY has no image field, so its 21-byte header would place
    # the index gen where the image sits. The version byte refuses it first —
    # the fail-open skew check that keeps a stale daemon from being parsed at
    # all, rather than parsed wrongly.
    v8 = bytes([8]) + struct.pack("<QQI", 7, 42, len(b"gen-abc")) + b"gen-abc"
    assert _decode_ready(v8) is None


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
            pytest.fail("daemon did not come up within the wait budget")
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
            # lane 3b: the invert complement, warm end-to-end (FFI → UDS → cold).
            warm_inv_files = s.files(SearchRequest(pattern="TODO", invert=True))
            warm_inv_count = s.count(SearchRequest(pattern="TODO", invert=True))
        # Cold oracle over the same subtree ".".
        cold_files = gist.files("TODO", paths=(".",), cwd=corpus)
        cold_count = gist.count("TODO", paths=(".",), cwd=corpus)
        cold_ci = gist.count("TODO", ignore_case=True, paths=(".",), cwd=corpus)
        cold_inv_files = gist.files("TODO", invert=True, paths=(".",), cwd=corpus)
        cold_inv_count = gist.count("TODO", invert=True, paths=(".",), cwd=corpus)
        assert _norm(warm_files) == _norm(cold_files)
        assert warm_count == cold_count
        assert warm_ci == cold_ci
        assert warm_ci > warm_count  # 'todo' lowercase pulled in by -i
        assert _norm(warm_inv_files) == _norm(cold_inv_files)
        assert warm_inv_count == cold_inv_count
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        shutil.rmtree(sock_dir, ignore_errors=True)


# ─────────────────────────── ensure_serve / opening_session ───────────────────────────


def test_ensure_serve_no_op_when_daemon_up(corpus, monkeypatch) -> None:
    # A socket that already accepts must short-circuit: no spawn, returns True.
    sock_dir = tempfile.mkdtemp(prefix="gistd-")
    sock = os.path.join(sock_dir, "g.sock")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock)
    srv.listen(1)

    def _boom(*_a, **_k):  # spawning would be a bug — the daemon is already up
        raise AssertionError("ensure_serve spawned despite a live socket")

    monkeypatch.setattr(subprocess, "Popen", _boom)
    try:
        assert gist.ensure_serve(cwd=corpus, socket_path=sock) is True
    finally:
        srv.close()
        shutil.rmtree(sock_dir, ignore_errors=True)


def test_ensure_serve_respects_opt_out(corpus, monkeypatch) -> None:
    # GIST_NO_AUTOSERVE → never spawn, and (no daemon) → False.
    sock = str(corpus / "unused.sock")
    monkeypatch.setenv("GIST_NO_AUTOSERVE", "1")

    def _boom(*_a, **_k):
        raise AssertionError("ensure_serve spawned despite GIST_NO_AUTOSERVE")

    monkeypatch.setattr(subprocess, "Popen", _boom)
    assert gist.ensure_serve(cwd=corpus, socket_path=sock) is False


@needs_gist
def test_opening_session_spawns_and_serves_warm(corpus) -> None:
    # End-to-end: no daemon listening → opening_session spawns one, connects, and
    # a rootless eligible query answers, agreeing with the cold oracle.
    sock_dir = tempfile.mkdtemp(prefix="gistd-")
    sock = os.path.join(sock_dir, "g.sock")
    try:
        with gist.opening_session(cwd=corpus, socket_path=sock) as s:
            if s.generation is None:
                pytest.fail("daemon did not come up within the wait budget")
            warm_files = s.files(SearchRequest(pattern="TODO"))
            warm_count = s.count(SearchRequest(pattern="TODO"))
        cold_files = gist.files("TODO", paths=(".",), cwd=corpus)
        cold_count = gist.count("TODO", paths=(".",), cwd=corpus)
        assert _norm(warm_files) == _norm(cold_files)
        assert warm_count == cold_count
    finally:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            try:
                c.connect(sock)
                c.sendall(struct.pack("<I", 1) + bytes([7]))  # _OP_SHUTDOWN
            except OSError:
                pass
        shutil.rmtree(sock_dir, ignore_errors=True)


def test_connect_deadline_against_unresponsive_daemon(corpus) -> None:
    # A socket that ACCEPTS the TCP-level connect but never answers the HELLO
    # (the exact shape of the pre-multiplex daemon busy with another client, or
    # a wedged one) must cost at most ~SESSION_IO_TIMEOUT before failing open —
    # never park the caller indefinitely on the handshake recv.
    from irregex.runtime.daemon import SESSION_IO_TIMEOUT

    sock_dir = tempfile.mkdtemp(prefix="gistd-")
    sock = os.path.join(sock_dir, "g.sock")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock)
    srv.listen(4)  # backlog admits the connect; nothing ever reads the HELLO
    try:
        with gist.Session(sock, cwd=corpus) as s:
            t0 = time.monotonic()
            ok = s.connect()
            elapsed = time.monotonic() - t0
        assert ok is False
        assert elapsed < SESSION_IO_TIMEOUT + 2.0
    finally:
        srv.close()
        shutil.rmtree(sock_dir, ignore_errors=True)


def test_absent_false_without_daemon(corpus) -> None:
    # No daemon → absent must be False (fail-open: "run your own scan"), never a
    # spurious True that would skip an authoritative scan.
    with gist.Session(str(corpus / "nope.sock"), cwd=corpus) as s:
        assert s.absent("TODO") is False
        assert s.absent("this_string_is_nowhere_xyzzy") is False


@needs_gist
def test_absent_matches_broad_tree(corpus) -> None:
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
            pytest.fail("daemon did not come up within the wait budget")
        with gist.Session(sock, cwd=corpus) as s:
            assert s.connect()
            # Present tree-wide → not absent; genuinely missing → absent.
            assert s.absent("TODO") is False
            assert s.absent("this_string_is_nowhere_xyzzy") is True
    finally:
        proc.terminate()
        proc.wait(timeout=10)
        shutil.rmtree(sock_dir, ignore_errors=True)
