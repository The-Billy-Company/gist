"""doc_radar ↔ GIST equivalence + warm-path canary (ADR-352).

doc_radar (`scripts/observe/trust/doc_radar/lib.py`) drives three ripgrep
wrappers: `ripgrep` (count matching lines over paths), `ripgrep_batch` (a fan
of those over every ADR `still_here` pin), and `ripgrep_files` (files-with-a-
match, for marker discovery). The plan's step 4 makes doc_radar the canary for
the unified API; step 6 graduates GIST into those wrappers **only** if it is a
byte-equivalent substitute *and* the repeated-query path wins materially.

This harness produces exactly that evidence, over doc_radar's *real* query
corpus — the marker-discovery pattern plus every `still_here` pin declared in
the ADR frontmatter — never a synthetic stand-in:

- **Equivalence.** For every query it runs `rg` (the oracle) and GIST (via the
  importable package, so the canary dogfoods the new API) and asserts identical
  results. A pattern GIST cannot accept in its linear-time engine is recorded
  as `unsupported` — a fail-loud gap the live radar would fall back to `rg`
  for, never a silent divergence.
- **Warm-path benefit.** It times the whole count batch three ways — `rg`,
  GIST warm (riding the persisted `.local/gist-verify/index.gist`), and GIST
  cold (`--no-index`, a fresh walk) — so the graduation decision rests on
  measured numbers, not the plan's assumption. When a `gist serve` daemon is
  serving the tree it also times a fourth, report-only leg (`gist_session`):
  doc_radar's real resident-Session count batch (ADR-352 rung 2.5). This leg
  never gates the canary — it is present only as evidence.

Run it: `python -m canary.doc_radar [--json] [--root PATH] [--limit N]`.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import TYPE_CHECKING

import gist
from gist.errors import GistError


if TYPE_CHECKING:
    from collections.abc import Iterable, Sequence


def _find_root(start: Path | None = None) -> Path:
    """Walk upward from here (or `start`) to the repo root (the dir holding
    `.git`), so the canary resolves the corpus regardless of CWD.
    """
    here = (start or Path(__file__)).resolve()
    for parent in (here, *here.parents):
        if (parent / ".git").exists():
            return parent
    # bindings/python/canary/doc_radar.py → repo root is parents[5]
    return Path(__file__).resolve().parents[5]


# ── query corpus ─────────────────────────────────────────────────────

# doc_radar's marker-discovery query (lib.discover_doc_markers): the one
# files-with-match pass that finds every doc opting into the radar.
MARKER_PATTERN = r"^(?:doc_radar:|.*doc-radar:begin)"
MARKER_GLOBS: tuple[str, ...] = ("*.md", "*.mdc")


@dataclass(frozen=True, slots=True)
class CountQuery:
    """A `ripgrep`-shaped count query: matching lines of `pattern` under
    `paths` (repo-relative).
    """

    pattern: str
    paths: tuple[str, ...]
    origin: str  # e.g. "ADR-352 still_here" — for report attribution


def _radar_lib(root: Path):  # noqa: ANN202 — dynamically-imported module
    """doc_radar's `lib` module imported off `root/scripts` (its stdlib-only
    package), or None when unavailable — so the canary drives the radar's own
    loaders + count batch rather than re-implementing them."""
    scripts = root / "scripts"
    added = str(scripts) not in sys.path
    if added:
        sys.path.insert(0, str(scripts))
    try:
        from observe.trust.doc_radar import lib
    except ImportError:
        return None
    finally:
        if added and str(scripts) in sys.path:
            sys.path.remove(str(scripts))
    return lib


def _collect_still_here(root: Path) -> list[CountQuery]:
    """Every `still_here` pin across all ADRs, via doc_radar's own loaders so
    the corpus is genuinely the radar's — falls back to an empty list when the
    radar package can't be imported (it is stdlib-only, so this is rare).
    """
    lib = _radar_lib(root)
    if lib is None:
        return []
    out: list[CountQuery] = []
    for adr in lib.load_adrs():
        for entry in adr.radar.get("still_here", []) or []:
            if not isinstance(entry, dict):
                continue
            pat, paths = entry.get("pattern"), entry.get("paths") or []
            if not pat or not isinstance(paths, list):
                continue
            out.append(
                CountQuery(
                    pattern=str(pat),
                    paths=tuple(str(p) for p in paths),
                    origin=f"ADR-{adr.num} still_here",
                )
            )
    return out


def collect_queries(root: Path) -> tuple[tuple[str, tuple[str, ...]], list[CountQuery]]:
    """The radar's real query corpus: the (marker pattern, globs) discovery
    query and every `still_here` count query.
    """
    return (MARKER_PATTERN, MARKER_GLOBS), _collect_still_here(root)


# ── ripgrep oracle (mirrors doc_radar.lib exactly) ───────────────────


def _rg() -> str:
    return shutil.which("rg") or "rg"


def _rg_count(root: Path, query: CountQuery) -> int:
    """`lib.ripgrep`: matching lines across the existing targets, -1 on error."""
    targets = [str(root / p) for p in query.paths if (root / p).exists()]
    if not targets:
        return 0
    proc = subprocess.run(  # noqa: S603 — fixed argv, trusted binary
        # `-e` mirrors lib.ripgrep's leading-dash-safe argv (ADR-352).
        [_rg(), "--count-matches", "--no-heading", "--no-filename", "-e", query.pattern, *targets],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    if proc.returncode not in (0, 1):
        return -1
    return sum(int(x) for x in proc.stdout.splitlines() if x.strip().isdigit())


def _rg_files(root: Path, pattern: str, globs: Sequence[str]) -> list[str]:
    """`lib.ripgrep_files`: repo-relative paths of files with a match."""
    cmd = [_rg(), "-l", "--hidden", "--no-messages", "-e", pattern]
    for g in globs:
        cmd += ["-g", g]
    cmd.append(str(root))
    proc = subprocess.run(  # noqa: S603 — fixed argv, trusted binary
        cmd, capture_output=True, text=True, timeout=30, check=False
    )
    if proc.returncode not in (0, 1):
        return []
    out: list[str] = []
    for ln in proc.stdout.splitlines():
        if not ln:
            continue
        try:
            out.append(str(Path(ln).resolve().relative_to(root)))
        except ValueError:
            continue
    return sorted(out)


# ── GIST side (dogfoods the importable package) ──────────────────────


def _gist_count(root: Path, query: CountQuery, *, warm: bool) -> int | None:
    """Matching lines via the GIST package; `None` when the pattern is outside
    GIST's engine (the live radar would fall back to `rg` for it).
    """
    existing = tuple(p for p in query.paths if (root / p).exists())
    if not existing:
        return 0
    try:
        return gist.count(query.pattern, paths=existing, no_index=not warm, cwd=root)
    except GistError:
        return None


def _gist_files(root: Path, pattern: str, globs: Sequence[str]) -> list[str] | None:
    try:
        return gist.files(pattern, globs=tuple(globs), hidden=True, cwd=root)
    except GistError:
        return None


# ── results ──────────────────────────────────────────────────────────


@dataclass(frozen=True, slots=True)
class QueryResult:
    """One query run through both engines."""

    kind: str  # "files" | "count"
    origin: str
    pattern: str
    rg: object
    gist: object

    @property
    def unsupported(self) -> bool:
        return self.gist is None

    @property
    def equal(self) -> bool:
        return self.gist is not None and self.rg == self.gist


@dataclass(slots=True)
class CanaryReport:
    """The evidence bundle: per-query equivalence + the warm/cold/rg timing."""

    results: list[QueryResult] = field(default_factory=list)
    timings_ms: dict[str, float] = field(default_factory=dict)
    gist_available: bool = False
    rg_available: bool = False

    @property
    def compared(self) -> list[QueryResult]:
        """Results GIST could actually answer (excludes unsupported patterns)."""
        return [r for r in self.results if not r.unsupported]

    @property
    def mismatches(self) -> list[QueryResult]:
        return [r for r in self.compared if not r.equal]

    @property
    def unsupported(self) -> list[QueryResult]:
        return [r for r in self.results if r.unsupported]

    @property
    def equivalent(self) -> bool:
        """Byte-equivalent wherever GIST can answer — the plan's correctness
        contract. Unsupported patterns are a known fallback, not a divergence.
        """
        return bool(self.compared) and not self.mismatches

    @property
    def warm_speedup(self) -> float | None:
        """`rg` batch time ÷ GIST-warm batch time (>1 means GIST warm wins)."""
        rg_ms, warm_ms = self.timings_ms.get("rg"), self.timings_ms.get("gist_warm")
        if not rg_ms or not warm_ms:
            return None
        return rg_ms / warm_ms

    def to_dict(self) -> dict[str, object]:
        return {
            "gist_available": self.gist_available,
            "rg_available": self.rg_available,
            "queries": len(self.results),
            "compared": len(self.compared),
            "mismatches": [
                {
                    "kind": r.kind,
                    "origin": r.origin,
                    "pattern": r.pattern,
                    "rg": r.rg,
                    "gist": r.gist,
                }
                for r in self.mismatches
            ],
            "unsupported": [{"origin": r.origin, "pattern": r.pattern} for r in self.unsupported],
            "equivalent": self.equivalent,
            "timings_ms": {k: round(v, 2) for k, v in self.timings_ms.items()},
            "warm_speedup": (
                round(self.warm_speedup, 2) if self.warm_speedup is not None else None
            ),
        }


# ── driver ───────────────────────────────────────────────────────────


def _time_batch(fn, queries: Iterable[CountQuery]) -> float:
    """Wall-clock ms to run `fn` over every query (the repeated-query path)."""
    start = time.perf_counter()
    for q in queries:
        fn(q)
    return (time.perf_counter() - start) * 1000.0


def _time_session_batch(root: Path, counts: list[CountQuery]) -> float | None:
    """Wall-clock ms for doc_radar's real warm-Session count batch — reported
    only when a `gist serve` daemon serves `root` (else None; the leg is
    omitted). Never gates the canary; it measures the resident path the live
    radar takes once the stop hook has warmed a daemon."""
    probe = gist.Session(cwd=str(root))
    up = probe.connect()
    probe.close()
    if not up:
        return None
    lib = _radar_lib(root)
    if lib is None:
        return None
    tasks = [(q.pattern, list(q.paths)) for q in counts]
    lib.reset_file_index_cache()  # fresh shared session for a clean measurement
    start = time.perf_counter()
    lib.count_matches_batch(tasks)
    elapsed = (time.perf_counter() - start) * 1000.0
    lib.reset_file_index_cache()  # close the session this leg opened
    return elapsed


def run_canary(root: Path | None = None, *, limit: int | None = None) -> CanaryReport:
    """Run the full canary: equivalence over the whole corpus, then time the
    count batch three ways (rg / GIST warm / GIST cold).
    """
    root = root or _find_root()
    report = CanaryReport(
        gist_available=_gist_available(),
        rg_available=shutil.which("rg") is not None,
    )
    if not (report.gist_available and report.rg_available):
        return report

    (marker_pat, marker_globs), counts = collect_queries(root)
    if limit is not None:
        counts = counts[:limit]

    # Equivalence — files-with-match (marker discovery).
    rg_files = _rg_files(root, marker_pat, marker_globs)
    gist_files = _gist_files(root, marker_pat, marker_globs)
    report.results.append(
        QueryResult("files", "marker discovery", marker_pat, rg_files, gist_files)
    )

    # Equivalence — every still_here count.
    for q in counts:
        report.results.append(
            QueryResult(
                "count",
                q.origin,
                q.pattern,
                _rg_count(root, q),
                _gist_count(root, q, warm=True),
            )
        )

    # Warm-path measurement over the count batch (the multi-query workload).
    if counts:
        report.timings_ms["rg"] = _time_batch(lambda q: _rg_count(root, q), counts)
        report.timings_ms["gist_warm"] = _time_batch(
            lambda q: _gist_count(root, q, warm=True), counts
        )
        report.timings_ms["gist_cold"] = _time_batch(
            lambda q: _gist_count(root, q, warm=False), counts
        )
        session_ms = _time_session_batch(root, counts)
        if session_ms is not None:
            report.timings_ms["gist_session"] = session_ms
    return report


def _gist_available() -> bool:
    if shutil.which("gist") is not None:
        return True
    try:
        gist.binary()
    except gist.GistNotFoundError:
        return False
    return True


def _render(report: CanaryReport) -> str:
    if not report.gist_available:
        return "gist binary not found — build it with `make install-gist`."
    if not report.rg_available:
        return "rg not found — install ripgrep to run the equivalence oracle."
    lines = [
        "doc_radar x GIST canary (ADR-352)",
        f"  queries        : {len(report.results)} "
        f"({len(report.compared)} comparable, {len(report.unsupported)} unsupported)",
        f"  equivalent     : {report.equivalent}",
    ]
    if report.mismatches:
        lines.append(f"  MISMATCHES     : {len(report.mismatches)}")
        lines.extend(
            f"    [{r.kind}] {r.origin}: rg={r.rg!r} gist={r.gist!r}" for r in report.mismatches[:5]
        )
    if report.unsupported:
        lines.append(f"  unsupported    : {len(report.unsupported)} (radar falls back to rg)")
    t = report.timings_ms
    if t:
        lines.append(
            f"  batch (ms)     : rg={t.get('rg', 0):.1f} "
            f"gist_warm={t.get('gist_warm', 0):.1f} gist_cold={t.get('gist_cold', 0):.1f}"
        )
        if report.warm_speedup is not None:
            verdict = "GIST warm wins" if report.warm_speedup > 1 else "rg wins"
            lines.append(f"  warm speedup   : {report.warm_speedup:.2f}x ({verdict})")
        if "gist_session" in t:
            lines.append(
                f"  session (ms)   : gist_session={t['gist_session']:.1f} "
                "(resident daemon, report-only)"
            )
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="doc_radar x GIST canary (ADR-352).")
    parser.add_argument("--root", type=Path, default=None, help="repo root (auto-detected)")
    parser.add_argument("--limit", type=int, default=None, help="cap still_here queries")
    parser.add_argument("--json", action="store_true", help="emit the evidence as JSON")
    args = parser.parse_args(argv)

    report = run_canary(args.root, limit=args.limit)
    print(json.dumps(report.to_dict(), indent=2) if args.json else _render(report))
    # Fail loud only on a real divergence; absence of gist/rg is a skip, not a fail.
    if report.gist_available and report.rg_available and report.mismatches:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
