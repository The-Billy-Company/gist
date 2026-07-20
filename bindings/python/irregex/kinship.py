"""The relate face — the irregular-expression verbs, importable (ADR-352 shape). Three native engine surfaces with no rg equivalent, driven through the certified `relate` binary (same kernel as `gist`, never a second matcher): `similar` (nearest files by compression kinship — LZ78 dictionary sketches, LZJD distance), `dups` (near-duplicate pairs, closest first), and `patterns` (one walk, N patterns, exact per-pattern attribution, optionally grouped into counts engine-side). Each function shells the verb with `--json` and parses its NDJSON rows into typed records; distances and attribution are computed in the kernel, never re-derived here. Corpus policy is the verbs' own (the index corpus: non-binary files under the roots minus VCS/build subtrees) — see `contract/search_api.toml` `[irregex]`."""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import subprocess
from typing import TYPE_CHECKING

from .engine import DEFAULT_TIMEOUT, relate_binary
from .errors import GistNotFoundError, SearchFailedError


if TYPE_CHECKING:
    from collections.abc import Sequence


@dataclass(frozen=True, slots=True)
class Similar:
    """One kinship neighbor: `distance` ∈ [0, 1], 0 = identical dictionaries."""

    path: str
    distance: float


@dataclass(frozen=True, slots=True)
class DupPair:
    """One verified near-duplicate pair, `a` < `b` in path order."""

    a: str
    b: str
    distance: float


@dataclass(frozen=True, slots=True)
class PatternHit:
    """One attributed match row: pattern `pattern_id` (source `pattern`) hit `path` at `line`."""

    path: str
    line: int
    pattern_id: int
    pattern: str


@dataclass(frozen=True, slots=True)
class PatternCount:
    """One engine-side group: `label` is a pattern source or a file path."""

    label: str
    count: int


def _run(argv: list[str], *, cwd: str | os.PathLike[str] | None, timeout: float) -> str:
    """Run one relate verb; NDJSON rows on stdout, diagnostics on stderr."""
    try:
        proc = subprocess.run(  # noqa: S603 — fixed argv, no shell
            [relate_binary(), *argv],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=timeout,
            check=False,
            stdin=subprocess.DEVNULL,
        )
    except FileNotFoundError as e:  # binary vanished between resolution and run
        raise GistNotFoundError(str(e)) from e
    except subprocess.TimeoutExpired as e:
        msg = f"relate timed out after {timeout}s"
        raise SearchFailedError(msg) from e
    if proc.returncode != 0:
        msg = proc.stderr.strip() or f"relate exited {proc.returncode}"
        raise SearchFailedError(msg)
    return proc.stdout


def _rows(stdout: str) -> list[dict[str, object]]:
    return [json.loads(line) for line in stdout.splitlines() if line]


def _num(row: dict[str, object], key: str) -> float:
    """Narrow one NDJSON field to a number — the engine's rows are the trust boundary."""
    v = row[key]
    if isinstance(v, bool) or not isinstance(v, int | float):
        msg = f"relate: non-numeric {key!r} in row: {v!r}"
        raise SearchFailedError(msg)
    return float(v)


def _count(row: dict[str, object], key: str) -> int:
    return int(_num(row, key))


def similar(
    path: str | os.PathLike[str],
    *,
    top: int = 20,
    roots: Sequence[str] = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[Similar]:
    """The `top` nearest files to `path` by compression kinship, ascending distance (the target itself excluded)."""
    argv = ["similar", os.fspath(path), "--top", str(top), "--json", *roots]
    return [
        Similar(path=str(r["path"]), distance=_num(r, "distance"))
        for r in _rows(_run(argv, cwd=cwd, timeout=timeout))
    ]


def dups(
    *,
    max_distance: float = 0.25,
    top: int = 100,
    roots: Sequence[str] = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[DupPair]:
    """Near-duplicate pairs across the corpus at distance ≤ `max_distance`, closest first."""
    argv = ["dups", "--max-distance", str(max_distance), "--top", str(top), "--json", *roots]
    return [
        DupPair(a=str(r["a"]), b=str(r["b"]), distance=_num(r, "distance"))
        for r in _rows(_run(argv, cwd=cwd, timeout=timeout))
    ]


def patterns(
    specs: Sequence[str],
    *,
    fixed: bool = False,
    ignore_case: bool = False,
    under: str | None = None,
    top: int = 0,
    roots: Sequence[str] = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[PatternHit]:
    """One walk, every pattern in `specs`, exact per-pattern attribution as `PatternHit` rows in total (path, line, pattern) order. This is the batched shape that replaces N sequential searches + downstream re-classification."""
    argv = ["patterns", *_pattern_argv(specs, fixed, ignore_case, under, top), "--json", *roots]
    return [
        PatternHit(
            path=str(r["path"]),
            line=_count(r, "line"),
            pattern_id=_count(r, "pattern_id"),
            pattern=str(r["pattern"]),
        )
        for r in _rows(_run(argv, cwd=cwd, timeout=timeout))
    ]


def pattern_counts(
    specs: Sequence[str],
    *,
    by: str = "pattern",
    fixed: bool = False,
    ignore_case: bool = False,
    under: str | None = None,
    top: int = 0,
    roots: Sequence[str] = (),
    cwd: str | os.PathLike[str] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> list[PatternCount]:
    """Grouped counts (`by` = `"pattern"` or `"file"`), descending, computed engine-side by the loom — no rows cross the process boundary."""
    argv = [
        "patterns",
        *_pattern_argv(specs, fixed, ignore_case, under, top),
        "--by",
        by,
        "--json",
        *roots,
    ]
    return [
        PatternCount(label=str(r["label"]), count=_count(r, "count"))
        for r in _rows(_run(argv, cwd=cwd, timeout=timeout))
    ]


def _pattern_argv(
    specs: Sequence[str], fixed: bool, ignore_case: bool, under: str | None, top: int
) -> list[str]:
    if not specs:
        msg = "patterns: at least one pattern is required"
        raise ValueError(msg)
    argv: list[str] = []
    for s in specs:
        argv += ["-e", s]
    if fixed:
        argv.append("-F")
    if ignore_case:
        argv.append("-i")
    if under is not None:
        argv += ["--under", under]
    if top:
        argv += ["--top", str(top)]
    return argv
