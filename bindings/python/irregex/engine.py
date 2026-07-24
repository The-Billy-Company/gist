"""The subprocess engine adapter (ADR-352). Locates the certified `gist` binary, lowers a `SearchRequest` into its rg-parity argv, runs it, and parses the result. All faces of the unified API funnel through here, so results are produced by the *same* engine the CLI uses — never a second matcher. Subprocess is the authoritative transport today: a bad pattern exits the child (code 2), surfaced as a typed error, and never terminates the host the way an in-process `die()`/exit would."""

from __future__ import annotations

import functools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from .contract import EXIT_ERROR, EXIT_MATCHED, EXIT_NO_MATCH
from .errors import GistNotFoundError, SearchFailedError, UnsupportedPatternError
from .introspection import IndexStatus
from .request import Match, MatchKind, Ranked, RankKind, SearchRequest, Submatch


DEFAULT_TIMEOUT = 30.0
# stderr phrases the engine prints when a pattern/flag is outside its
# linear-time syntax (see src/surface/exec/cold/{argv/args,engine/serial}.zig `die` messages).
_UNSUPPORTED_MARKERS = (
    "unsupported",
    "use ripgrep",
    "use rg for this",
    "linear-time syntax",
    "not yet implemented",
)


@functools.cache
def _resolve(name: str, env_var: str) -> str:
    """Absolute path to one of the kernel's product binaries. Resolution order: explicit env override, this checkout's built `zig-out/bin/<name>`, then `name` on PATH. Checkout-local wins so a worktree never drives a stale globally installed binary. As an *in-repo* last resort — never in a distributed wheel — build the CLIs once from source when `build.zig` and `zig` are present. A missing engine is **fail-closed** (`GistNotFoundError`), never a silent fallback to a second matcher."""
    env = os.environ.get(env_var)
    if env:
        p = Path(env).expanduser()
        if p.is_file():
            return str(p)
        msg = f"{env_var}={env!r} is not a file"
        raise GistNotFoundError(msg)
    # pkg/kernels/irregex/bindings/python/irregex/engine.py → kernel root is parents[3]
    kernel = Path(__file__).resolve().parents[3]
    built = kernel / "zig-out" / "bin" / name
    if built.is_file():
        return str(built)
    on_path = shutil.which(name)
    if on_path:
        return on_path
    # In-repo bootstrap: the kernel source (`build.zig`) is only present in the
    # monorepo, so this branch is inert in a shipped wheel (pure locator there).
    if (kernel / "build.zig").is_file() and (zig := shutil.which("zig")):
        _build_cli(zig, kernel)
        if built.is_file():
            return str(built)
    msg = (
        f"no `{name}` binary found — set {env_var}, put `{name}` on PATH, "
        "or build it with `make install-gist`"
    )
    raise GistNotFoundError(msg)


def binary() -> str:
    """The `gist` binary (search face). Env override: `GIST_BIN`."""
    return _resolve("gist", "GIST_BIN")


def relate_binary() -> str:
    """The `relate` binary (compression-search face: similar/dups/patterns). Env override: `RELATE_BIN`."""
    return _resolve("relate", "RELATE_BIN")


def _build_cli(zig: str, kernel: Path) -> None:
    """`zig build -Doptimize=ReleaseFast` in the kernel dir — idempotent, and Zig's build cache makes a warm rebuild ~instant. Best-effort: on failure `binary()` falls through to its fail-closed `GistNotFoundError`."""
    try:
        subprocess.run(  # noqa: S603 — fixed argv, no shell
            [zig, "build", "-Doptimize=ReleaseFast"],
            cwd=kernel,
            capture_output=True,
            text=True,
            timeout=600,
            check=False,
        )
    except OSError, subprocess.TimeoutExpired:
        pass


def _invoke(
    tail: list[str],
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None,
    timeout: float,
) -> subprocess.CompletedProcess[str]:
    """Run `gist <flags> <tail> --regexp <pattern> [paths]`.

    `--regexp` carries the pattern so it cannot be mistaken for a flag or path.
    The canonical no-verb face is required: the retired `rg` compatibility
    token consumes only one positional root and drops hidden-mode flags.
    """
    argv = [
        binary(),
        *request.to_argv(),
        *tail,
        "--regexp",
        request.pattern,
        *request.paths,
    ]
    # Binding methods promise complete result sets; CLI context budgets are a
    # presentation concern. The engine's independent hard OOM ceiling remains.
    env = os.environ.copy()
    env["GIST_UNCAP"] = "1"
    env.pop("GIST_MAX_OUTPUT_BYTES", None)
    env.pop("GIST_MAX_OUTPUT_TOKENS", None)
    try:
        proc = subprocess.run(  # noqa: S603 — argv is a fixed list, no shell
            argv,
            capture_output=True,
            text=True,
            cwd=cwd,
            env=env,
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
    """Execute a `SearchRequest` and return structured matches (and any requested context lines), in engine output order."""
    # The CLI's default output budget protects agent context, but truncating a
    # structured API result silently breaks discovery. The process still retains
    # gist's hard 256 MiB OOM ceiling.
    proc = _invoke(["--json", "--uncap"], request, cwd=cwd, timeout=timeout)
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
                text=text.removesuffix("\n").removesuffix("\r"),
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
    """Total matching lines across the searched tree.

    rg `-c`/`--count`, one line counted once regardless of how many times the
    pattern hits it — the semantic every other count surface shares
    (`irregex.count`/`Session.count` docstrings, the resident daemon's
    `countLines`, the in-process FFI's per-line stream). Was
    `--count-matches` (per-occurrence), which over-counted a line with
    repeated hits and silently diverged from the warm transports.
    """
    proc = _invoke(["--count", "--no-filename"], request, cwd=cwd, timeout=timeout)
    return sum(int(x) for x in proc.stdout.splitlines() if x.strip().isdigit())


def count_matches(
    request: SearchRequest,
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> int:
    """Total match occurrences across the searched tree."""
    proc = _invoke(["--count-matches", "--no-filename"], request, cwd=cwd, timeout=timeout)
    return sum(int(x) for x in proc.stdout.splitlines() if x.strip().isdigit())


# One `--rank` row: rank-index, `path:line`, `[def|use|gen]`, the per-file count,
# then the snippet (rank.zig). `\u00d7` is the multiplication sign the engine
# prints ahead of the count (kept as an escape so the source stays ASCII).
_RANK_ROW = re.compile(
    r"^\s*\d+\.\s+(?P<path>.+?):(?P<line>\d+)\s+\[(?P<kind>def|use|gen)\]\s+\u00d7(?P<count>\d+)\s+(?P<snippet>.*)$"
)


def rank(
    request: SearchRequest,
    *,
    limit: int = 20,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[Ranked]:
    """The engine's definition-first `--rank` view: the top-`limit` files for the request's pattern, each tagged with the engine's own `def`/`use`/`gen` class (`limit <= 0` uses the engine default of 20). Ranking needs a persisted index — with none there is nothing to rank, so the result is empty. This is gist's one native shape with no rg equivalent; the def/use/gen class is read straight from the engine, never reclassified here."""
    tail = ["--rank"] if limit <= 0 else [f"--rank={limit}"]
    proc = _invoke(tail, request, cwd=cwd, timeout=timeout)
    return _parse_rank(proc.stdout)


def _parse_rank(stream: str) -> list[Ranked]:
    """Parse `--rank` stdout rows into `Ranked` records (timing goes to stderr, so stdout is rows only)."""
    out: list[Ranked] = []
    for line in stream.splitlines():
        m = _RANK_ROW.match(line)
        if m is None:
            continue
        out.append(
            Ranked(
                path=m["path"],
                line_number=int(m["line"]),
                kind=RankKind(m["kind"]),
                count=int(m["count"]),
                snippet=m["snippet"],
            )
        )
    return out


def status(
    *,
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> IndexStatus:
    """Structured persisted-index state; retained here for adapter callers."""
    from .introspection import status as inspect

    return inspect(cwd=cwd, timeout=timeout)


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
