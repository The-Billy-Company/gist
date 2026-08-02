"""A long artifact home must not be able to kill the process.

The session's rendezvous path is `<artifact home>/gistd.sock`, and every verb
that probes for a resident daemon hands that path to the kernel. The standard
library's `UnixAddress` admits 108 bytes on every POSIX target, but Darwin's
`sun_path` holds 104, and std's POSIX copy is unclamped — so the four lengths in
between were memcpy'd past a stack buffer inside std's connect helper, smashing
the caller's frame. The process then died somewhere else entirely: the crash we
chased surfaced inside an unrelated file read, dereferencing a pointer whose low
bytes spelled "sock", the tail of this very path.

It read as flakiness because whether a run lands in the window depends only on
how long its artifact home happens to be — so it appeared under a test runner
that names temp directories after the test, and never from a shell. This walks
the whole neighborhood on purpose: the bug lived in four lengths, and a fixture
that picked one path length would have missed it the same way everything else
did.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from collections.abc import Iterator
from pathlib import Path

import pytest

import gist

# `<home>/gistd.sock`. The guard is about the address the kernel is handed, so
# the lengths below are measured on that, not on the directory.
RENDEZVOUS = "/gistd.sock"
# 104 is Darwin's `sun_path`; 108 is what std admits. Span both, with room on
# each side, so the assertion does not encode either bound as the expectation.
LENGTHS = range(98, 116)


@pytest.fixture(scope="module")
def binary() -> str:
    try:
        return gist.binary()
    except gist.GistNotFoundError as why:
        pytest.skip(f"no gist binary: {why}")


@pytest.fixture(scope="module")
def root() -> Iterator[Path]:
    """A base short enough that the shortest length under test is still reachable.

    This matters more than it looks. macOS points `TMPDIR` at a ~50-byte
    `/var/folders/…` path and pytest adds its own run directory on top, which
    leaves no room to *build down* to a 105-byte address — the suite would skip
    the entire window it exists to cover and report itself green. Prefer the
    shortest writable temp root available.
    """
    candidates = (Path("/tmp"), Path(tempfile.gettempdir()))
    base = min(
        (c for c in candidates if c.is_dir() and os.access(c, os.W_OK)), key=lambda c: len(str(c))
    )
    made = Path(tempfile.mkdtemp(prefix="g", dir=base))
    try:
        yield made
    finally:
        shutil.rmtree(made, ignore_errors=True)


@pytest.mark.parametrize("length", LENGTHS)
def test_status_survives_every_rendezvous_path_length(binary: str, root: Path, length: int):
    pad = length - len(str(root)) - len(RENDEZVOUS) - 1
    # Not a skip. A length this suite cannot construct is a length it is not
    # checking, and the whole point is that the bug lived in four of them.
    assert pad >= 1, (
        f"base {root} is {len(str(root))} bytes — too long to build a {length}-byte address"
    )
    # Each length yields its own padding width, so the names cannot collide.
    home = root / ("x" * pad)
    home.mkdir()
    assert len(str(home)) + len(RENDEZVOUS) == length

    done = subprocess.run(
        [binary, "status"],
        env={**os.environ, "GIST_DIR": str(home)},
        capture_output=True,
        text=True,
        check=False,
    )
    # A signal is the failure this exists to catch; `returncode` is negative for
    # one, so name it rather than letting it read as an ordinary bad exit.
    assert done.returncode >= 0, (
        f"killed by signal {-done.returncode} on a {length}-byte rendezvous path"
    )
    assert done.returncode == 0, f"status failed on a {length}-byte path:\n{done.stderr}"


def test_a_path_too_long_to_hold_is_reported_as_no_daemon(binary: str, tmp_path):
    """Refusing the address must degrade, not error out. A path the kernel cannot
    hold is a path no daemon can be listening on, which is exactly `none`."""
    home = tmp_path / ("y" * 120)
    home.mkdir()
    done = subprocess.run(
        [binary, "status", "--json"],
        env={**os.environ, "GIST_DIR": str(home)},
        capture_output=True,
        text=True,
        check=False,
    )
    assert done.returncode == 0, done.stderr
    assert '"resident"' in done.stdout and '"none"' in done.stdout, done.stdout
