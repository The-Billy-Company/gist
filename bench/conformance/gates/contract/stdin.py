#!/usr/bin/env python3
"""Prove stdin source identity against the actual CLI, cold and daemon-present.

Usage: python3 stdin.py /absolute/path/to/gist
No build or installation; streams.sh supplies the artifact it already built.
"""

from __future__ import annotations

import contextlib
import json
import os
import pty
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def prove(binary: Path) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="gist-stdin-") as temporary:
        root = Path(temporary)
        corpus = root / "corpus"
        corpus.mkdir()
        (corpus / "poison.txt").write_bytes(b"needle tree\n")
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIST_")}
        env.update(
            GIST_DIR=str(root / "index"), GIST_NO_AUTOSERVE="1", GIST_HINTS="0", GIST_UNCAP="1"
        )

        @contextlib.contextmanager
        def child(*args: str, stdin=subprocess.PIPE, overrides=None):
            process = subprocess.Popen(
                [str(binary), *args],
                cwd=corpus,
                env=env | (overrides or {}),
                stdin=stdin,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            try:
                yield process
            finally:
                if process.poll() is None:
                    process.terminate()
                _, stderr = process.communicate(timeout=5)
                if args[0] == "serve" and stderr:
                    print(stderr.decode(errors="replace"), file=sys.stderr, end="")

        def check(process, label, code, output, data=None, diagnostic=None):
            stdout, stderr = process.communicate(input=data, timeout=5)
            assert (process.returncode, stdout) == (code, output), (
                label,
                process.returncode,
                stdout,
                stderr,
            )
            if diagnostic is not None:
                assert diagnostic in stderr, (label, stderr)
            results.append({"case": label, "exit": process.returncode, "stdout_bytes": len(stdout)})

        for topology in ("cold", "daemon"):
            with contextlib.ExitStack() as stack:
                if topology == "daemon":
                    endpoint = root / "resident.sock"
                    env.update(GIST_SESSION_SOCK=str(endpoint), GIST_TRACE="warm")
                    # Auto-spawn uses bare `serve`: explicit '.' preserves its
                    # path prefix and is a different resident corpus contract.
                    server = stack.enter_context(child("serve", stdin=subprocess.DEVNULL))
                    deadline = time.monotonic() + 10
                    while not endpoint.exists():
                        assert server.poll() is None, server.communicate()
                        assert time.monotonic() < deadline, "daemon never bound its socket"
                        time.sleep(0.01)

                # A slow first byte cannot become the matching CWD file. Checking
                # before sending also rejects an implementation that searched early.
                with child("needle") as process:
                    time.sleep(2.2)
                    assert process.poll() is None, (
                        topology,
                        "quiet pipe changed source",
                        process.communicate(),
                    )
                    check(process, f"{topology}/delayed", 0, b"needle stream\n", b"needle stream\n")

                for overrides in ({}, {"GIST_STDIN_WAIT_MS": "0"}):
                    with child("needle", overrides=overrides) as process:
                        check(process, f"{topology}/empty/{bool(overrides)}", 1, b"", b"")
                    reader, writer = socket.socketpair()
                    with reader, writer:
                        writer.close()
                        with child("needle", stdin=reader, overrides=overrides) as process:
                            check(process, f"{topology}/socket-eof/{bool(overrides)}", 1, b"")

                reader, writer = socket.socketpair()
                with reader, writer, child("needle", stdin=reader) as process:
                    time.sleep(2.2)
                    assert process.poll() is None, (topology, "quiet socket changed source")
                    writer.sendall(b"needle socket\n")
                    writer.shutdown(socket.SHUT_WR)
                    check(process, f"{topology}/socket-delayed", 0, b"needle socket\n")

                # Named paths must not consume or wait on the inherited pipe. The
                # trace proves the daemon-present arm was actually answered warm.
                with child("needle", "poison.txt", "-l") as process:
                    process.wait(timeout=5)
                    check(
                        process,
                        f"{topology}/explicit-path",
                        0,
                        b"poison.txt\n",
                        diagnostic=b"[warm]" if topology == "daemon" else None,
                    )

                with child("needle", overrides={"GIST_STDIN_WAIT_MS": "10"}) as process:
                    process.wait(timeout=5)  # Keep the writer open and silent.
                    check(
                        process,
                        f"{topology}/explicit-timeout",
                        2,
                        b"",
                        diagnostic=b"input was not searched",
                    )

                with child("needle") as process:
                    time.sleep(0.1)
                    assert process.poll() is None, "quiet input unexpectedly completed"
                    started = time.monotonic()
                    process.send_signal(signal.SIGINT)
                    check(process, f"{topology}/cancel", -signal.SIGINT, b"")
                    results[-1]["cancel_ms"] = round((time.monotonic() - started) * 1000, 3)

        # The read loop must preserve later bytes and refuse incomplete reads.
        with child("needle") as process:
            process.stdin.write(b"needle first\n")
            process.stdin.flush()
            time.sleep(2.2)
            assert process.poll() is None, "a pause after data truncated stdin"
            check(process, "paused-chunks", 0, b"needle first\nneedle last\n", b"needle last\n")

        source = root / "redirected.txt"
        source.write_bytes(b"needle file\n")
        with source.open("rb") as stdin, child("needle", stdin=stdin) as process:
            check(process, "regular-file", 0, b"needle file\n")
        with child("needle", "-l", stdin=subprocess.DEVNULL) as process:
            check(process, "devnull-default-tree", 0, b"poison.txt\n")
        with child("needle", ".", "-l") as process:
            process.wait(timeout=5)
            check(process, "explicit-dot", 0, b"./poison.txt\n")
        master, terminal = pty.openpty()
        try:
            with child("needle", "-l", stdin=terminal) as process:
                check(process, "interactive-default-tree", 0, b"poison.txt\n")
        finally:
            os.close(master)
            os.close(terminal)

        reader, writer = os.pipe()
        try:
            os.set_blocking(reader, False)
            os.write(writer, b"needle incomplete\n")
            with child("needle", stdin=reader) as process:
                check(process, "partial-read-error", 2, b"", diagnostic=b"cannot read stdin")
        finally:
            os.close(reader)
            os.close(writer)

        # O_RDWR does not mean this process is the sole writer. Admit the named
        # FIFO, allow another writer, then cancel (our own writer prevents EOF).
        fifo = root / "input.fifo"
        os.mkfifo(fifo)
        reader = os.open(fifo, os.O_RDWR)
        try:
            with child("needle", stdin=reader) as process:
                time.sleep(0.1)
                assert process.poll() is None, "read-write FIFO was treated as a tree"
                with fifo.open("wb", buffering=0) as writer:
                    writer.write(b"needle other writer\n")
                time.sleep(0.1)
                assert process.poll() is None, "read-write FIFO was silently truncated"
                process.send_signal(signal.SIGINT)
                check(process, "read-write-fifo", -signal.SIGINT, b"")
        finally:
            os.close(reader)
    return results


if __name__ == "__main__":
    if not __debug__:
        raise SystemExit("stdin proof requires Python assertions enabled")
    print(json.dumps(prove(Path(sys.argv[1]).resolve(strict=True)), indent=2))
