#!/usr/bin/env python3
"""gist ⇄ ripgrep differential proof for the `-U`/`-P` modes rgsuite marks NA/SKIP.

`run.py` replays ripgrep's *own* mined suite, but by design defers `-U`/`--multiline`
(boundary #1) and `-P`/`--pcre2` (boundary #6) to NA/SKIP. This is the hand-authored
companion that certifies exactly those two modes now that gist implements them: it
compares `gist <args>` against `rg <args>` — ripgrep the ground truth, no hardcoded
expected strings — across a flag matrix on synthetic edge-case fixtures (byte-exact)
and the real Billy tree (order-normalized), diffing stdout + exit codes, and asserting
the indexed path equals `--no-index` (read-elision soundness). `bench` times both to
hunt acceleration wins.

stdlib-only. Fixtures are generated into a temp dir each run (the generator here is the
committed contract), so nothing large or machine-specific is tracked.

Subcommands: run [--mode all|multiline|pcre|core] | bench
"""

from __future__ import annotations

import argparse
import atexit
from dataclasses import dataclass
import json
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


def _find_gist() -> str:
    """Resolve the gist ReleaseFast binary — `GIST_BIN` override, else build it."""
    if env := os.environ.get("GIST_BIN"):
        return env
    # The suite drives the ReleaseFast CLI (matching bench/gates/line_parity.sh).
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
    """One command run: exit code, captured stdout bytes, and wall-clock time."""

    rc: int
    data: bytes
    secs: float


def run(bin_: str, args: list[str], cwd: Path, stdin: bytes | None = None) -> Out:
    """Run `bin_ args` in `cwd` (stderr suppressed), capturing stdout + rc + secs."""
    t0 = time.perf_counter()
    p = subprocess.run(
        [bin_, *args],
        cwd=str(cwd),
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=90,
    )
    return Out(p.returncode, p.stdout, time.perf_counter() - t0)


# ───────────────────────── output normalization ─────────────────────────


def _canon_json(data: bytes) -> bytes:
    """Parse rg/gist JSON-lines, drop nondeterministic timing, sort records."""
    recs = []
    for ln in data.split(b"\n"):
        if not ln.strip():
            continue
        try:
            obj = json.loads(ln)
        except json.JSONDecodeError:
            recs.append(("_raw", ln.decode("utf-8", "replace")))
            continue
        _strip_durations(obj)
        recs.append((obj.get("type", ""), json.dumps(obj, sort_keys=True)))
    # begin/end/match/context order within a file is meaningful; sort by the
    # whole tuple so cross-file interleave (parallel walk) doesn't create diffs.
    recs.sort()
    return "\n".join(r[1] for r in recs).encode()


def _strip_durations(obj: object) -> None:
    """Recursively drop the nondeterministic timing fields from a JSON record."""
    if isinstance(obj, dict):
        for k in ("elapsed_total", "elapsed", "stats"):
            obj.pop(k, None)
        for v in obj.values():
            _strip_durations(v)
    elif isinstance(obj, list):
        for v in obj:
            _strip_durations(v)


def normalize(o: Out, *, is_json: bool, sort_lines: bool) -> bytes:
    """Canonicalize stdout for comparison: JSON-canon, optional line-sort, else raw."""
    if is_json:
        return _canon_json(o.data)
    if sort_lines:
        return b"\n".join(sorted(o.data.split(b"\n")))
    return o.data


# ───────────────────────── fixtures ─────────────────────────


def gen_fixtures(root: Path) -> None:
    """Write the synthetic edge-case fixtures (this generator is the committed contract)."""
    root.mkdir(parents=True, exist_ok=True)

    def w(name: str, b: bytes) -> None:
        (root / name).write_bytes(b)

    w("simple.txt", b"alpha\nbeta gamma\ndelta\nEPSILON zeta\n")
    # cross-line spans
    w("multi.txt", b"start here\nfoo\nbar\nEND here\nfoo again END\nopen{\n  body line\n}close\n")
    w("blocks.txt", b"BEGIN\nx\ny\nEND\nBEGIN\nz\nEND\nBEGIN no end\n")
    # CRLF
    w("crlf.txt", b"one\r\ntwo\r\nthree END\r\nfour\r\n")
    # BOM + utf8
    w("bom.txt", b"\xef\xbb\xbffirst\nsecond match\n")
    # NUL / binary
    w("binary.bin", b"prefix match\x00after nul match\n")
    # invalid utf-8
    w("badutf.txt", b"good line\n\xff\xfe raw bytes match\ntail\n")
    # unicode
    w("unicode.txt", "café résumé\nΩmega Ω\nนก\n".encode("utf-8"))
    # NUL as line terminator (--null-data)
    w("nuldata.txt", b"reca match\x00recb\x00recc match END\x00")
    # zero-width friendly
    w("zw.txt", b"\n\naaa\n\nbbb\n\n")
    # a large-ish file to exercise the read cap + timing (>1 MiB, many hits)
    chunk = b"".join(
        (
            f"needle line {i} filler filler filler\n"
            f"otherwise plain {i} lorem ipsum dolor sit amet\n"
        ).encode()
        for i in range(40000)
    )
    w("big.txt", chunk)
    # dotall target: braces spanning many lines
    w("json_like.txt", b'{\n  "a": 1,\n  "b": [1,2,3],\n  "c": {"d": 4}\n}\ntrailer\n')
    # PCRE-only surface: backrefs, lookaround, repeated words, anchors
    w("pcre.txt", b"foofoo\nfoobar\nba\nhello hello\nabcabc\nbeta gamma\n")
    # catastrophic backtracking: 30 'a's then a non-'a' — `(a+)+$` blows PCRE2's
    # match limit (rg exits 2), while possessive/atomic forms terminate at once.
    w("catastrophic.txt", b"a" * 30 + b"X\n")


# ───────────────────────── case matrix ─────────────────────────


@dataclass
class Case:
    """One differential case: shared argv + fixture path + comparison knobs."""

    name: str
    args: list[str]  # argv shared by gist + rg (pattern + flags), path appended
    path: str  # relative to cwd
    cwd: Path = REPO
    stdin: bytes | None = None
    sort_lines: bool = False
    is_json: bool = False


# presentation flags applied on top of a base (pattern, path) case
PRESENT = [
    [],
    ["-n"],
    ["-H"],
    ["-n", "-H"],
    ["-o"],
    ["-c"],
    ["--count-matches"],
    ["-l"],
    ["--files-without-match"],
    ["-w"],
    ["-v"],
    ["-i"],
    ["-A", "1"],
    ["-B", "1"],
    ["-C", "2"],
    ["--column"],
    ["-b"],
    ["-m", "2"],
    ["-n", "--column", "-b"],
    ["--json"],
]


def _fix_cases(mode: str) -> list[Case]:
    """The curated adversarial fixture cases for `mode` (multiline/pcre/core)."""
    cs: list[Case] = []

    def add(name, args, path, **kw):
        cs.append(Case(name, args, path, cwd=FIX, **kw))

    if mode in ("all", "core"):
        for pf in PRESENT:
            j = "--json" in pf
            add(f"core:lit{pf}", ["match", *pf], "simple.txt", is_json=j)
            add(f"core:re{pf}", [r"\bmatch\b", *pf], "multi.txt", is_json=j)
        add("core:crlf", ["--crlf", "-n", "END$"], "crlf.txt")
        add("core:bom", ["-n", "match"], "bom.txt")
        add("core:badutf", ["-n", "match"], "badutf.txt")
        add("core:nuldata", ["--null-data", "-o", "match"], "nuldata.txt")
        add("core:unicode", ["-n", "Ω"], "unicode.txt")
        add("core:replace", ["-r", "R[$0]", "match"], "simple.txt")
        cs.append(
            Case(
                "core:stdin", ["-n", "beta"], "-", cwd=FIX, stdin=(FIX / "simple.txt").read_bytes()
            )
        )

    if mode in ("all", "multiline"):
        for pf in [
            [],
            ["-n"],
            ["-H", "-n"],
            ["-o"],
            ["-c"],
            ["--count-matches"],
            ["-b"],
            ["--column"],
            ["-A", "1"],
            ["--json"],
            ["-v"],
        ]:
            j = "--json" in pf
            add(f"ml:span{pf}", ["-U", r"foo\nbar", *pf], "multi.txt", is_json=j)
            add(f"ml:block{pf}", ["-U", r"BEGIN[\s\S]*?END", *pf], "blocks.txt", is_json=j)
        add("ml:dotall", ["-U", "--multiline-dotall", r"\{.*\}"], "json_like.txt")
        add("ml:dotall-o", ["-U", "--multiline-dotall", "-o", r"\{.*\}"], "json_like.txt")
        add("ml:crlf", ["-U", "-n", r"two\r?\nthree"], "crlf.txt")
        add("ml:replace", ["-U", "-r", "<$0>", r"foo\nbar"], "multi.txt")
        add("ml:zerowidth", ["-U", "-o", r"^"], "zw.txt")
        add("ml:big", ["-U", "-c", r"needle line \d+\notherwise"], "big.txt")

    if mode in ("all", "pcre"):
        for pf in [[], ["-n"], ["-o"], ["-c"], ["--count-matches"], ["-H", "-n"], ["--json"]]:
            j = "--json" in pf
            add(f"pcre:lookahead{pf}", ["-P", r"match(?= gamma)", *pf], "simple.txt", is_json=j)
            add(f"pcre:backref{pf}", ["-P", r"(\w+) \1", *pf], "simple.txt", is_json=j)
        add("pcre:lookbehind", ["-P", "-o", r"(?<=beta )\w+"], "simple.txt")
        add("pcre:named", ["-P", "-o", r"(?P<w>\w+)\s+(?P=w)"], "simple.txt")
        add("pcre:badutf", ["-P", "-n", "match"], "badutf.txt")
        add("pcre:combined-U", ["-P", "-U", "-o", r"foo\nbar"], "multi.txt")
        # negative lookaround: exclude the excluded context, keep the rest
        add("pcre:neg-lookahead", ["-P", "-o", r"foo(?!bar)"], "pcre.txt")
        add("pcre:neg-lookbehind", ["-P", "-o", r"(?<!foo)bar"], "pcre.txt")
        # PCRE-only quantifier forms — must parse and match/anchor like rg's PCRE2
        add("pcre:possessive", ["-P", "-o", r"a++X"], "catastrophic.txt")
        add("pcre:atomic", ["-P", r"(?>a+)a"], "catastrophic.txt")  # atomic ⇒ no match (rc 1)
        # catastrophic backtracking: rg surfaces PCRE2's match-limit as exit 2 —
        # gist's `-P` must map the same limit to the same exit, never a hang.
        add("pcre:catastrophic", ["-P", r"(a+)+$"], "catastrophic.txt")
        # Unicode mode on (default) vs byte mode (--no-pcre2-unicode)
        add("pcre:unicode-prop", ["-P", "-o", r"\p{L}+"], "unicode.txt")
        add("pcre:byte-word", ["-P", "--no-pcre2-unicode", "-o", r"\w+"], "unicode.txt")
        # caseless, anchors, word boundary, and replace-with-backref
        add("pcre:caseless", ["-P", "-i", "-o", "BETA"], "simple.txt")
        add("pcre:anchors", ["-P", "-n", r"^\w+$"], "simple.txt")
        add("pcre:wordbound", ["-P", "-o", r"\bbeta\b"], "simple.txt")
        add("pcre:replace-backref", ["-P", "-o", "-r", "<$1>", r"(\w+)\1"], "pcre.txt")
    return cs


def _repo_cases(mode: str) -> list[Case]:
    """Large, gross recursive queries over real subtrees (order-normalized)."""
    cs: list[Case] = []
    subtree = "services/backend"

    def add(name, args, **kw):
        cs.append(Case(name, args, subtree, cwd=REPO, sort_lines=True, **kw))

    if mode in ("all", "core"):
        add("repo:func", [r"func \w+\(", "-n", "-H"])
        add("repo:count", [r"func \w+\(", "-c", "-H"])
        add("repo:files", ["-l", "TODO"])
        add("repo:word", ["-w", "-n", "-H", "context"])
        add("repo:type", ["-n", "-H", "-tgo", "package"])
        add("repo:glob", ["-n", "-H", "-g", "*.go", "import"])
    if mode in ("all", "multiline"):
        add("repo:ml-import", ["-U", "-o", r"import \([\s\S]*?\)"])
        add("repo:ml-struct", ["-U", "-n", "-H", r"struct \{[\s\S]*?\}"])
    if mode in ("all", "pcre"):
        add("repo:pcre-look", ["-P", "-n", "-H", r"func \w+\((?=.*error)"])
    return cs


# ───────────────────────── differential run ─────────────────────────


def do_run(mode: str) -> int:
    """Run the differential slice for `mode`; return 1 on any parity/index-safety fail."""
    cases = _fix_cases(mode) + _repo_cases(mode)
    fails: list[str] = []
    idx_fails: list[str] = []
    ran = 0
    for c in cases:
        argv = [*c.args, c.path] if c.path != "-" else c.args
        try:
            g = run(GIST, [*argv, "--no-index"] if c.path != "-" else argv, c.cwd, c.stdin)
            r = run(RG, argv, c.cwd, c.stdin)
        except subprocess.TimeoutExpired:
            fails.append(f"{c.name}: TIMEOUT")
            continue
        ran += 1
        gn = normalize(g, is_json=c.is_json, sort_lines=c.sort_lines)
        rn = normalize(r, is_json=c.is_json, sort_lines=c.sort_lines)
        # exit-code parity: rg 0=match 1=nomatch 2=err; gist mirrors.
        if g.rc != r.rc:
            fails.append(f"{c.name}: EXIT gist={g.rc} rg={r.rc}  argv={argv}")
        if gn != rn:
            fails.append(f"{c.name}: STDOUT diverges  argv={argv}\n" + _mini_diff(gn, rn))
        # index-safety: indexed must equal --no-index (skip stdin cases).
        if c.path != "-":
            gi = run(GIST, argv, c.cwd, c.stdin)
            gin = normalize(gi, is_json=c.is_json, sort_lines=c.sort_lines)
            if gin != gn:
                idx_fails.append(f"{c.name}: indexed != --no-index  argv={argv}")

    print(f"\n=== differential [{mode}]: {ran} cases ===")
    if not fails and not idx_fails:
        print("✓ ALL PASS — gist == rg (stdout + exit) and indexed == --no-index")
        return 0
    for f in fails:
        print("✗ " + f)
    for f in idx_fails:
        print("⚠ INDEX " + f)
    print(f"\n{len(fails)} parity fail(s), {len(idx_fails)} index-safety fail(s)")
    return 1


def _mini_diff(a: bytes, b: bytes, ctx: int = 4) -> str:
    """Render the first stdout divergence between gist and rg with a little context."""
    al = a.split(b"\n")
    bl = b.split(b"\n")
    # first differing index (the actionable point), with a little context.
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
    lo = max(0, i - ctx)
    dec = lambda xs, k: xs[k].decode("utf-8", "replace") if k < len(xs) else "<EOF>"
    out = [f"  first diff at line {i} (gist={len(al)} lines, rg={len(bl)} lines):"]
    for k in range(lo, i + ctx + 1):
        mark = ">>" if k == i else "  "
        out.append(f"  {mark} g| {dec(al, k)}")
        out.append(f"  {mark} r| {dec(bl, k)}")
    return "\n".join(out)


# ───────────────────────── bench (acceleration hunt) ─────────────────────────


def do_bench() -> int:
    """Time gist-idx vs gist-noidx vs rg across the acceleration query matrix."""
    subtree = "services"
    queries = [
        ("literal-rare", ["WalletService"]),
        ("literal-common", ["error"]),
        ("regex-anchored", [r"func \w+\("]),
        # -U/-P over a COMMON literal: little to prune, so this is a raw
        # match-throughput contest (gist parallel vs rg parallel).
        ("multiline-import", ["-U", r"import \([\s\S]*?\)"]),
        ("pcre-look", ["-P", r"func \w+\((?=.*ctx)"]),
        # -U/-P over a RARE literal: the index elides ~every non-candidate read,
        # so gist answers a backreference/lookaround/cross-line query by touching
        # a handful of files where rg must walk + PCRE-match the whole subtree.
        ("pcre-rare-look", ["-P", r"WalletService(?=[\s\S]*ctx)"]),
        ("multiline-rare", ["-U", r"WalletService[\s\S]{0,80}?\{"]),
    ]
    print(f"\n=== bench over {subtree} (median of 3) ===")
    print(f"{'query':<20} {'gist-idx':>10} {'gist-noidx':>11} {'rg':>8}")
    for name, args in queries:
        gi = _median(GIST, [*args, "-c", subtree])
        gn = _median(GIST, [*args, "-c", "--no-index", subtree])
        rr = _median(RG, [*args, "-c", subtree])
        print(f"{name:<20} {gi * 1e3:>9.1f}m {gn * 1e3:>10.1f}m {rr * 1e3:>7.1f}m")
    return 0


def _median(bin_: str, args: list[str]) -> float:
    """Median of 3 wall-clock timings of `bin_ args` from the repo root (inf on timeout)."""
    ts = []
    for _ in range(3):
        try:
            ts.append(run(bin_, args, REPO).secs)
        except subprocess.TimeoutExpired:
            return float("inf")
    ts.sort()
    return ts[1]


def main() -> int:
    """CLI entry: `run --mode all|core|multiline|pcre` or `bench`."""
    global GIST, FIX
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run")
    pr.add_argument("--mode", default="all", choices=["all", "core", "multiline", "pcre"])
    sub.add_parser("bench")
    a = ap.parse_args()

    FIX = Path(tempfile.mkdtemp(prefix="gist-rgmodes-"))
    atexit.register(lambda: shutil.rmtree(FIX, ignore_errors=True))
    gen_fixtures(FIX)
    GIST = _find_gist()
    print(f"gist={GIST}\nrg={RG}")
    if a.cmd == "run":
        return do_run(a.mode)
    if a.cmd == "bench":
        return do_bench()
    return 0


if __name__ == "__main__":
    sys.exit(main())
