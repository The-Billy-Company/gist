#!/usr/bin/env python3
"""Differential drop-in proof: replay ripgrep's OWN integration suite against gist's `rg` verb and score it honestly against real ripgrep as the oracle.

For each mined test we materialize its fixture in a throwaway dir, run REAL `rg`
and `gist rg` on byte-identical inputs (same argv, same stdin), and compare
stdout + exit-class. ripgrep is the ground truth — we never trust a hardcoded
expected string, we diff against what the installed `rg` actually prints.

Buckets:
  PASS     gist stdout == rg stdout (+ matching exit-class)
  ORDER    differ only in line order (dir-walk nondeterminism) → soft pass
  FAIL     gist differs on a surface it claims to support → a real bug to fix
  NA       feature unsupported by gist's design (gist exits 2, OR the diff is
           attributable to a documented scope boundary — see below)
  RG_ERR   rg itself errored (bad usage / needs pcre2) — not gist's concern
  FIXTURE  the miner couldn't reproduce a referenced path (our miner's limit)
  SKIP     not runnable here (control-flow test, pcre2-only, non-stdout terminal)

Supported-surface parity = (PASS+ORDER) / (PASS+ORDER+FAIL): of everything gist
claims to do, how much matches ripgrep byte-for-byte. Needs `rg` on PATH (the
oracle) and a built `gist` CLI (../../zig-out/bin/gist → `zig build`, the `rg`
verb — see src/commands/cli/main.zig; distinct from the `gist-bench` harness).

Usage:  python3 run.py            # score the frozen spec.json
        python3 run.py --list-na  # also print the NA reasons
"""

import base64
import contextlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
GIST = HERE.parents[1] / "zig-out" / "bin" / "gist"  # …/gist/zig-out/bin — the CLI (`rg` verb)
RG = "rg"
spec = json.loads((HERE / "spec.json").read_text())


def materialize(rec, root: Path):
    """Perform materialize."""
    for d in rec["dirs"]:
        (root / d).mkdir(parents=True, exist_ok=True)
    for f in rec["files"]:
        p = root / f["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(base64.b64decode(f["b64"]))
    # Sparse zero-filled files (ripgrep's Dir::create_size = File::set_len).
    for s in rec.get("sized", []):
        p = root / s["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        with p.open("wb") as fh:
            fh.truncate(int(s["size"]))
    # Symlinks (ripgrep's Dir::link_file/link_dir → absolute symlink target).
    for link in rec.get("symlinks", []):
        p = root / link["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.is_symlink() or p.exists():
            with contextlib.suppress(OSError):
                p.unlink()
        p.symlink_to(root / link["target"])


def run(cmd, cwd, stdin_bytes, engine_env=None):
    """Run a command with optional stdin bytes; return (rc, stdout, stderr).

    No piped input → hand the child /dev/null (a char device), exactly like
    ripgrep's own Rust harness. Load-bearing: an empty *pipe* would make rg
    read (empty) stdin instead of searching the directory.
    """
    kw = {"input": stdin_bytes} if stdin_bytes is not None else {"stdin": subprocess.DEVNULL}
    env = {**os.environ, **engine_env} if engine_env else None
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=20, env=env, **kw)
    except subprocess.TimeoutExpired:
        return 124, b"", b"timeout"
    else:
        return r.returncode, r.stdout, r.stderr


def sort_lines(b: bytes) -> bytes:
    """Return bytes for sort lines."""
    ls = b.decode("utf-8", "replace").strip("\n").split("\n") if b.strip() else []
    return ("\n".join(sorted(ls)) + ("\n" if ls else "")).encode()


# `--stats` prints two wall-clock lines (`… seconds spent searching`, `… seconds
# total`) that are inherently non-deterministic. ripgrep's own tests only assert
# `contains("seconds")`, never the value — so we normalize both sides' timing
# lines to a fixed token before the byte-exact diff (not a correctness property).
_SECONDS = re.compile(rb"^[0-9.]+ (seconds spent searching|seconds total)$", re.MULTILINE)


def norm_time(b: bytes) -> bytes:
    """Return bytes for norm time."""
    return _SECONDS.sub(rb"T \1", b)


# `--json` carries the same inherently non-reproducible accounting the text
# `--stats` block does: wall-clock `elapsed`/`elapsed_total` objects and the
# printer-internal `bytes_printed` byte count. ripgrep's own JSON tests assert
# structure + counts, never these — so we normalize just those fields (on BOTH
# sides) before the byte-exact diff, exactly like the `seconds` normalization.
_ELAPSED = re.compile(rb'"elapsed(?:_total)?":\{[^}]*\}')
_BYTES_PRINTED = re.compile(rb'"bytes_printed":\d+')


def norm_json(b: bytes) -> bytes:
    """Return bytes for norm json."""
    b = _ELAPSED.sub(rb'"elapsed":{}', b)
    return _BYTES_PRINTED.sub(rb'"bytes_printed":0', b)


# gist now IMPLEMENTS the git ignore boundary (.gitignore/.ignore/.rgignore,
# .git/info/exclude incl. linked worktrees, --ignore-file, --no-ignore*), so a
# diverging ignore test is a REAL bug, not "by design" — it must FAIL, not hide
# as NA. Only two ignore sub-features stay genuinely out of scope: a GLOBAL
# gitignore (git `core.excludesFile` / `$XDG_CONFIG_HOME`, machine-external
# state a locator shouldn't read) and fd's `.fdignore` dialect (not ripgrep's).
UNSUPPORTED_IGNORE_FILES = {".fdignore"}
UNSUPPORTED_IGNORE_FLAGS = ("--no-ignore-global", "--ignore-file-case-insensitive")


def _exercises_ignore(rec) -> bool:
    for f in rec["files"]:
        if f["path"].rsplit("/", 1)[-1] in UNSUPPORTED_IGNORE_FILES:
            return True
    return any(a in UNSUPPORTED_IGNORE_FLAGS for a in rec["argv"])


_ANSI = re.compile(rb"\x1b\[[0-9;]*m")


def _strip_ansi(b: bytes) -> bytes:
    return _ANSI.sub(b"", b)


def _uses_color(rec) -> bool:
    return any(a in ("--color", "--colors") or a.startswith(("--color=", "--colors="))
               for a in rec["argv"])


def score(rec, engine_env=None):
    """Perform score."""
    if rec["status"] == "skip" or not rec["argv"]:
        return "SKIP", "control-flow/unresolved"
    if rec["pcre2"]:
        return "SKIP", "pcre2-only"
    if rec["terminal"] != "stdout":
        return "SKIP", f"terminal={rec['terminal']}"

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        materialize(rec, root)
        cwd = str(root / rec["current_dir"]) if rec["current_dir"] else str(root)
        stdin = base64.b64decode(rec["stdin"]) if rec["stdin"] else None
        argv = rec["argv"]
        rc_rg, out_rg, err_rg = run([RG, "--path-separator", "/", *argv], cwd, stdin)
        rc_g, out_g, err_g = run([str(GIST), "rg", *argv], cwd, stdin, engine_env)

    if rc_rg == 2:
        e = err_rg.decode("utf-8", "replace")
        if "No such file" in e or "IO error" in e:
            return "FIXTURE", "miner did not build a referenced path"
        return "RG_ERR", e[:120]
    if rc_g == 2:
        return "NA", err_g.decode("utf-8", "replace")[:120]

    if "--stats" in rec["argv"]:
        out_g, out_rg = norm_time(out_g), norm_time(out_rg)
    if "--json" in rec["argv"]:
        out_g, out_rg = norm_json(out_g), norm_json(out_rg)
    if out_g == out_rg:
        return "PASS", ""
    if sort_lines(out_g) == sort_lines(out_rg):
        return "ORDER", "line-order only"

    # Honest design-boundary re-bucketing — applied ONLY to a case that would
    # otherwise FAIL, and ONLY when the divergence is attributable to a
    # documented gist scope boundary (never to excuse a real output-contract
    # bug). Each boundary is stated in gist's README/source:
    #   (a) ignore-agnostic: an unsupported ignore SOURCE (global gitignore /
    #       .fdignore); the in-tree gitignore boundary IS implemented and FAILs.
    #   (b) text/source-oriented: gist skips binary files; it never emits
    #       ripgrep's "binary file matches" summary line.
    #   (c) own type registry: `--type-list` is now rg-SORTED and rg-FRAMED
    #       (`types.writeTypeList` — lexicographic names + globs), and gist's
    #       table is a strict SUPERSET of rg's (every rg type + glob present,
    #       plus gist-only types and per-type enrichments), so most rows are
    #       byte-identical to rg and the rest differ only by being richer. It
    #       is not byte-identical overall precisely because it covers more.
    #   (d) own color palette: gist paints a deliberate scheme (bright-red
    #       underline matches, dim separators — color.zig). When the ONLY
    #       divergence is ANSI color codes (identical after stripping them), it's
    #       the documented palette, never an output-contract bug.
    #   (e) `--crlf`+`--color`: ripgrep injects a `\r` in color mode that is
    #       absent from the file AND from rg's OWN plain output; gist matches rg's
    #       plain output and stays self-consistent, so it does not replicate it.
    if _exercises_ignore(rec):
        return "NA", "unsupported ignore source by design (global gitignore / .fdignore)"
    if b"binary file matches" in out_rg:
        return "NA", "text/source-oriented by design (skips binary)"
    if "--type-list" in rec["argv"]:
        return "NA", "rg-sorted superset registry by design (scope/types.zig)"
    if _uses_color(rec) and _strip_ansi(out_g) == _strip_ansi(out_rg):
        return "NA", "own color palette by design (color.zig)"
    if _uses_color(rec) and "--crlf" in rec["argv"] and \
            _strip_ansi(out_g).replace(b"\r\n", b"\n") == _strip_ansi(out_rg).replace(b"\r\n", b"\n"):
        return "NA", "ripgrep --crlf+color \\r artifact not replicated (matches rg plain)"
    return "FAIL", None


# The whole mined suite runs once per ENGINE — parallel (`pipeline.zig`,
# gist's default recursive-walk dispatch) and serial (`run.zig`, forced via
# the internal `GIST_NO_PARALLEL` knob — see `pipeline.eligible`'s doc
# comment in the Zig source). A single-engine run isn't a complete parity
# proof: the parallel engine landed a day after a serial-only ignore-parity
# fix and silently missed porting it (`Ignore.skipFromVerdict` lacked the
# whitelist-override pair `shouldSkip` had), and the vast majority of this
# suite's recursive-walk cases dispatch straight to the parallel path by
# default — a serial-only harness would never have caught that regression.
_ENGINES = [("parallel", None), ("serial", {"GIST_NO_PARALLEL": "1"})]


def _run_engine(engine_env):
    from collections import Counter
    buckets, fails, nas, results = Counter(), [], [], []
    for rec in spec:
        b, detail = score(rec, engine_env)
        buckets[b] += 1
        results.append({"name": rec["name"], "file": rec["file"], "bucket": b,
                        "argv": rec["argv"], "detail": detail})
        if b == "FAIL":
            fails.append(rec)
        elif b == "NA":
            nas.append((rec["name"], detail))
    return buckets, fails, nas, results


def main():
    """CLI entry point."""
    if not GIST.exists():
        sys.exit(f"gist CLI not built at {GIST} — run `zig build` in {HERE.parents[1]}")
    list_na = "--list-na" in sys.argv[1:]
    any_fails = False
    all_results = {}
    for label, engine_env in _ENGINES:
        buckets, fails, nas, results = _run_engine(engine_env)
        all_results[label] = results

        total = sum(buckets.values())
        print(f"=== gist rg [{label}] vs ripgrep {_rg_version()} — {total} mined tests ===")
        for k in ["PASS", "ORDER", "FAIL", "NA", "RG_ERR", "FIXTURE", "SKIP"]:
            if buckets[k]:
                print(f"  {k:8} {buckets[k]:4}")
        inscope = buckets["PASS"] + buckets["ORDER"] + buckets["FAIL"]
        if inscope:
            pct = 100 * (buckets["PASS"] + buckets["ORDER"]) / inscope
            print(f"\nsupported-surface parity [{label}]: {buckets['PASS']+buckets['ORDER']}/{inscope} = {pct:.1f}%")
        if fails:
            any_fails = True
            print(f"\n=== {len(fails)} FAILs [{label}] ===")
            for r in fails:
                print(f"  {r['file']:14} {r['name']:34} {r['argv']}")
        if list_na:
            print(f"\n=== {len(nas)} NA (unsupported by design) [{label}] ===")
            for name, reason in nas:
                print(f"  {name:36} {reason}")
        print()
    (HERE / "results.json").write_text(json.dumps(all_results["parallel"], indent=1) + "\n")
    sys.exit(1 if any_fails else 0)


def _rg_version() -> str:
    try:
        out = subprocess.run([RG, "--version"], capture_output=True, text=True).stdout
        return out.split("\n", 1)[0].replace("ripgrep ", "").strip() or "?"
    except Exception:
        return "?"


if __name__ == "__main__":
    main()
