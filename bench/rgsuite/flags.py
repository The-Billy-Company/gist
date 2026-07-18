#!/usr/bin/env python3
"""gist ⇄ ripgrep differential proof for the walk/order/ignore flags rgsuite can't mine.

`run.py` replays ripgrep's *own* mined suite, but that suite exercises almost no
`--sort`/`--sortr`/`--sort-files`, `-j`/`--threads`, `--one-file-system`, or
global-`core.excludesFile` behavior — the results depend on file *timestamps*,
*device ids*, worker *thread counts*, and a user's *global git config*, none of
which a self-contained mined replay can pin. This is the hand-authored companion
that certifies exactly those flags now that gist implements them, with ripgrep as
the ground truth (no hardcoded expected strings):

  * ordering flags are proven **byte-for-byte** on a fixture whose modified /
    accessed times are deliberately shuffled out of path order, so a comparator
    that ignored its key would diverge;
  * negation / one-file-system / global-ignore cases are pinned deterministic by
    pairing them with `--sort path`, so the assertion is byte-exact, not a set;
  * `-j`/`--threads` is proven order-invariant (gist -j1 == gist -jN) and a set
    match against rg (the parallel walk streams in worker-discovery order);
  * every non-thread case also asserts the indexed path equals `--no-index`
    (read-elision soundness), and the whole slate runs once per **engine** — the
    parallel work-stealing walk and the serial fallback (`GIST_NO_PARALLEL=1`) —
    because they own separate walk/ignore code (see rgsuite README, "Two engines").

stdlib-only. Fixtures are generated into a temp dir each run (the generator here
is the committed contract), so nothing large or machine-specific is tracked.

Subcommands: run [--engine both|parallel|serial] | bench
"""

from __future__ import annotations

import argparse
import atexit
from dataclasses import dataclass, field
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

# Fixture file set: created in lexicographic order (so birthtime order == path
# order) but with modified/accessed stamps shuffled into distinct non-path
# permutations, so an ascending-time sort lands a provably different order than a
# path sort — a comparator that dropped its key could not accidentally pass.
TREE_FILES = ("a_apple.txt", "b_banana.txt", "c_cherry.txt", "d_date.txt", "e_elder.txt")
_MTIME_RANK = {
    "c_cherry.txt": 1,
    "a_apple.txt": 2,
    "e_elder.txt": 3,
    "b_banana.txt": 4,
    "d_date.txt": 5,
}
_ATIME_RANK = {
    "e_elder.txt": 1,
    "d_date.txt": 2,
    "a_apple.txt": 3,
    "c_cherry.txt": 4,
    "b_banana.txt": 5,
}
_EPOCH = 1_600_000_000


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


def _norm(data: bytes, sort_lines: bool) -> bytes:
    """Canonicalize stdout: line-sorted set (order-agnostic) or raw bytes."""
    return b"\n".join(sorted(data.split(b"\n"))) if sort_lines else data


# ───────────────────────── fixtures ─────────────────────────


def gen_fixtures(root: Path) -> tuple[dict[str, str], dict[str, str]]:
    """Build the tree/, repo/ + home/ fixtures; return (base_env, global_ignore_env).

    This generator is the committed contract — nothing large is tracked. `tree/`
    drives ordering + threading; `repo/` (a git repo) + `home/` (a `.gitconfig`
    naming a global excludesFile) drive `--no-ignore-global`.
    """
    root.mkdir(parents=True, exist_ok=True)
    tree = root / "tree"
    tree.mkdir()
    for name in TREE_FILES:  # lexicographic creation ⇒ birthtime order == path order
        (tree / name).write_text("MATCH one\nplain filler line\nMATCH two\n")
        time.sleep(0.01)  # distinct birthtimes, so `--sort created` is total
    for name in TREE_FILES:  # shuffle mtime/atime out of path order
        os.utime(tree / name, (_EPOCH + _ATIME_RANK[name] * 100, _EPOCH + _MTIME_RANK[name] * 100))

    home = root / "home"
    home.mkdir()
    (home / "globalignore").write_text("*.log\n")
    (home / ".gitconfig").write_text(f"[core]\n\texcludesFile = {home / 'globalignore'}\n")
    repo = root / "repo"
    (repo / ".git").mkdir(parents=True)  # rg honors gitignore only inside a git repo
    (repo / "keep.txt").write_text("MATCH keep\n")
    (repo / "skip.log").write_text("MATCH skip\n")

    base_env = {**os.environ}
    gi_env = {**os.environ, "HOME": str(home), "GIT_CONFIG_NOSYSTEM": "1"}
    gi_env.pop("XDG_CONFIG_HOME", None)  # keep resolution on the fixture's HOME
    return base_env, gi_env


# ───────────────────────── case matrix ─────────────────────────


@dataclass
class Case:
    """One differential case: shared argv (path appended) + comparison knobs."""

    name: str
    args: list[str]
    path: str
    cwd: Path
    env: dict[str, str] = field(default_factory=dict)
    sort_lines: bool = False  # True ⇒ assert set-equality (order not pinned)
    index_safe: bool = True  # also assert indexed stdout == --no-index


def _cases(base_env: dict[str, str], gi_env: dict[str, str]) -> list[Case]:
    """The curated adversarial flag cases (ripgrep is the oracle for every one)."""
    cs: list[Case] = []

    def tree(name, args, **kw):
        cs.append(Case(name, args, "tree", FIX, env=base_env, **kw))

    # ── ordering: byte-exact on shuffled mtime/atime (key actually consulted) ──
    for key in ("path", "modified", "accessed"):
        tree(f"sort:{key}", ["--sort", key, "-n", "MATCH"])
        tree(f"sortr:{key}", ["--sortr", key, "-n", "MATCH"])
    # created: birthtime can't be set portably, so pin the *set*, not the order.
    tree("sort:created", ["--sort", "created", "-n", "MATCH"], sort_lines=True)
    tree("sortr:created", ["--sortr", "created", "-n", "MATCH"], sort_lines=True)
    tree("sort-files", ["--sort-files", "-n", "MATCH"])  # rg alias for --sort path
    # ordering composes with presentation (filenames-only, count, heading group)
    tree("sort:path -l", ["--sort", "path", "-l", "MATCH"])
    tree("sort:modified -c", ["--sort", "modified", "-c", "-H", "MATCH"])

    # ── negation last-wins, pinned deterministic by --sort path ──
    def neg(name, extra):
        tree(name, ["--sort", "path", *extra, "-n", "MATCH"])

    neg("neg:heading-on", ["--no-heading", "--heading"])  # heading forced on ⇒ grouped
    neg("neg:heading-off", ["--heading", "--no-heading"])  # inline path:line
    neg("neg:no-filename", ["-H", "--no-filename"])
    neg("neg:no-line-number", ["-n", "--no-line-number"])
    neg("neg:no-stats", ["--stats", "--no-stats"])  # suppresses the timing summary

    # ── one-file-system: a single-fs tree must be pruned identically to no flag ──
    tree("one-file-system", ["--sort", "path", "--one-file-system", "-n", "MATCH"])

    # ── global core.excludesFile: honored by default, disabled by the flag ──
    def repo(name, args, env):
        cs.append(Case(name, args, "repo", FIX, env=env))

    repo("global:honored", ["--sort", "path", "-n", "MATCH"], gi_env)
    repo("global:disabled", ["--sort", "path", "--no-ignore-global", "-n", "MATCH"], gi_env)
    # sanity: with no global config the .log is visible even without the flag.
    repo("global:absent", ["--sort", "path", "-n", "MATCH"], base_env)

    return cs


def _repo_cases() -> list[Case]:
    """Repo-scale ordering over a real subtree — exercises the persisted index."""
    env = {**os.environ}
    return [
        Case(
            "repo:sort-path",
            ["--sort", "path", "-n", "-H", "TODO"],
            "services/backend",
            REPO,
            env=env,
        ),
        Case(
            "repo:sortr-path", ["--sortr", "path", "-l", "func"], "services/backend", REPO, env=env
        ),
        Case(
            "repo:sort-modified",
            ["--sort", "modified", "-l", "WalletService"],
            "services/backend/api",
            REPO,
            env=env,
        ),
    ]


# ───────────────────────── differential run ─────────────────────────


def _engine_env(env: dict[str, str], serial: bool) -> dict[str, str]:
    e = {**env}
    if serial:
        e["GIST_NO_PARALLEL"] = "1"
    else:
        e.pop("GIST_NO_PARALLEL", None)
    return e


def _diff_engine(cases: list[Case], *, serial: bool) -> tuple[list[str], list[str]]:
    """Replay every case on one engine; return (parity fails, index-safety fails)."""
    fails: list[str] = []
    idx_fails: list[str] = []
    for c in cases:
        argv = [*c.args, c.path]
        env = _engine_env(c.env, serial)
        g = run(GIST, [*argv, "--no-index"], c.cwd, env)
        r = run(RG, argv, c.cwd, c.env)
        gn, rn = _norm(g.data, c.sort_lines), _norm(r.data, c.sort_lines)
        if g.rc != r.rc:
            fails.append(f"{c.name}: EXIT gist={g.rc} rg={r.rc}  argv={argv}")
        if gn != rn:
            fails.append(f"{c.name}: STDOUT diverges  argv={argv}\n" + _mini_diff(gn, rn))
        if c.index_safe:
            gi = run(GIST, argv, c.cwd, env)
            if _norm(gi.data, c.sort_lines) != gn:
                idx_fails.append(f"{c.name}: indexed != --no-index  argv={argv}")
    return fails, idx_fails


def _thread_invariance(*, serial: bool) -> list[str]:
    """`-j` must not change results: gist -j1 == gist -jN, and each matches rg's set."""
    fails: list[str] = []
    env = _engine_env({**os.environ}, serial)
    argv = ["MATCH", "tree"]
    ref = _norm(run(GIST, [*argv, "-j", "1", "--no-index"], FIX, env).data, True)
    for j in ("2", "8"):
        got = _norm(run(GIST, [*argv, "-j", j, "--no-index"], FIX, env).data, True)
        if got != ref:
            fails.append(f"threads:j{j}: gist -j{j} != gist -j1")
    rg_set = _norm(run(RG, argv, FIX, {**os.environ}).data, True)
    if ref != rg_set:
        fails.append("threads: gist -j1 set != rg set")
    return fails


def do_run(engine: str) -> int:
    """Run the differential slate on the requested engine(s); 1 on any failure."""
    base_env, gi_env = gen_fixtures(FIX)
    cases = _cases(base_env, gi_env) + _repo_cases()
    engines = (
        [("parallel", False), ("serial", True)]
        if engine == "both"
        else [(engine, engine == "serial")]
    )
    total = 0
    for label, serial in engines:
        fails, idx_fails = _diff_engine(cases, serial=serial)
        fails += _thread_invariance(serial=serial)
        n = len(cases) + 3
        print(f"\n=== flags differential [{label}]: {n} cases ===")
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


def _mini_diff(a: bytes, b: bytes, ctx: int = 3) -> str:
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

    def dec(xs: list[bytes], k: int) -> str:
        return xs[k].decode("utf-8", "replace") if k < len(xs) else "<EOF>"

    lines = [f"  first diff at line {i} (gist={len(al)} rg={len(bl)}):"]
    for k in range(max(0, i - ctx), i + ctx + 1):
        mark = ">>" if k == i else "  "
        lines.append(f"  {mark} g| {dec(al, k)}")
        lines.append(f"  {mark} r| {dec(bl, k)}")
    return "\n".join(lines)


# ───────────────────────── bench (parity-at-speed hunt) ─────────────────────────


def do_bench() -> int:
    """Time gist-idx vs gist-noidx vs rg for the ordering + threading paths (report-only)."""
    sub = "services/backend"
    print(f"\n=== flags bench over {sub} (median of 3, report-only) ===")
    print(f"{'query':<26} {'gist-idx':>10} {'gist-noidx':>11} {'rg':>8}")
    queries = [
        ("--sort path", ["--sort", "path", "-l", "func", sub]),
        ("--sortr modified", ["--sortr", "modified", "-l", "func", sub]),
        ("-j1 func", ["-j", "1", "-l", "func", sub]),
        ("-j8 func", ["-j", "8", "-l", "func", sub]),
    ]
    for name, args in queries:
        gi = _median(GIST, args)
        gn = _median(GIST, [*args, "--no-index"])
        rr = _median(RG, args)
        print(f"{name:<26} {gi * 1e3:>9.1f}m {gn * 1e3:>10.1f}m {rr * 1e3:>7.1f}m")
    return 0


def _median(bin_: str, args: list[str]) -> float:
    """Median of 3 wall-clock timings of `bin_ args` from the repo root (inf on timeout)."""
    ts = []
    for _ in range(3):
        t0 = time.perf_counter()
        try:
            run(bin_, args, REPO, {**os.environ})
        except subprocess.TimeoutExpired:
            return float("inf")
        ts.append(time.perf_counter() - t0)
    ts.sort()
    return ts[1]


def main() -> int:
    """CLI entry: `run [--engine both|parallel|serial]` or `bench`."""
    global GIST, FIX
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run")
    pr.add_argument("--engine", default="both", choices=["both", "parallel", "serial"])
    sub.add_parser("bench")
    a = ap.parse_args()

    FIX = Path(tempfile.mkdtemp(prefix="gist-rgflags-"))
    atexit.register(lambda: shutil.rmtree(FIX, ignore_errors=True))
    GIST = _find_gist()
    print(f"gist={GIST}\nrg={RG}")
    if a.cmd == "run":
        return do_run(a.engine)
    if a.cmd == "bench":
        gen_fixtures(FIX)
        return do_bench()
    return 0


if __name__ == "__main__":
    sys.exit(main())
