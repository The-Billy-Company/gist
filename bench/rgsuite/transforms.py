#!/usr/bin/env python3
"""gist ⇄ ripgrep differential proof for the content-transform flags rgsuite can't mine.

`run.py` replays ripgrep's own mined suite over the repo's *plain* source bytes,
so it exercises none of the flags that reshape a file's content before matching:
`-z`/`--search-zip` (decompress), `--pre`/`--pre-glob` (preprocess), `-E`/
`--encoding` (transcode), and `--binary`/`-uuu` (search NUL-bearing files). Those
need special fixtures — compressed blobs, UTF-16 / Latin-1 text, a NUL-embedded
file, a preprocessor script — a plain source tree cannot supply. This is the
hand-authored companion that certifies exactly those flags, with ripgrep as the
ground truth (no hardcoded expected strings):

  * `-z` is proven **byte-for-byte** (`-n --no-heading`) per container format —
    gzip / bzip2 / xz always (Python stdlib mints the fixtures), plus zstd / lz4 /
    brotli when the system tool is installed to write them. gist decodes gzip and
    xz IN-PROCESS; rg forks a decompressor; the *output* must be identical.
  * `-E` transcoding is byte-exact on UTF-16 (LE/BE/BOM), Latin-1, and the CJK /
    legacy code pages (Shift_JIS, EUC-JP, GBK, Big5, EUC-KR) vs rg's encoding_rs.
  * `--pre` matches rg exactly for BOTH invocation styles: a `gzip -dc "$1"`
    wrapper (reads the path argv) and an `exec cat` preprocessor (reads only the
    file's bytes on stdin — proving gist feeds stdin like rg, not just the path),
    plus `--pre-glob` scoping.
  * `--binary`/`-uuu` are gist's deliberate **superset** of rg's one-line summary:
    they search a NUL-bearing file in full, so `rg -a` (ripgrep --text, "search it
    all as text") is the correct oracle for gist's `--binary` stdout — pinned
    byte-for-byte. Default (flag-free) binary detection is separately pinned equal
    to plain rg (both emit the summary).
  * every case also asserts the indexed path equals `--no-index` (a transform
    disables read-elision, so they must agree), and the whole slate runs once per
    **engine** — the parallel work-stealing walk and the serial fallback
    (`GIST_NO_PARALLEL=1`) — proving the pipeline's decline-to-serial for any
    transform is result-neutral.

stdlib-only. Fixtures are generated into a temp dir each run (the generator here
is the committed contract), so nothing binary or machine-specific is tracked.

Subcommands:
  run   [--engine both|parallel|serial]        differential parity vs rg
  bench [--floor-rg N] [--floor-parallel N]    -z pipeline-vs-serial-vs-rg speed
"""

from __future__ import annotations

import argparse
import atexit
import bz2
from collections.abc import Callable
from dataclasses import dataclass, field
import gzip
import lzma
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[1]  # bench/rgsuite -> pkg/kernels/irregex
REPO = HERE.parents[4]  # -> repo root
FIX = Path()  # temp fixture root, set in main()

RG = os.environ.get("RG_BIN", "rg")
GIST = ""  # resolved in main()

# gist caps its own output by default (agent-context guard); rg has no such cap,
# so lift the soft ceiling for byte-exact parity (children inherit os.environ).
# The hard OOM ceiling stays on.
os.environ.setdefault("GIST_UNCAP", "1")

# The line body every text fixture carries: two matching lines around filler, so
# a comparator that mis-counts lines (or drops the tail after a NUL) diverges.
BODY = "the needle is here\nplain filler line\nanother needle appears\n"

# -E CJK / legacy fixtures: filename -> (python mint codec, content). Content pairs
# an ASCII "needle" (stable across encodings) with encoding-appropriate multi-byte
# text — two needle lines, matching BODY's shape. The `-E` label the run passes to
# BOTH gist and rg is derived from the stem (sjis→shift_jis, …) in `_cases`.
_CJK_FIXTURES: dict[str, tuple[str, str]] = {
    "sjis.txt": ("shift_jis", "needle 日本語\nplain filler\nanother needle 東京\n"),
    "eucjp.txt": ("euc_jp", "needle 日本語\nplain filler\nanother needle 東京\n"),
    "gbk.txt": ("gbk", "needle 中文内容\nplain filler\nanother needle 北京\n"),
    "big5.txt": ("big5", "needle 中文內容\nplain filler\nanother needle 台北\n"),
    "euckr.txt": ("cp949", "needle 한국어\nplain filler\nanother needle 서울\n"),
}
# fixture stem -> the `-E` label handed to gist AND rg (encoding_rs canonical).
_CJK_LABELS = {
    "sjis": "shift_jis",
    "eucjp": "euc-jp",
    "gbk": "gbk",
    "big5": "big5",
    "euckr": "euc-kr",
}

# `-z` container formats. The stdlib trio is always minted; the rest are written
# only when their system encoder exists (rg and gist both read all six).
_STDLIB_CODECS: dict[str, Callable[[bytes], bytes]] = {
    "gz": lambda b: gzip.compress(b, mtime=0),
    "bz2": bz2.compress,
    "xz": lambda b: lzma.compress(b, format=lzma.FORMAT_XZ),
}
# ext -> argv writing stdin→<path> (the tool must exist on PATH to be exercised).
_TOOL_CODECS = {
    "zst": ["zstd", "-q"],
    "lz4": ["lz4", "-q"],
    "br": ["brotli"],
}


def _find_gist() -> str:
    """Resolve the gist ReleaseFast binary — `GIST_BIN` override, else build it."""
    if env := os.environ.get("GIST_BIN"):
        return env
    out = KERNEL / "zig-out" / "bin" / "gist"
    subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseFast"],
        cwd=KERNEL,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    if out.exists():
        return str(out)
    cands = sorted(
        KERNEL.glob(".zig-cache/o/*/gist"), key=lambda p: p.stat().st_mtime, reverse=True
    )
    if not cands:
        sys.exit("no gist binary found after `zig build`")
    return str(cands[0])


# ───────────────────────── process runner ─────────────────────────


@dataclass
class Out:
    """One command run: exit code and captured stdout bytes."""

    rc: int
    data: bytes


def run(bin_: str, args: list[str], cwd: Path, env: dict[str, str] | None = None) -> Out:
    """Run `bin_ args` in `cwd` (stderr suppressed), capturing stdout + rc."""
    p = subprocess.run(
        [bin_, *args],
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=90,
    )
    return Out(p.returncode, p.stdout)


# ───────────────────────── fixtures ─────────────────────────


def _avail_codecs() -> dict[str, Callable[[bytes], bytes] | list[str]]:
    """The container formats writable on this host: stdlib trio + any present tools."""
    codecs: dict[str, Callable[[bytes], bytes] | list[str]] = dict(_STDLIB_CODECS)
    for ext, argv in _TOOL_CODECS.items():
        if shutil.which(argv[0]):
            codecs[ext] = argv
    return codecs


def gen_fixtures(root: Path) -> list[str]:
    """Build the zip/, enc/, bin/, pre/ fixtures; return the `-z` extensions minted.

    This generator is the committed contract — nothing binary is tracked. Every
    text fixture shares BODY so one needle pattern drives every comparison.
    """
    root.mkdir(parents=True, exist_ok=True)
    raw = BODY.encode()

    # ── -z: one container per available codec (plus a plain sibling for --pre-glob) ──
    zip_dir = root / "zip"
    zip_dir.mkdir()
    (zip_dir / "plain.txt").write_bytes(raw)
    exts: list[str] = []
    for ext, codec in _avail_codecs().items():
        dst = zip_dir / f"doc.txt.{ext}"
        if isinstance(codec, list):  # external tool: stdin → stdout → file
            blob = subprocess.run(
                [*codec, "-c"], input=raw, stdout=subprocess.PIPE, check=True
            ).stdout
            dst.write_bytes(blob)
        else:
            dst.write_bytes(codec(raw))
        exts.append(ext)

    # ── -E: UTF-16 (LE/BE/with-BOM) + Latin-1, the accented byte forcing a transcode ──
    enc = root / "enc"
    enc.mkdir()
    accented = "café needle\nplain line\n"
    (enc / "u16le.txt").write_bytes(BODY.encode("utf-16-le"))
    (enc / "u16be.txt").write_bytes(BODY.encode("utf-16-be"))
    (enc / "u16bom.txt").write_bytes(BODY.encode("utf-16"))  # BOM-prefixed
    (enc / "latin1.txt").write_bytes(accented.encode("latin-1"))

    # ── -E: the CJK / legacy code pages (the gap this suite closes). Each fixture
    # carries an ASCII "needle" (encoding-invariant, so the match is stable) beside
    # real multi-byte content, forcing gist's decoder onto the lead-byte path. rg
    # (encoding_rs) is the oracle; the Python codec is only the fixture minter, so a
    # Python↔encoding_rs nuance can't break parity as long as gist tracks rg. euc-kr
    # mints via CP949/UHC — WHATWG "euc-kr" is UHC, which Python spells `cp949`.
    for fname, (pycodec, text) in _CJK_FIXTURES.items():
        (enc / fname).write_bytes(text.encode(pycodec))

    # ── binary: a NUL splits two matching lines; both must survive --binary/-a ──
    bind = root / "bin"
    bind.mkdir()
    (bind / "blob.dat").write_bytes(b"text needle before\x00binary needle after\nmore needle\n")

    # ── --pre: the canonical `exec gzip -dc "$1"` wrapper rg's docs lead with, plus
    # a stdin-ONLY preprocessor (`exec cat`, no argv use) that proves gist feeds the
    # file's bytes on the child's stdin exactly as rg does — the adverse case that
    # fails the moment stdin is closed (the pre-fix behavior) ──
    pre = root / "pre"
    pre.mkdir()
    (pre / "doc.txt.gz").write_bytes(gzip.compress(raw, mtime=0))
    (pre / "plain.txt").write_bytes(raw)
    script = pre / "decompress.sh"
    script.write_text('#!/bin/sh\nexec gzip -dc "$1"\n')
    script.chmod(0o755)
    stdin_only = pre / "stdin_only.sh"
    stdin_only.write_text("#!/bin/sh\nexec cat\n")  # ignores argv, reads stdin
    stdin_only.chmod(0o755)

    return exts


# ───────────────────────── case matrix ─────────────────────────


@dataclass
class Case:
    """One differential case: gist argv, the rg oracle argv, cwd + comparison knobs."""

    name: str
    gist_args: list[str]
    rg_args: list[str]
    cwd: Path
    sort_lines: bool = False  # True ⇒ set-equality (walk order not pinned)
    index_safe: bool = True  # also assert indexed stdout == --no-index


def _cases(exts: list[str]) -> list[Case]:
    """The curated content-transform cases (ripgrep is the oracle for every one)."""
    cs: list[Case] = []
    n = ["-n", "--no-heading", "needle"]

    # ── -z: byte-exact per format, gist -z ≡ rg -z on one explicit file ──
    for ext in exts:
        f = f"zip/doc.txt.{ext}"
        cs.append(Case(f"zip:{ext}", ["-z", *n, f], ["-z", *n, f], FIX))
    # -z over a directory walk (set-equality; both must decode every member)
    cs.append(
        Case(
            "zip:walk",
            ["-z", "-l", "needle", "zip"],
            ["-z", "-l", "needle", "zip"],
            FIX,
            sort_lines=True,
        )
    )

    # ── -E: rg is the oracle for every transcode ──
    cs += [
        Case(
            "enc:u16le",
            ["-E", "utf-16le", *n, "enc/u16le.txt"],
            ["-E", "utf-16le", *n, "enc/u16le.txt"],
            FIX,
        ),
        Case(
            "enc:u16be",
            ["-E", "utf-16be", *n, "enc/u16be.txt"],
            ["-E", "utf-16be", *n, "enc/u16be.txt"],
            FIX,
        ),
        Case("enc:u16-auto-bom", [*n, "enc/u16bom.txt"], [*n, "enc/u16bom.txt"], FIX),
        # latin1 folds to windows-1252 in both gist and rg (WHATWG); 0xE9 (é) is
        # identical in both pages, so the accented case still pins byte-exact.
        Case(
            "enc:latin1",
            ["-E", "latin1", *n, "enc/latin1.txt"],
            ["-E", "latin1", *n, "enc/latin1.txt"],
            FIX,
        ),
        Case(
            "enc:latin1-accent",
            ["-E", "latin1", "-n", "--no-heading", "caf", "enc/latin1.txt"],
            ["-E", "latin1", "-n", "--no-heading", "caf", "enc/latin1.txt"],
            FIX,
        ),
    ]

    # ── -E: CJK / legacy code pages — gist ≡ rg (encoding_rs) on the ASCII needle
    # AND the transcoded multi-byte lines around it (byte-exact, both `-n`). ──
    for stem, label in _CJK_LABELS.items():
        f = f"enc/{stem}.txt"
        cs.append(Case(f"enc:{stem}", ["-E", label, *n, f], ["-E", label, *n, f], FIX))

    # ── --pre / --pre-glob: gist ≡ rg over the wrapper's stdout ──
    pre_sh = "pre/decompress.sh"
    cs += [
        Case(
            "pre:basic",
            ["--pre", pre_sh, *n, "pre/doc.txt.gz"],
            ["--pre", pre_sh, *n, "pre/doc.txt.gz"],
            FIX,
        ),
        Case(
            "pre:glob-scoped",
            ["--pre", pre_sh, "--pre-glob", "*.gz", "-l", "needle", "pre"],
            ["--pre", pre_sh, "--pre-glob", "*.gz", "-l", "needle", "pre"],
            FIX,
            sort_lines=True,
        ),
        # stdin-only preprocessor: `exec cat` never touches argv, so it emits the
        # file's bytes ONLY if gist (like rg) wires them to the child's stdin. Fails
        # loud if stdin is ever closed again.
        Case(
            "pre:stdin-only",
            ["--pre", "pre/stdin_only.sh", *n, "pre/plain.txt"],
            ["--pre", "pre/stdin_only.sh", *n, "pre/plain.txt"],
            FIX,
        ),
    ]

    # ── --binary / -uuu: gist's superset ≡ `rg -a` (search the NUL file as text) ──
    cs += [
        Case(
            "bin:--binary",
            ["--binary", *n, "bin/blob.dat"],
            ["-a", *n, "bin/blob.dat"],
            FIX,
            index_safe=False,
        ),
        Case(
            "bin:-uuu",
            ["-uuu", *n, "bin/blob.dat"],
            ["-a", *n, "bin/blob.dat"],
            FIX,
            index_safe=False,
        ),
        # flag-free: gist's default binary detection matches rg's (both summarize)
        Case(
            "bin:default-detect", [*n, "bin/blob.dat"], [*n, "bin/blob.dat"], FIX, index_safe=False
        ),
    ]
    return cs


# ───────────────────────── differential run ─────────────────────────


def _norm(data: bytes, sort_lines: bool) -> bytes:
    """Canonicalize stdout: line-sorted set (order-agnostic) or raw bytes."""
    return b"\n".join(sorted(data.split(b"\n"))) if sort_lines else data


def _engine_env(serial: bool) -> dict[str, str]:
    e = {**os.environ}
    if serial:
        e["GIST_NO_PARALLEL"] = "1"
    else:
        e.pop("GIST_NO_PARALLEL", None)
    return e


def _diff_engine(cases: list[Case], *, serial: bool) -> tuple[list[str], list[str]]:
    """Replay every case on one engine; return (parity fails, index-safety fails)."""
    fails: list[str] = []
    idx_fails: list[str] = []
    env = _engine_env(serial)
    for c in cases:
        g = run(GIST, [*c.gist_args, "--no-index"], c.cwd, env)
        r = run(RG, c.rg_args, c.cwd, {**os.environ})
        gn, rn = _norm(g.data, c.sort_lines), _norm(r.data, c.sort_lines)
        if g.rc != r.rc:
            fails.append(f"{c.name}: EXIT gist={g.rc} rg={r.rc}  gist={c.gist_args} rg={c.rg_args}")
        if gn != rn:
            fails.append(
                f"{c.name}: STDOUT diverges  gist={c.gist_args} rg={c.rg_args}\n"
                + _mini_diff(gn, rn)
            )
        if c.index_safe:
            gi = run(GIST, c.gist_args, c.cwd, env)
            if _norm(gi.data, c.sort_lines) != gn:
                idx_fails.append(f"{c.name}: indexed != --no-index  gist={c.gist_args}")
    return fails, idx_fails


def do_run(engine: str) -> int:
    """Run the differential slate on the requested engine(s); 1 on any failure."""
    exts = gen_fixtures(FIX)
    cases = _cases(exts)
    engines = (
        [("parallel", False), ("serial", True)]
        if engine == "both"
        else [(engine, engine == "serial")]
    )
    total = 0
    for label, serial in engines:
        fails, idx_fails = _diff_engine(cases, serial=serial)
        print(
            f"\n=== transforms differential [{label}]: {len(cases)} cases "
            f"(-z formats: {' '.join(exts)}) ==="
        )
        if not fails and not idx_fails:
            print("✓ ALL PASS — gist == rg (stdout + exit) and indexed == --no-index")
        else:
            for f in fails:
                print("✗ " + f)
            for f in idx_fails:
                print("⚠ INDEX " + f)
            print(f"{len(fails)} parity fail(s), {len(idx_fails)} index-safety fail(s)")
        total += len(fails) + len(idx_fails)
    return 1 if total else 0


def _mini_diff(a: bytes, b: bytes, ctx: int = 2) -> str:
    """Render the first stdout divergence between gist and rg with a little context."""
    al, bl = a.split(b"\n"), b.split(b"\n")
    i = next(
        (
            k
            for k in range(max(len(al), len(bl)))
            if (al[k] if k < len(al) else None) != (bl[k] if k < len(bl) else None)
        ),
        None,
    )
    if i is None:
        return f"  (equal after normalization; len gist={len(al)} rg={len(bl)})"
    dec = lambda xs, k: xs[k].decode("utf-8", "replace") if k < len(xs) else "<EOF>"
    lines = [f"  first diff at line {i} (gist={len(al)} rg={len(bl)}):"]
    for k in range(max(0, i - ctx), i + ctx + 1):
        mark = ">>" if k == i else "  "
        lines.append(f"  {mark} g| {dec(al, k)}")
        lines.append(f"  {mark} r| {dec(bl, k)}")
    return "\n".join(lines)


# ───────────────────────── bench (in-process-decompress speed edge) ─────────────────────────

# Many subdirs, because the pipeline's work-stealing is DIRECTORY-granular: a flat
# (or few-dir) tree routes most files to one worker, so parallelism tracks the dir
# count, not the core count. A real source/log tree is many-dir, so the corpus is
# too (32 subdirs x 16 files = 512/format). Files are deliberately HEAVY (3000
# lines): at ~200 lines the run is process-startup dominated (~10ms) and the
# decode/match region is too small to show parallelism; at 3000 lines it dominates
# and `parallel_gain` settles into a stable >1x on a multicore box.
_BENCH_SUBDIRS = 32
_BENCH_PER_SUBDIR = 16
_BENCH_LINES = 3000


def _mint_corpus(ext: str, encode) -> Path:
    """Write the nested compressed corpus for one format; return its root dir."""
    raw = (
        "".join(
            f"line {j} of source with an occasional needle {j % 37}\n" for j in range(_BENCH_LINES)
        )
    ).encode()
    blob = encode(raw)  # one compressed image, fanned out across the nested tree
    root = FIX / "corpus" / ext
    for s in range(_BENCH_SUBDIRS):
        sub = root / f"sub{s}"
        sub.mkdir(parents=True, exist_ok=True)
        for i in range(_BENCH_PER_SUBDIR):
            (sub / f"f{i}.txt.{ext}").write_bytes(blob)
    return root


def do_bench(floor_rg: float, floor_parallel: float) -> int:
    """Race gist -z over a nested compressed corpus: pipeline vs serial vs rg.

    Two signals over the SAME bytes, both back-to-back so hardware cancels:

      * vs_rg = rg / gist_pipeline — the BLOCKING regression floor. gist's edge
        over rg here is ARCHITECTURAL (native `std.compress` decode of the common
        formats in-process vs rg's fork-a-decompressor-per-file), so the margin is
        large (~4-9x) and noise-immune. A conservative `--floor-rg` (default 2.0x)
        never false-trips on jitter yet catches a real regression — e.g. someone
        routing gzip through a per-file fork, or breaking the in-process decoder.
        This is the "beat ripgrep" claim, pinned as a number (sins.mdc: truth).
      * parallel_gain = gist_serial / gist_pipeline — INFORMATIONAL. The pipeline
        fuses decode+match per file across workers, but its work-stealing is
        directory-granular, so the gain tracks the corpus's dir count — corpus-
        shape-sensitive and therefore not a stable blocking floor (a flat archive
        of many files under-parallelizes). Shown to catch a gross parallelism loss;
        `--floor-parallel` defaults to 0 (report-only). The deterministic guard for
        "the pipeline still handles -z at all" is the `transformsRidePipeline` Zig
        unit test, not this wall-clock number.
    """
    cores = os.cpu_count() or 1
    native = {
        "gz": lambda b: gzip.compress(b, mtime=0),
        "xz": lambda b: lzma.compress(b, format=lzma.FORMAT_XZ),
    }
    if shutil.which("zstd"):
        native["zst"] = lambda b: (
            subprocess.run(["zstd", "-q", "-c"], input=b, stdout=subprocess.PIPE, check=True).stdout
        )
    n_files = _BENCH_SUBDIRS * _BENCH_PER_SUBDIR
    have_rg = shutil.which(RG) is not None
    print(
        f"\n=== -z race: gist pipeline vs serial vs rg — {n_files} files/format, "
        f"nested {_BENCH_SUBDIRS}x{_BENCH_PER_SUBDIR}, {cores} cores, min of 6 ==="
    )
    print(f"{'format':<7} {'par_ms':>8} {'ser_ms':>8} {'rg_ms':>8} {'vs_rg':>7} {'par_gain':>9}")
    par_env = _engine_env(serial=False)
    ser_env = _engine_env(serial=True)
    worst_rg, worst_parallel = float("inf"), float("inf")
    for ext, encode in native.items():
        _mint_corpus(ext, encode)
        args = ["-z", "-c", "needle 3$", f"corpus/{ext}"]
        par = _min_time(GIST, args, env=par_env)
        ser = _min_time(GIST, args, env=ser_env)
        gain = ser / par if par > 0 else float("inf")
        worst_parallel = min(worst_parallel, gain)
        rm = _min_time(RG, args) if have_rg else float("nan")
        vs = rm / par if have_rg and par > 0 else float("nan")
        if have_rg:
            worst_rg = min(worst_rg, vs)
        print(
            f"{ext:<7} {par * 1e3:>7.1f}m {ser * 1e3:>7.1f}m "
            f"{rm * 1e3:>7.1f}m {vs:>6.2f}x {gain:>8.2f}x"
        )

    if have_rg:
        print(f"worst vs_rg:         {worst_rg:.2f}x  (floor {floor_rg:.2f}x, BLOCKING)")
    else:
        print("  (vs_rg floor skipped: ripgrep not on PATH)")
    print(f"worst parallel_gain: {worst_parallel:.2f}x  (informational)")
    rc = 0
    if have_rg and floor_rg > 0 and worst_rg < floor_rg:
        print(
            f"✗ REGRESSION: -z vs_rg {worst_rg:.2f}x < floor {floor_rg:.2f}x — gist "
            f"lost its in-process-decode edge over ripgrep (check ingest.zig's native "
            f"decoders / a fork-per-file path)"
        )
        rc = 1
    if floor_parallel > 0 and cores >= 2 and worst_parallel < floor_parallel:
        print(f"✗ REGRESSION: -z parallel_gain {worst_parallel:.2f}x < floor {floor_parallel:.2f}x")
        rc = 1
    return rc


def _min_time(bin_: str, args: list[str], n: int = 6, env: dict[str, str] | None = None) -> float:
    """Min of N wall-clock timings of `bin_ args` from the fixture root (inf on timeout)."""
    best = float("inf")
    for _ in range(n):
        t0 = time.perf_counter()
        try:
            run(bin_, args, FIX, env if env is not None else {**os.environ})
        except subprocess.TimeoutExpired:
            return float("inf")
        best = min(best, time.perf_counter() - t0)
    return best


def main() -> int:
    """CLI entry: `run [--engine both|parallel|serial]` or `bench [--floor N]`."""
    global GIST, FIX
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run")
    pr.add_argument("--engine", default="both", choices=["both", "parallel", "serial"])
    pb = sub.add_parser("bench")
    pb.add_argument(
        "--floor-rg",
        type=float,
        default=2.0,
        help="fail if the worst gist-vs-rg -z speedup drops below this "
        "(blocking; the architectural in-process-decode edge, ~4-9x)",
    )
    pb.add_argument(
        "--floor-parallel",
        type=float,
        default=0.0,
        help="fail if the worst pipeline-vs-serial -z gain drops below this "
        "(informational by default; corpus-shape-sensitive)",
    )
    a = ap.parse_args()

    FIX = Path(tempfile.mkdtemp(prefix="gist-rgtransforms-"))
    atexit.register(lambda: shutil.rmtree(FIX, ignore_errors=True))
    GIST = _find_gist()
    print(f"gist={GIST}\nrg={RG}")
    if a.cmd == "run":
        return do_run(a.engine)
    if a.cmd == "bench":
        return do_bench(a.floor_rg, a.floor_parallel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
