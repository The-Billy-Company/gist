#!/usr/bin/env python3
"""Measurement lanes for the gist evaluation matrix — the OPERATIONAL ENVELOPE.

Cold/warm query dominance and rg drop-in correctness are the Certificate of
Optimality's job (bench/certify/ + session/ + rgsuite/); this module deliberately
does NOT re-time them. It measures only what the certificate does not: index
lifecycle cost, resource footprint, scaling shape, and concurrent-load behavior.

Each lane returns plain-dict rows the orchestrator (`evaluate.py`) folds into a
bundle. Every lane reuses the ONE source of truth for how a tool is invoked —
`bench/races/_compete.sh` — via a thin bash bridge, so the evaluator can never
drift from the certified race commands. Timing is `hyperfine --export-json`
(same runner the certificate uses); statistics come from `certify_stats` so the
whole evidence stack tells one statistical story.

Lanes, mapped to the regimes in `contract/performance_evidence.toml`:
  * ``parity``       byte-exact gist ≡ rg on BOTH engines — a build-sanity
                     PRECONDITION for the timed lanes, not a published claim.
  * ``lifecycle``    full build, first-query, incremental add/edit/delete/rename.
  * ``resource``     peak RSS, index/corpus size ratio, scan throughput.
  * ``scale``        latency + build across corpus size and shape.
  * ``concurrency``  aggregate qps + tail latency against the resident daemon.

A cell that cannot be measured is recorded ``status="unsupported"`` /
``"failed"`` — never fabricated, never dropped from the denominator.
"""

# ruff: noqa: S603, S607 — a benchmark orchestrator: it MUST spawn the tools under
# test (gist/rg/hyperfine/git//usr/bin/time) with computed argv, resolving them on
# PATH; inputs are the fixed probe registry + installed rivals, never user text.

from __future__ import annotations

import concurrent.futures as futures
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[1]
REPO = KERNEL.parents[2]
COMPETE = KERNEL / "bench" / "races" / "_compete.sh"
CERTIFY = KERNEL / "bench" / "certify" / "certify_stats.py"


def _corpus_root() -> Path:
    """The tree lanes actually search — an immutable snapshot when the evaluator
    froze one (GIST_CORPUS_ROOT), else the live repo. Mirrors `_compete.sh`'s
    ``CORPUS`` so the Python-side cwd and the shell-side roots always agree."""
    root = os.environ.get("GIST_CORPUS_ROOT", "").strip()
    return Path(root) if root else REPO


def _load_certify_stats():
    """Import certify_stats by path (its dir is not a package)."""
    spec = importlib.util.spec_from_file_location("certify_stats", CERTIFY)
    if spec is None or spec.loader is None:
        msg = f"cannot load certify_stats from {CERTIFY}"
        raise ImportError(msg)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STATS = _load_certify_stats()

# The 12-class probe registry, byte-identical to certify.sh / ratio_regress.
PROBES: tuple[tuple[str, str, str], ...] = (
    ("literal-rare", "literal", "pgxpool"),
    ("literal-dotted", "literal", "context.Context"),
    ("literal-common", "literal", "func"),
    ("literal-punct2", "literal", "})"),
    ("regex-decl", "regex", r"func\s+\w+\("),
    ("regex-dotted", "regex", r"pgxpool\.\w+"),
    ("regex-anchored", "regex", r"^func\s"),
    ("regex-classcount", "regex", r"[0-9a-f]{8}-[0-9a-f]{4}"),
    ("regex-alternation", "regex", r"return|continue|break"),
    ("regex-dense-scan", "regex", r"\w{3,8}"),
    ("regex-eol", "regex", r";$"),
    ("regex-litalt", "regex", r"panic|0x"),
)


class Bridge:
    """Build gist and resolve gist/rg commands from `_compete.sh`.

    One bash subshell sources `_compete.sh` and echoes the exact command for a
    (tool, kind, pattern) — the same string the certificate times — so the
    parity precondition inherits fairness scoping (roots, ignore set, per-tool
    path) verbatim instead of re-encoding it. The operational lanes only need
    gist (the subject) and rg (the parity oracle); csearch/zoekt field context
    is the certificate's, not re-run here.
    """

    def __init__(self, gist_dir: Path | None = None):
        self.env = dict(os.environ)
        # The command STRINGS from `_compete.sh` assume the env `_compete.sh` exports
        # when sourced — above all `GIST_UNCAP=1` (its line 49): gist's default output
        # budget clips a repo-wide `-l`/`-c` result, which would make the parity oracle
        # mismatch rg and perturb every timed cell. We run those strings via `bash -c`
        # without re-sourcing, so we must carry that contract here. `GIST_HINTS=0` keeps
        # the coaching channel off stdout for byte-clean captures.
        self.env["GIST_UNCAP"] = "1"
        self.env["GIST_HINTS"] = "0"
        if gist_dir:
            self.env["GIST_DIR"] = str(gist_dir)
        self.gist_bin = REPO / ".local" / "gist-bin"

    def _source(self, snippet: str) -> subprocess.CompletedProcess:
        script = f'set -euo pipefail\nsource "{COMPETE}"\n{snippet}\n'
        return subprocess.run(
            ["bash", "-c", script],
            check=False,
            capture_output=True,
            text=True,
            cwd=str(KERNEL),
            env=self.env,
        )

    def build_gist(self) -> bool:
        """Build gist ReleaseFast, install the deterministic bin, persist the index."""
        proc = self._source("compete_build_gist_index")
        return proc.returncode == 0

    def command(self, tool: str, kind: str, pattern: str) -> str:
        """The exact timed command for a (tool, kind, pattern), or '' if inexpressible."""
        helper = "compete_lit_cmd" if kind == "literal" else "compete_rgx_cmd"
        # Patterns in the slate carry no single quotes.
        proc = self._source(f"{helper} {tool} '{pattern}'")
        cmd = proc.stdout.strip()
        return "" if cmd in ("", "false") else cmd


def _hyperfine(cmd: str, *, warmup: int, runs: int, prepare: str | None, env: dict) -> list[float]:
    """Timed samples (ms) via hyperfine --export-json, or [] on failure."""
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as handle:
        out = Path(handle.name)
    try:
        argv = ["hyperfine", "--style", "none", "--warmup", str(warmup), "--runs", str(runs)]
        if prepare:
            argv += ["--prepare", prepare]
        argv += ["--output", "pipe", "--ignore-failure", "--export-json", str(out), cmd]
        proc = subprocess.run(
            argv, check=False, capture_output=True, text=True, cwd=str(_corpus_root()), env=env
        )
        if proc.returncode != 0 or not out.is_file():
            return []
        doc = json.loads(out.read_text())
        results = doc.get("results") or []
        if len(results) != 1:
            return []
        return [t * 1000.0 for t in (results[0].get("times") or [])]
    finally:
        out.unlink(missing_ok=True)


def _sorted_lines(raw: bytes) -> bytes:
    return b"\n".join(sorted(raw.split(b"\n")))


def _run_capture(cmd: str, env: dict) -> tuple[int, bytes]:
    proc = subprocess.run(
        ["bash", "-c", cmd], check=False, capture_output=True, cwd=str(_corpus_root()), env=env
    )
    return proc.returncode, proc.stdout


# ── parity ────────────────────────────────────────────────────────────────────
def parity_lane(bridge: Bridge, corpus: str = "billy") -> list[dict]:
    """gist ≡ rg byte-exact (order-insensitive) on BOTH engines, per class.

    The single-engine trap is real (a serial-only regression has slipped before —
    see rgsuite "Two engines, one suite"), so parity is asserted on the parallel
    AND the serial (`GIST_NO_PARALLEL`) path before any cell of this corpus is
    allowed to be timed.
    """
    rows: list[dict] = []
    for cls, kind, pattern in PROBES:
        rg_cmd = bridge.command("rg", kind, pattern)
        gist_cmd = bridge.command("gist", kind, pattern)
        if not rg_cmd or not gist_cmd:
            rows.append({"class": cls, "status": "unsupported", "note": "no rg/gist command"})
            continue
        rc_rg, out_rg = _run_capture(rg_cmd, bridge.env)
        oracle = _sorted_lines(out_rg)
        row = {"class": cls, "kind": kind, "status": "ok", "engines": {}}
        for engine, extra in (("parallel", {}), ("serial", {"GIST_NO_PARALLEL": "1"})):
            env = bridge.env | extra
            rc_g, out_g = _run_capture(gist_cmd, env)
            match = rc_g == rc_rg and _sorted_lines(out_g) == oracle
            row["engines"][engine] = match
            if not match:
                row["status"] = "failed"
                row["note"] = f"{engine} engine != rg oracle (rc {rc_g} vs {rc_rg})"
        rows.append(row)
    return rows


# ── lifecycle ───────────────────────────────────────────────────────────────
def lifecycle_lane(bridge: Bridge, gist_dir: Path) -> dict:
    """Full build, first-query, and incremental add/edit/delete/rename latency."""
    gist = str(bridge.gist_bin)
    env = bridge.env
    roots = ["services", "libs", "clients", "contracts", "scripts", "quality"]

    def _timed(argv: list[str], cwd: Path | None = None) -> float | None:
        cwd = cwd or _corpus_root()
        start = time.monotonic()
        proc = subprocess.run(argv, check=False, capture_output=True, cwd=str(cwd), env=env)
        return (time.monotonic() - start) * 1000.0 if proc.returncode in (0, 1) else None

    shutil.rmtree(gist_dir, ignore_errors=True)
    gist_dir.mkdir(parents=True, exist_ok=True)
    build_ms = _timed([gist, "index", *roots])
    first_query_ms = _timed([gist, "pgxpool", "-l", "--", *roots])

    incremental: list[dict] = []
    scratch = REPO / ".local" / "gist-evaluation" / "scratch"
    scratch.mkdir(parents=True, exist_ok=True)
    probe = scratch / "EVAL_PROBE.txt"
    events = {
        "add": lambda: probe.write_text("EVAL_INCREMENTAL_NEEDLE\n"),
        "edit": lambda: probe.write_text("EVAL_INCREMENTAL_NEEDLE edited\n"),
        "rename": lambda: probe.rename(scratch / "EVAL_PROBE_RENAMED.txt"),
        "delete": lambda: (scratch / "EVAL_PROBE_RENAMED.txt").unlink(missing_ok=True),
    }
    for name, mutate in events.items():
        mutate()
        incremental.append({"event": name, "refresh_ms": _timed([gist, "index", "--auto", *roots])})
    shutil.rmtree(scratch, ignore_errors=True)
    return {
        "build_ms": round(build_ms, 2) if build_ms is not None else None,
        "first_query_ms": round(first_query_ms, 2) if first_query_ms is not None else None,
        "incremental": incremental,
    }


# ── resource ──────────────────────────────────────────────────────────────────
def _peak_rss_kb(argv: list[str], env: dict) -> int | None:
    """Peak RSS (KiB) for a command via platform /usr/bin/time, or None."""
    time_bin = "/usr/bin/time"
    if not Path(time_bin).exists():
        return None
    linux = sys.platform.startswith("linux")
    flag = "-v" if linux else "-l"
    proc = subprocess.run(
        [time_bin, flag, *argv],
        check=False,
        capture_output=True,
        text=True,
        cwd=str(_corpus_root()),
        env=env,
    )
    text = proc.stderr
    for line in text.splitlines():
        low = line.lower()
        if linux and "maximum resident set size" in low:
            return int("".join(c for c in line if c.isdigit()) or 0)  # KiB on GNU time
        if not linux and "maximum resident set size" in low:
            return int("".join(c for c in line.split()[0] if c.isdigit()) or 0) // 1024  # bytes→KiB
    return None


def resource_lane(bridge: Bridge, gist_dir: Path, corpus_bytes: int) -> dict:
    """Index/corpus size ratio, peak RSS, and scan throughput (hardware ratios)."""
    gist = str(bridge.gist_bin)
    parts = {
        "posting": gist_dir / "index.gist",
        "path": gist_dir / "paths.list",
        "freshness": gist_dir / "built.ns",
    }
    index_bytes = sum(p.stat().st_size for p in parts.values() if p.exists())
    ratio = round(index_bytes / corpus_bytes, 4) if corpus_bytes else None
    roots = ["services", "libs", "clients", "contracts", "scripts", "quality"]
    peak_rss = _peak_rss_kb([gist, r"\w{3,8}", "-c", "--", *roots], bridge.env)

    # Throughput: no-index full scan over the corpus, bytes / wall seconds.
    start = time.monotonic()
    scan = subprocess.run(
        [gist, "--no-index", r"\w{3,8}", "-c", "--", *roots],
        check=False,
        capture_output=True,
        cwd=str(_corpus_root()),
        env=bridge.env,
    )
    scan_s = time.monotonic() - start
    throughput = (
        round((corpus_bytes / (1 << 20)) / scan_s, 1)
        if scan_s > 0 and scan.returncode in (0, 1)
        else None
    )
    return {
        "index_bytes": index_bytes,
        "corpus_bytes": corpus_bytes,
        "index_over_corpus": ratio,
        "peak_rss_kb": peak_rss,
        "scan_throughput_mb_s": throughput,
    }


# ── scale ─────────────────────────────────────────────────────────────────────
def scale_lane(bridge: Bridge, corpora_dir: Path, *, warmup: int, runs: int) -> list[dict]:
    """Cold p50 + build time across the installed foreign corpora (size x shape).

    Each foreign tree is a scale/shape point; the SHAPE of latency-vs-bytes is the
    portable claim (absolute ms stays machine-local). Corpora are opt-in — only
    those materialized by `bench/corpora/fetch.sh` contribute a point.
    """
    points: list[dict] = []
    if not corpora_dir.is_dir():
        return points
    gist = str(bridge.gist_bin)
    for tree in sorted(p for p in corpora_dir.iterdir() if (p / ".corpus-ready").exists()):
        total_bytes = sum(f.stat().st_size for f in tree.rglob("*") if f.is_file())
        file_count = sum(1 for f in tree.rglob("*") if f.is_file())
        env = bridge.env | {"GIST_ROOTS": str(tree)}
        start = time.monotonic()
        build = subprocess.run(
            [gist, "index", str(tree)], check=False, capture_output=True, env=env
        )
        build_ms = (time.monotonic() - start) * 1000.0 if build.returncode in (0, 1) else None
        samples = _hyperfine(
            f"{gist} 'func' -l -- {tree}", warmup=warmup, runs=runs, prepare=None, env=env
        )
        p50 = round(STATS.quantile(sorted(samples), 0.50), 4) if samples else None
        points.append(
            {
                "corpus": tree.name,
                "file_count": file_count,
                "total_bytes": total_bytes,
                "build_ms": round(build_ms, 2) if build_ms is not None else None,
                "cold_p50_ms": p50,
            }
        )
    return points


# ── concurrency ─────────────────────────────────────────────────────────────
def concurrency_lane(
    bridge: Bridge, *, workers_scan: tuple[int, ...] = (1, 4, 8, 16), per_worker: int = 20
) -> list[dict]:
    """Aggregate qps + tail latency against the resident daemon at bounded workers.

    Proves the warm path holds under the many-agent load gist is built for. The
    caller must arm the daemon first; each worker replays selective needles whose
    cold command auto-dials it.
    """
    gist = str(bridge.gist_bin)
    roots = ["services", "libs", "clients", "contracts", "scripts", "quality"]
    needles = ["pgxpool", "context.Context", "func", "panic", "return"]
    points: list[dict] = []

    def _one(needle: str) -> float:
        start = time.monotonic()
        subprocess.run(
            [gist, needle, "-l", "--", *roots],
            check=False,
            capture_output=True,
            cwd=str(_corpus_root()),
            env=bridge.env,
        )
        return (time.monotonic() - start) * 1000.0

    for workers in workers_scan:
        jobs = [needles[i % len(needles)] for i in range(workers * per_worker)]
        start = time.monotonic()
        with futures.ThreadPoolExecutor(max_workers=workers) as pool:
            latencies = sorted(pool.map(_one, jobs))
        wall = time.monotonic() - start
        points.append(
            {
                "workers": workers,
                "queries": len(jobs),
                "qps": round(len(jobs) / wall, 1) if wall > 0 else None,
                "p50_ms": round(STATS.quantile(latencies, 0.50), 3),
                "p95_ms": round(STATS.quantile(latencies, 0.95), 3),
                "p99_ms": round(STATS.quantile(latencies, 0.99), 3),
            }
        )
    return points
