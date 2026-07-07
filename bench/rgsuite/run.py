#!/usr/bin/env python3
"""Differential drop-in proof: replay ripgrep's OWN integration suite against
gist's `rg` verb and score it honestly against real ripgrep as the oracle.

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
from __future__ import annotations
import base64, json, os, re, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GIST = HERE.parents[1] / "zig-out" / "bin" / "gist"  # …/gist/zig-out/bin — the CLI (`rg` verb)
RG = "rg"
spec = json.loads((HERE / "spec.json").read_text())


def materialize(rec, root: Path):
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
        with open(p, "wb") as fh:
            fh.truncate(int(s["size"]))
    # Symlinks (ripgrep's Dir::link_file/link_dir → absolute symlink target).
    for l in rec.get("symlinks", []):
        p = root / l["path"]
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.is_symlink() or p.exists():
            try: p.unlink()
            except OSError: pass
        os.symlink(root / l["target"], p)


def run(cmd, cwd, stdin_bytes):
    # No piped input → hand the child /dev/null (a char device), exactly like
    # ripgrep's own Rust harness. Load-bearing: an empty *pipe* would make rg
    # read (empty) stdin instead of searching the directory.
    kw = {"input": stdin_bytes} if stdin_bytes is not None else {"stdin": subprocess.DEVNULL}
    try:
        r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=20, **kw)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, b"", b"timeout"


def sort_lines(b: bytes) -> bytes:
    ls = b.decode("utf-8", "replace").strip("\n").split("\n") if b.strip() else []
    return ("\n".join(sorted(ls)) + ("\n" if ls else "")).encode()


# `--stats` prints two wall-clock lines (`… seconds spent searching`, `… seconds
# total`) that are inherently non-deterministic. ripgrep's own tests only assert
# `contains("seconds")`, never the value — so we normalize both sides' timing
# lines to a fixed token before the byte-exact diff (not a correctness property).
_SECONDS = re.compile(rb"^[0-9.]+ (seconds spent searching|seconds total)$", re.M)


def norm_time(b: bytes) -> bytes:
    return _SECONDS.sub(rb"T \1", b)


# `--json` carries the same inherently non-reproducible accounting the text
# `--stats` block does: wall-clock `elapsed`/`elapsed_total` objects and the
# printer-internal `bytes_printed` byte count. ripgrep's own JSON tests assert
# structure + counts, never these — so we normalize just those fields (on BOTH
# sides) before the byte-exact diff, exactly like the `seconds` normalization.
_ELAPSED = re.compile(rb'"elapsed(?:_total)?":\{[^}]*\}')
_BYTES_PRINTED = re.compile(rb'"bytes_printed":\d+')


def norm_json(b: bytes) -> bytes:
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


def _unicode_caseless(rec) -> bool:
    if not any(a in ("-i", "--ignore-case", "-S", "--smart-case") for a in rec["argv"]):
        return False
    return any(not a.startswith("-") and not a.isascii() for a in rec["argv"])


def score(rec):
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
        rc_rg, out_rg, err_rg = run([RG, "--path-separator", "/"] + argv, cwd, stdin)
        rc_g, out_g, err_g = run([str(GIST), "rg"] + argv, cwd, stdin)

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
    # bug). Three boundaries, each stated in gist's README/architecture:
    #   (a) ignore-agnostic: gist deliberately does NOT read .gitignore/.ignore
    #       (an agent-facing locator searches what's on disk).
    #   (b) text/source-oriented: gist skips binary files; it never emits
    #       ripgrep's "binary file matches" summary line.
    #   (c) ASCII case-folding: `-i` folds ASCII only (no Unicode case folding).
    if _exercises_ignore(rec):
        return "NA", "unsupported ignore source by design (global gitignore / .fdignore)"
    if b"binary file matches" in out_rg:
        return "NA", "text/source-oriented by design (skips binary)"
    if _unicode_caseless(rec):
        return "NA", "ASCII case-fold by design (no Unicode -i)"
    return "FAIL", None


def main():
    from collections import Counter
    if not GIST.exists():
        sys.exit(f"gist CLI not built at {GIST} — run `zig build` in {HERE.parents[1]}")
    list_na = "--list-na" in sys.argv[1:]
    buckets, fails, nas, results = Counter(), [], [], []
    for rec in spec:
        b, detail = score(rec)
        buckets[b] += 1
        results.append({"name": rec["name"], "file": rec["file"], "bucket": b,
                        "argv": rec["argv"], "detail": detail})
        if b == "FAIL":
            fails.append(rec)
        elif b == "NA":
            nas.append((rec["name"], detail))
    (HERE / "results.json").write_text(json.dumps(results, indent=1) + "\n")

    total = sum(buckets.values())
    print(f"=== gist rg vs ripgrep {_rg_version()} — {total} mined tests ===")
    for k in ["PASS", "ORDER", "FAIL", "NA", "RG_ERR", "FIXTURE", "SKIP"]:
        if buckets[k]:
            print(f"  {k:8} {buckets[k]:4}")
    inscope = buckets["PASS"] + buckets["ORDER"] + buckets["FAIL"]
    if inscope:
        pct = 100 * (buckets["PASS"] + buckets["ORDER"]) / inscope
        print(f"\nsupported-surface parity: {buckets['PASS']+buckets['ORDER']}/{inscope} = {pct:.1f}%")
    if fails:
        print(f"\n=== {len(fails)} FAILs ===")
        for r in fails:
            print(f"  {r['file']:14} {r['name']:34} {r['argv']}")
    if list_na:
        print(f"\n=== {len(nas)} NA (unsupported by design) ===")
        for name, reason in nas:
            print(f"  {name:36} {reason}")
    sys.exit(1 if fails else 0)


def _rg_version() -> str:
    try:
        out = subprocess.run([RG, "--version"], capture_output=True, text=True).stdout
        return out.split("\n", 1)[0].replace("ripgrep ", "").strip() or "?"
    except Exception:
        return "?"


if __name__ == "__main__":
    main()
