"""The subprocess engine adapter (ADR-352).

Locates the certified `gist` binary, lowers a `SearchRequest` into its rg-parity
argv, runs it, and parses the result. All faces of the unified API funnel
through here, so results are produced by the *same* engine the CLI uses — never
a second matcher. Subprocess is the authoritative transport today: a bad pattern
exits the child (code 2), surfaced as a typed error, and never terminates the
host the way an in-process `die()`/exit would.
"""

from __future__ import annotations

import functools
import json
import os
from pathlib import Path
import shutil
import subprocess

from .contract import EXIT_ERROR, EXIT_MATCHED, EXIT_NO_MATCH
from .errors import GistNotFoundError, SearchFailedError, UnsupportedPatternError
from .request import Match, MatchKind, SearchRequest, Submatch


DEFAULT_TIMEOUT = 30.0
# stderr phrases the engine prints when a pattern/flag is outside its
# linear-time syntax (see src/commands/ripgrep/{args,run}.zig `die` messages).
_UNSUPPORTED_MARKERS = (
    "unsupported",
    "use ripgrep",
    "use rg for this",
    "linear-time syntax",
    "not yet implemented",
)


@functools.cache
def binary() -> str:
    """Absolute path to the `gist` binary. Resolution order: env `GIST_BIN`,
    then `gist` on PATH, then the repo's freshly built `zig-out/bin/gist`."""
    env = os.environ.get("GIST_BIN")
    if env:
        p = Path(env).expanduser()
        if p.is_file():
            return str(p)
        msg = f"GIST_BIN={env!r} is not a file"
        raise GistNotFoundError(msg)
    on_path = shutil.which("gist")
    if on_path:
        return on_path
    # pkg/kernels/gist/bindings/python/gist/engine.py → kernel root is parents[3]
    built = Path(__file__).resolve().parents[3] / "zig-out" / "bin" / "gist"
    if built.is_file():
        return str(built)
    msg = (
        "no `gist` binary found — set GIST_BIN, put `gist` on PATH, "
        "or build it with `make install-gist`"
    )
    raise GistNotFoundError(msg)


def _invoke(
    tail: list[str],
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    """Run `gist rg <flags> <tail> --regexp <pattern> [paths]`. `--regexp`
    carries the pattern so it can never be mistaken for a flag or a path."""
    argv = [
        binary(),
        "rg",
        *request.to_argv(),
        *tail,
        "--regexp",
        request.pattern,
        *request.paths,
    ]
    try:
        proc = subprocess.run(  # noqa: S603 — argv is a fixed list, no shell
            argv,
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=timeout,
            check=False,
            # Detach stdin: with no path args and a non-tty stdin the engine
            # would read *stdin* (rg's stdin path) instead of walking the tree.
            # /dev/null is not "readable", so it always walks — matching a
            # bare `rg <pat> </dev/null`.
            stdin=subprocess.DEVNULL,
        )
    except FileNotFoundError as e:  # binary vanished between resolution and run
        raise GistNotFoundError(str(e)) from e
    except subprocess.TimeoutExpired as e:
        msg = f"gist timed out after {timeout}s"
        raise SearchFailedError(msg) from e
    if proc.returncode == EXIT_ERROR:
        stderr = proc.stderr.strip()
        low = stderr.lower()
        if any(m in low for m in _UNSUPPORTED_MARKERS):
            raise UnsupportedPatternError(stderr or "unsupported pattern")
        raise SearchFailedError(stderr or "gist exited 2")
    if proc.returncode not in (EXIT_MATCHED, EXIT_NO_MATCH):
        msg = f"gist exited {proc.returncode}: {proc.stderr.strip()}"
        raise SearchFailedError(msg)
    return proc


def run(
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[Match]:
    """Execute a `SearchRequest` and return structured matches (and any
    requested context lines), in engine output order."""
    proc = _invoke(["--json"], request, cwd=cwd, timeout=timeout)
    return _parse_json(proc.stdout)


def _parse_json(stream: str) -> list[Match]:
    """Parse ripgrep's JSON-lines record stream into `Match` records."""
    out: list[Match] = []
    for line in stream.splitlines():
        if not line:
            continue
        rec = json.loads(line)
        kind = rec.get("type")
        if kind not in ("match", "context"):
            continue
        data = rec["data"]
        text = data["lines"].get("text", "")
        subs = tuple(
            Submatch(text=s["match"]["text"], start=s["start"], end=s["end"])
            for s in data.get("submatches", [])
        )
        out.append(
            Match(
                path=data["path"]["text"],
                line_number=data.get("line_number") or 0,
                text=text.rstrip("\n"),
                kind=MatchKind(kind),
                submatches=subs,
            )
        )
    return out


def files(
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[str]:
    """Paths of files with ≥1 matching line (`-l`), sorted."""
    proc = _invoke(["-l"], request, cwd=cwd, timeout=timeout)
    return sorted(ln for ln in proc.stdout.splitlines() if ln)


def count(
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> int:
    """Total matching lines across the searched tree (`--count-matches`)."""
    proc = _invoke(["--count-matches", "--no-filename"], request, cwd=cwd, timeout=timeout)
    return sum(int(x) for x in proc.stdout.splitlines() if x.strip().isdigit())


def status(*, cwd: str | os.PathLike[str] | None = None, timeout: float = DEFAULT_TIMEOUT) -> str:
    """The persisted-index report (`gist status`) — is an index ready, how
    fresh, how big. Read-only; safe to call blind."""
    proc = subprocess.run(  # noqa: S603 — fixed argv, no shell
        [binary(), "status"],
        capture_output=True,
        text=True,
        cwd=cwd,
        timeout=timeout,
        check=False,
    )
    return proc.stdout


@functools.cache
def version() -> str:
    """The driven binary's semver (from `gist --version`)."""
    proc = subprocess.run(  # noqa: S603 — fixed argv, no shell
        [binary(), "--version"], capture_output=True, text=True, check=False
    )
    # `gist 0.1.0` → `0.1.0`. The banner prints via Zig `std.debug.print`
    # (stderr), so read whichever stream carries it.
    parts = (proc.stdout or proc.stderr).strip().split()
    return parts[-1] if parts else ""
