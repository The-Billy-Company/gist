#!/usr/bin/env python3
"""Multi-corpus differential sweep: `gist rg` vs real ripgrep on foreign trees.

Every other gate in bench/ measures ONE corpus (a large host monorepo). This
sweep replays a broad flag/pattern slate over each installed corpus in
`.local/gist-corpora/` (see fetch.sh) — trees with radically different shapes:
the Linux kernel (C at scale), CPython (encoding fixtures), TypeScript
(3 MiB single files + 60k tiny ones), OpenSubtitles (one giant non-code text
file per language, real Cyrillic), and the generated `torture` tree
(cap edges, straddles, symlink cycles, ignore corner cases).

ripgrep is the oracle — no hardcoded expected strings, ever. For each case we
run identical argv in the corpus root and require:

  * exit-code parity (0 match / 1 no-match / 2 error), and
  * stdout parity — byte-exact for `--sort path` cases, order-insensitive
    (sorted-line) equality for unsorted recursive walks, where rg's own
    output order is nondeterministic.

The whole slate runs once per ENGINE (parallel pipeline.zig + serial run.zig
via GIST_NO_PARALLEL) — the two share flags but not code paths, and a
single-engine sweep has already missed a real regression once (see
../rgsuite/README.md "Two engines, one suite").

Usage:
  python3 sweep.py                       # all installed corpora, both engines
  python3 sweep.py --corpora torture     # one corpus
  python3 sweep.py --engine serial       # one engine
  python3 sweep.py --list                # print the case slate and exit
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]  # corpora → apparatus → bench → repo
REPO = KERNEL
GIST = KERNEL / "zig-out" / "bin" / "gist"
CORPORA = Path(os.environ.get("GIST_CORPORA_DIR", REPO / ".local" / "gist-corpora"))
TIMEOUT = int(os.environ.get("SWEEP_TIMEOUT", "300"))

# The oracle needs rg's full uncapped stream, and hint lines would pollute
# stderr-based diagnostics.
os.environ["GIST_UNCAP"] = "1"
os.environ["GIST_HINTS"] = "0"

# ── the case slate ───────────────────────────────────────────────────────────
# (label, argv, mode) — mode `set` compares sorted stdout lines (recursive
# walks, rg's own order is nondeterministic); `exact` requires byte equality
# (the argv must make rg deterministic itself, e.g. --sort path or -c on a
# single file). Patterns favor -l/-c so a dense corpus can't drown the diff.
COMMON: list[tuple[str, list[str], str]] = [
    ("files-walk", ["--files"], "set"),
    ("literal-common-count", ["-c", "-e", "the"], "set"),
    ("literal-punct", ["-F", "-l", "-e", "})"], "set"),
    ("literal-casei", ["-i", "-c", "-e", "error"], "set"),
    ("word-boundary", ["-w", "-c", "-e", "int"], "set"),
    ("line-regexp", ["-x", "-c", "-e", ".*end.*"], "set"),
    ("regex-decl", ["-c", "-e", r"func\s+\w+\("], "set"),
    ("regex-anchored", ["-c", "-e", r"^\s*static\s"], "set"),
    ("regex-classcount", ["-l", "-e", r"[0-9a-f]{8}-[0-9a-f]{4}"], "set"),
    ("regex-alternation", ["-c", "-e", r"return|continue|break"], "set"),
    ("regex-dense", ["-c", "-e", r"\w{3,8}"], "set"),
    ("regex-eol", ["-c", "-e", r";$"], "set"),
    ("regex-litalt", ["-c", "-e", r"panic|0x"], "set"),
    ("unicode-word", ["-c", "-e", r"\w+é\w*"], "set"),
    ("unicode-prop", ["-l", "-e", r"\p{Cyrillic}{4,}"], "set"),
    ("unicode-fold", ["-i", "-c", "-e", "CAFÉ"], "set"),
    ("invert-count", ["-v", "-c", "-e", "e"], "set"),
    ("max-count", ["-m", "3", "-c", "-e", "a"], "set"),
    ("only-matching", ["-o", "-c", "-e", r"[A-Z]{4,}"], "set"),
    ("context", ["--sort", "path", "-n", "-A1", "-B1", "-e", "NEEDLE"], "exact"),
    ("max-columns", ["--sort", "path", "-n", "-M", "40", "-e", "NEEDLE"], "exact"),
    ("replace", ["--sort", "path", "-n", "-r", "[$0]", "-e", r"NEEDLE_\w+"], "exact"),
    ("sorted-lines", ["--sort", "path", "-n", "--no-heading", "-e", r"NEEDLE_\w+"], "exact"),
    ("json", ["--sort", "path", "--json", "-e", r"NEEDLE_\w+"], "exact"),
    ("multiline", ["-U", "-l", "-e", r"NEEDLE_\w+[\s\S]{0,40}?\n\w"], "set"),
    ("pcre-lookahead", ["-P", "-l", "-e", r"NEEDLE_(?=\w*CAP)"], "set"),
    ("hidden", ["--hidden", "-l", "-e", "NEEDLE"], "set"),
    ("no-ignore", ["--no-ignore", "--hidden", "-c", "-e", "NEEDLE"], "set"),
    ("unrestricted-uu", ["-uu", "-l", "-e", "NEEDLE"], "set"),
    ("glob-scope", ["-g", "*.txt", "-l", "-e", "NEEDLE"], "set"),
    ("glob-negate", ["-g", "!*.log", "-l", "-e", "NEEDLE"], "set"),
    ("type-scope", ["-t", "c", "-c", "-e", r"#include"], "set"),
    ("binary-a", ["-a", "-l", "-e", "NEEDLE"], "set"),
]

# Corpus-specific slates: real needles for that tree's shape.
PER_CORPUS: dict[str, list[tuple[str, list[str], str]]] = {
    "linux": [
        ("linux-symbol", ["-l", "-e", "EXPORT_SYMBOL_GPL"], "set"),
        ("linux-makefiles", ["-t", "make", "-l", "-e", "obj-y"], "set"),
        ("linux-rare", ["-n", "--sort", "path", "-e", "TASK_UNINTERRUPTIBLE"], "exact"),
        ("linux-word", ["-w", "-l", "-e", "mutex_lock"], "set"),
    ],
    "cpython": [
        ("cpython-def", ["-c", "-e", r"^\s*def test_"], "set"),
        ("cpython-rare", ["-n", "--sort", "path", "-e", "Py_INCREF"], "exact"),
        ("cpython-surrogate", ["-l", "-e", r"\\udc80"], "set"),
    ],
    "typescript": [
        ("ts-checker", ["-c", "-e", "getTypeOfSymbol", "src/compiler/checker.ts"], "exact"),
        ("ts-baselines", ["-l", "-e", "~~~~~~~"], "set"),
        ("ts-interface", ["-c", "-e", r"export interface \w+ extends"], "set"),
    ],
    "subtitles": [
        ("sub-en-literal", ["-c", "-e", "Sherlock Holmes", "en.txt"], "exact"),
        ("sub-en-casei", ["-i", "-c", "-e", "sherlock holmes", "en.txt"], "exact"),
        ("sub-en-alt", ["-c", "-e", r"Sherlock Holmes|John Watson|Professor Moriarty", "en.txt"], "exact"),
        ("sub-en-word", ["-w", "-c", "-e", "though", "en.txt"], "exact"),
        ("sub-en-suffix", ["-c", "-e", r"\w+ing that", "en.txt"], "exact"),
        ("sub-ru-literal", ["-c", "-e", "Шерлок Холмс", "ru.txt"], "exact"),
        ("sub-ru-casei", ["-i", "-c", "-e", "шерлок холмс", "ru.txt"], "exact"),
        ("sub-ru-word", ["-w", "-c", "-e", "чтобы", "ru.txt"], "exact"),
        ("sub-ru-class", ["-c", "-e", r"[а-я]+никогда", "ru.txt"], "exact"),
        ("sub-lines", ["-n", "-m", "50", "-e", "Moriarty", "en.txt"], "exact"),
    ],
    "torture": [
        # Every generator needle by name — a FAIL names its trap directly.
        *[
            (f"needle-{n.lower()}", ["--sort", "path", "-n", "-e", n], "exact")
            for n in (
                "NEEDLE_UNDER_CAP",
                "NEEDLE_AT_CAP",
                "NEEDLE_SPANS_CAP_BOUNDARY",
                "NEEDLE_PAST_CAP",
                "NEEDLE_GIANT_LINE",
                "NEEDLE_GIANT_NO_NL",
                "NEEDLE_NO_TRAILING_NL",
                "STRADDLE_ME",
                "NEEDLE_CRLF",
                "NEEDLE_MIXED",
                "NEEDLE_CRLF_BOUNDARY",
                "NEEDLE_UTF16",
                "NEEDLE_UTF8_BOM",
                "NEEDLE_INVALID_UTF8",
                "NEEDLE_LATIN1",
                "NEEDLE_BINARY",
                "NEEDLE_LATE_NUL",
                "NEEDLE_SIGMA",
                "NEEDLE_CYRILLIC",
                "NEEDLE_DOTTED_I",
                "NEEDLE_IGNORED_LOG",
                "NEEDLE_NEGATED_KEEP",
                "NEEDLE_IGNORED_DIR",
                "NEEDLE_ANCHORED_ROOT",
                "NEEDLE_ANCHORED_SUB_SURVIVES",
                "NEEDLE_DOUBLESTAR_IGNORED",
                "NEEDLE_NESTED_REINCLUDE",
                "NEEDLE_IGNORE_OUTRANKS_GIT",
                "NEEDLE_HIDDEN",
                "NEEDLE_HIDDEN_DIR",
                "NEEDLE_SPACE_NAME",
                "NEEDLE_COLON_NAME",
                "NEEDLE_DASH_NAME",
                "NEEDLE_UNICODE_NAME",
                "NEEDLE_LONG_NAME",
                "NEEDLE_UPPER_EXT",
                "NEEDLE_DEEP_NEST",
                "NEEDLE_FANOUT",
                "NEEDLE_LINK_TARGET",
                "NEEDLE_CYCLE",
            )
        ],
        ("torture-uu-sweep", ["-uu", "-c", "-e", r"NEEDLE_\w+"], "set"),
        ("torture-hidden-sweep", ["--hidden", "-l", "-e", r"NEEDLE_\w+"], "set"),
        ("torture-casei-sigma", ["-i", "-c", "-e", "σίσυφοσ"], "set"),
        ("torture-casei-cyr", ["-i", "-c", "-e", "ЖИЗНЬ"], "set"),
        ("torture-fold-fullwidth", ["-l", "-e", r"ＮＥＥＤＬＥ"], "set"),
        ("torture-crlf-eol", ["--crlf", "-c", "-e", r"NEEDLE_CRLF$"], "set"),
        ("torture-utf16-E", ["-E", "utf-16", "-l", "-e", "NEEDLE_UTF16", "enc/utf16le_bom.txt"], "exact"),
        ("torture-latin1-E", ["-E", "latin-1", "-n", "-e", "café", "enc/latin1.txt"], "exact"),
        ("torture-follow-links", ["-L", "-l", "-e", "NEEDLE_LINK_TARGET", "links"], "set"),
        ("torture-dangling-link", ["-L", "-l", "-e", "NEEDLE_BESIDE_DANGLING", "broken"], "set"),
        ("torture-link-cycle", ["-L", "-l", "-e", "NEEDLE_CYCLE", "links"], "set"),
    ],
}


def run_one(argv: list[str], cwd: Path, env: dict[str, str] | None) -> tuple[int, bytes, bytes, float]:
    """Run argv in cwd; return (rc, stdout, stderr, seconds). 124 = timeout."""
    t0 = time.monotonic()
    try:
        r = subprocess.run(
            argv, cwd=cwd, capture_output=True, timeout=TIMEOUT,
            stdin=subprocess.DEVNULL, env=env, check=False,
        )
    except subprocess.TimeoutExpired:
        return 124, b"", b"timeout", time.monotonic() - t0
    return r.returncode, r.stdout, r.stderr, time.monotonic() - t0


def sorted_lines(b: bytes) -> bytes:
    """Return ``b`` with lines sorted for order-insensitive stdout compare."""
    return b"\n".join(sorted(b.split(b"\n")))


# `--json` carries inherently non-reproducible accounting (wall-clock elapsed
# objects + printer-internal bytes_printed); ripgrep's own tests never assert
# them, so both sides are normalized before the byte diff (same policy as
# ../rgsuite/run.py::norm_json). Everything else in the stream stays exact.
_ELAPSED = re.compile(rb'"elapsed(?:_total)?":\{[^}]*\}')
_BYTES_PRINTED = re.compile(rb'"bytes_printed":\d+')


def norm_json(b: bytes) -> bytes:
    """Zero the non-reproducible accounting fields on both sides of the diff."""
    return _BYTES_PRINTED.sub(rb'"bytes_printed":0', _ELAPSED.sub(rb'"elapsed":{}', b))


def preview_diff(rg_out: bytes, g_out: bytes, limit: int = 6) -> list[str]:
    """First lines present in exactly one side (order-insensitive preview)."""
    rg_set = rg_out.split(b"\n")
    g_set = g_out.split(b"\n")
    only_rg = [x for x in rg_set if x not in set(g_set)][:limit]
    only_g = [x for x in g_set if x not in set(rg_set)][:limit]
    out = []
    for x in only_rg:
        out.append("  rg-only  : " + x.decode("utf-8", "replace")[:160])
    for x in only_g:
        out.append("  gist-only: " + x.decode("utf-8", "replace")[:160])
    return out


def sweep_corpus(name: str, root: Path, engine: str, results: list[dict]) -> tuple[int, int]:
    """Run the slate for one corpus under one engine; returns (passes, fails)."""
    env = dict(os.environ)
    if engine == "serial":
        env["GIST_NO_PARALLEL"] = "1"
    else:
        env.pop("GIST_NO_PARALLEL", None)
    cases = COMMON + PER_CORPUS.get(name, [])
    passes = fails = 0
    for label, args, mode in cases:
        rc_r, out_r, _err_r, t_r = run_one(["rg", *args], root, env)
        rc_g, out_g, err_g, t_g = run_one([str(GIST), "rg", *args], root, env)
        if "--json" in args:
            out_r, out_g = norm_json(out_r), norm_json(out_g)
        ok = rc_r == rc_g and (
            out_r == out_g if mode == "exact" else sorted_lines(out_r) == sorted_lines(out_g)
        )
        # An unsorted `exact` walk may legitimately differ by whole-line order —
        # never applicable here (exact cases pin --sort path or a single file).
        rec = {
            "corpus": name, "engine": engine, "case": label, "mode": mode,
            "argv": args, "ok": ok, "rc_rg": rc_r, "rc_gist": rc_g,
            "secs_rg": round(t_r, 3), "secs_gist": round(t_g, 3),
        }
        if ok:
            passes += 1
        else:
            fails += 1
            rec["stderr_gist"] = err_g.decode("utf-8", "replace")[-400:]
            print(f"  FAIL [{name}/{engine}] {label}: rg exit {rc_r} vs gist {rc_g} (rg {t_r:.2f}s, gist {t_g:.2f}s)")
            for line in preview_diff(
                out_r if mode == "exact" else sorted_lines(out_r),
                out_g if mode == "exact" else sorted_lines(out_g),
            ):
                print(line)
            if err_g.strip():
                print("  gist-stderr: " + err_g.decode("utf-8", "replace").strip().splitlines()[-1][:160])
        results.append(rec)
    return passes, fails


def main() -> int:
    """CLI entry: sweep installed corpora and write JSON results."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--corpora", help="comma-separated subset (default: all installed)")
    ap.add_argument("--engine", choices=["parallel", "serial", "both"], default="both")
    ap.add_argument("--list", action="store_true", help="print the case slate and exit")
    ap.add_argument("--out", default=str(CORPORA / "sweep-results.json"))
    args = ap.parse_args()

    if args.list:
        for label, argv, mode in COMMON:
            print(f"common     {label:24s} [{mode}] {' '.join(argv)}")
        for corpus, cases in PER_CORPUS.items():
            for label, argv, mode in cases:
                print(f"{corpus:10s} {label:24s} [{mode}] {' '.join(argv)}")
        return 0

    if not GIST.exists():
        sys.exit(f"no gist CLI at {GIST} — run `zig build -Doptimize=ReleaseFast` first")
    installed = sorted(
        p.name for p in CORPORA.iterdir() if p.is_dir() and (p / ".corpus-ready").exists()
    ) if CORPORA.exists() else []
    want = args.corpora.split(",") if args.corpora else installed
    missing = [w for w in want if w not in installed]
    if missing:
        sys.exit(f"corpora not installed: {missing} — run fetch.sh (installed: {installed})")
    engines = ["parallel", "serial"] if args.engine == "both" else [args.engine]

    results: list[dict] = []
    total_pass = total_fail = 0
    for name in want:
        for engine in engines:
            t0 = time.monotonic()
            p, f = sweep_corpus(name, CORPORA / name, engine, results)
            total_pass += p
            total_fail += f
            print(f"{name}/{engine}: {p} pass, {f} fail  ({time.monotonic() - t0:.1f}s)")
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(results, indent=1))
    print(f"\nTOTAL: {total_pass} pass, {total_fail} fail → {args.out}")
    return 1 if total_fail else 0


if __name__ == "__main__":
    sys.exit(main())
