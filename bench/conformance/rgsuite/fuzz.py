#!/usr/bin/env python3
"""Differential fuzz: randomized (pattern x flags x corpus) triples, rg as oracle.

WHY A THIRD LANE
    `run.py` replays the cases ripgrep chose to write. `surface.py` probes the
    flags ripgrep chose to document. Both are denominators someone curated, and
    a curated denominator can only find bugs someone already thought about. This
    lane generates invocations nobody wrote down: a random pattern, a random
    composable flag set, and a corpus built to be hostile, then demands that
    `gist rg` and real `rg` agree byte-for-byte on stdout and exit code.

    Every published number here is a comparison against LIVE ripgrep. There is
    no expected-output table in this file, so there is nothing to bandaid: a
    divergence can only be resolved by changing gist or by proving the
    difference is one of the documented declines below.

WHAT IS NOT A DIVERGENCE
    declined      gist's linear-time engine refuses a construct outside its
                  guaranteed-linear syntax (lookaround, backreferences, `(?x)`)
                  and exits 2 pointing at `-P` — the same judgment `run.py`
                  scores NA, recognized by `_oracle.is_design_decline`.
    malformed     the generated pattern is invalid in EVERY grammar gist has
                  (it asked PCRE2 too) and gist exits 2, while rg answers — but
                  rg answers only because it wraps each pattern in `(?:...)`,
                  which pairs a stray paren of the generator's with one of its
                  own: `)(` becomes `(?:)()`, matching empty everywhere. rg is
                  not demonstrating a grammar gist lacks; it is searching for
                  something nobody asked for. Recognized by
                  `_oracle.is_malformed_refusal`, and kept apart from `declined`
                  because that one means "another tier could answer this".
    both_reject   the generated pattern is invalid for both engines and both
                  exit 2. Agreement on a rejection is agreement.
    declared      the argv holds a flag the gist catalog marks
                  `compatibility = .improvement`, and the difference passes that
                  boundary's residual check — the table and the residuals are
                  imported from `surface.py`, so this file cannot invent an
                  excuse of its own, and a boundary whose residual fails is
                  still counted as a divergence.

ROBUSTNESS IS MEASURED IN THE SAME PASS
    The corpora carry what maturity claims are really about: invalid UTF-8, NUL
    bytes, CRLF, a 4 MiB single line, 100k-line files, deep nesting, a symlink
    loop, an unreadable file, an empty file. Each child gets a hard timeout, and
    peak child RSS is sampled from `getrusage` so "bounded memory" is a
    measurement rather than a hope. A crash, a hang, or an unbounded RSS is a
    hard failure exactly like a byte divergence.

Usage
    python3 bench/rgsuite/fuzz.py                              # 500 iterations
    python3 bench/rgsuite/fuzz.py --iterations 5000 --seed 7
    python3 bench/rgsuite/fuzz.py --json OUT.json              # Layer I record
    python3 bench/rgsuite/fuzz.py --corpus dirty --verbose      # one corpus
"""

from __future__ import annotations

import argparse
from collections import Counter
import contextlib
import json
import os
from pathlib import Path
import random
import resource
import shlex
import shutil
import subprocess
import sys
import tempfile

import _oracle
import surface

GIST = str(_oracle.GIST)
RG = _oracle.RG

# macOS reports ru_maxrss in bytes, Linux in kibibytes.
_RSS_DIV = 1 << 20 if sys.platform == "darwin" else 1 << 10


# ── corpora ───────────────────────────────────────────────────────────────────
# Each builder writes one tree. They are built once per session and reused by
# every iteration, so a divergence is reproducible from (seed, iteration) alone.
def _plain(root: Path) -> None:
    """Ordinary source-shaped text, plus the ignore boundary."""
    (root / "src").mkdir()
    (root / "src" / "main.rs").write_text(
        "fn main() {\n    let mut n = 0usize;\n    // TODO: fix panic\n"
        "    for i in 0..10 { n += i; }\n    println!(\"{n}\");\n}\n"
    )
    (root / "src" / "lib.go").write_text(
        "package lib\n\nfunc Handle(ctx context.Context) error {\n"
        "\treturn nil // 0xDEADBEEF\n}\n\nfunc helper() {}\n"
    )
    (root / "app.py").write_text(
        "import os\n\n\ndef run(path):\n    return os.stat(path)\n\n\nclass Runner:\n    pass\n"
    )
    (root / "notes.md").write_text("# notes\n\nsee `Handle` and *panic* handling.\n\n\n")
    (root / ".gitignore").write_text("build/\n*.log\n")
    (root / "build").mkdir()
    (root / "build" / "out.rs").write_text("fn generated() {}\n")
    (root / "debug.log").write_text("panic at 0x41\n")
    (root / ".hidden.rs").write_text("fn hidden() { panic!() }\n")


def _unicode(root: Path) -> None:
    """Multi-byte, combining marks, and case-folding pairs the -i path must fold."""
    (root / "greek.txt").write_text("ΣΊΣΥΦΟΣ\nσίσυφος\nΣίσυφος\nfinal ς here\n")
    (root / "cjk.txt").write_text("日本語のテキスト\n漢字とかな\nfn 関数()\n")
    (root / "combining.txt").write_text("cafe\u0301 vs caf\u00e9\ne\u0301clair\n")
    (root / "emoji.txt").write_text("panic 🔥 here\n🚀🚀🚀\n")
    (root / "turkish.txt").write_text("İstanbul\nistanbul\nIstanbul\nı dotless\n")


def _dirty(root: Path) -> None:
    """Invalid UTF-8, CRLF, missing trailing newline, lone CR."""
    (root / "lone_cont.txt").write_bytes(b"valid\n\x80\x81 panic \xfe\xff\nmore fn\n")
    (root / "truncated.txt").write_bytes(b"fn ok\n\xe6\x97 truncated\nfn after\n")
    (root / "crlf.txt").write_bytes(b"fn one\r\nfn two\r\nfn three\r\n")
    (root / "mixed.txt").write_bytes(b"fn a\nfn b\r\nfn c\rfn d\n")
    (root / "no_eol.txt").write_bytes(b"fn last line has no newline")
    (root / "bom.txt").write_bytes(b"\xef\xbb\xbffn after bom\n")


def _binary(root: Path) -> None:
    """NUL-bearing and high-entropy files — the binary-detection boundary."""
    (root / "early_nul.bin").write_bytes(b"fn visible\n\x00\x01\x02 fn hidden\n")
    (root / "late_nul.bin").write_bytes(b"fn one\n" * 200 + b"\x00fn after nul\n")
    (root / "elf.bin").write_bytes(b"\x7fELF\x02\x01\x01\x00" + bytes(range(256)) * 4)
    (root / "nul_only.bin").write_bytes(b"\x00" * 4096)
    (root / "plain.txt").write_text("fn ordinary\n")


def _giant(root: Path) -> None:
    """One very long line, one very tall file, one empty file."""
    (root / "long_line.txt").write_bytes(b"fn " + b"x" * (4 << 20) + b" panic\n")
    (root / "tall.txt").write_text("".join(f"fn line{i}\n" for i in range(100_000)))
    (root / "empty.txt").write_bytes(b"")
    (root / "one_byte.txt").write_bytes(b"f")


def _hostile(root: Path) -> None:
    """Deep nesting, a symlink loop, a broken symlink, an unreadable file."""
    deep = root
    for i in range(24):
        deep = deep / f"d{i}"
        deep.mkdir()
    (deep / "bottom.rs").write_text("fn bottom() { panic!() }\n")
    (root / "top.rs").write_text("fn top() {}\n")
    (root / "loop").symlink_to(root)  # a cycle --follow must survive
    (root / "dangling").symlink_to(root / "nowhere.rs")
    unreadable = root / "unreadable.rs"
    unreadable.write_text("fn secret() {}\n")
    unreadable.chmod(0o000)  # unlinkable during cleanup: only the dir bit matters


CORPORA = {
    "plain": _plain,
    "unicode": _unicode,
    "dirty": _dirty,
    "binary": _binary,
    "giant": _giant,
    "hostile": _hostile,
}


# ── pattern generation ────────────────────────────────────────────────────────
# Literals lifted from the corpora so a good fraction of iterations actually
# match something; a fuzzer that only ever produces empty results proves the
# walk agrees and nothing about the emit path.
SEEDS = [
    "fn",
    "panic",
    "Handle",
    "context.Context",
    "0x",
    "TODO",
    "line1",
    "σίσυφος",
    "日本語",
    "İstanbul",
    "café",
    "🔥",
    "nowhere",
    "generated",
]
_ATOMS = [
    r"\w",
    r"\d",
    r"\s",
    r"\S",
    r"\b",
    ".",
    "[a-z]",
    "[A-Za-z_]",
    "[^ ]",
    "[0-9a-f]",
    r"\.",
    "fn",
    "0x",
    "panic",
    "x",
]
_QUANT = ["", "*", "+", "?", "{1,3}", "{2}", "{2,}"]
# Patterns whose backtracking behavior is the point: rg's PCRE2 path can be made
# to blow up on these, gist's linear engine cannot. Kept in the pool so the
# claim "gist does not surprise you" is exercised, not asserted.
_PATHOLOGICAL = [r"(a+)+$", r"(x|x)*y", r"(\w+\s?)+$", r"(a|aa)+$", r"([a-z]+)*!"]


def make_pattern(rng: random.Random) -> str:
    """A random pattern: a corpus literal, a generated regex, or a known trap."""
    roll = rng.random()
    if roll < 0.35:
        return rng.choice(SEEDS)
    if roll < 0.42:
        return rng.choice(_PATHOLOGICAL)
    if roll < 0.50:  # a literal with regex metacharacters, for the -F path
        return rng.choice(SEEDS) + rng.choice(["(", ")", "[", "]", "\\", "*", "+", "$", "^", "|"])
    parts = []
    for _ in range(rng.randint(1, 4)):
        atom = rng.choice(_ATOMS)
        if rng.random() < 0.2:
            atom = "(" + atom + rng.choice(_QUANT) + "|" + rng.choice(_ATOMS) + ")"
        parts.append(atom + rng.choice(_QUANT))
    pat = "".join(parts)
    if rng.random() < 0.12:
        pat = "^" + pat
    if rng.random() < 0.12:
        pat += "$"
    if rng.random() < 0.10:
        pat = "(?i)" + pat
    return pat


# ── flag generation ───────────────────────────────────────────────────────────
# Only flags whose output is a deterministic function of the corpus. Excluded by
# construction: color (a declared palette boundary, scored in surface.py), the
# lifecycle/identity flags (each tool names itself), `--threads` and the sort
# flags (they choose an order, and `--sort path` is injected below so every
# comparison is a sequence rather than a scheduling accident), and `--pre`/`-z`
# (they hand the search to an external program, not to the engine under test).
_SOLO = [
    "-i",
    "-S",
    "-s",
    "-w",
    "-x",
    "-v",
    "-F",
    "-U",
    "-n",
    "-N",
    "--column",
    "-b",
    "--null",
    "-o",
    "-c",
    "-l",
    "--files-without-match",
    "--count-matches",
    "-H",
    "-I",
    "--heading",
    "--no-heading",
    "--vimgrep",
    "-a",
    "--binary",
    "--crlf",
    "--hidden",
    "--no-ignore",
    "--no-ignore-vcs",
    "--no-ignore-dot",
    "--follow",
    "--one-file-system",
    "--mmap",
    "--no-mmap",
    "--no-unicode",
    "--stats",
    "--json",
    "--trim",
    "--include-zero",
    "--no-require-git",
    "--max-columns-preview",
    "--invert-match",
    "--line-number",
    "--with-filename",
    "--byte-offset",
    "-P",
    "-uu",
]
_VALUED = [
    ("-A", ["1", "2"]),
    ("-B", ["1", "2"]),
    ("-C", ["1", "3"]),
    ("-M", ["10", "40"]),
    ("-m", ["1", "3"]),
    ("--max-depth", ["1", "3", "30"]),
    ("--max-filesize", ["1K", "8M"]),
    ("-r", ["X", "[$0]"]),
    ("-g", ["*.rs", "!*.txt", "**/d*/**"]),
    ("--iglob", ["*.RS"]),
    ("-t", ["rust", "py"]),
    ("-T", ["md"]),
    ("--context-separator", ["--", ""]),
    ("--field-match-separator", ["|"]),
    ("--encoding", ["utf-8", "none"]),
    ("--engine", ["default", "auto"]),
    ("--path-separator", ["/"]),
    ("--regex-size-limit", ["10M"]),
]
# Pairs that cannot be sampled together: rg rejects the combination, so drawing
# both would only ever measure two identical usage errors.
_CONFLICTS = [
    {"-c", "-l"},
    {"-c", "-o"},
    {"-l", "-o"},
    {"-c", "--files-without-match"},
    {"-l", "--files-without-match"},
    {"-o", "--files-without-match"},
    {"-c", "--count-matches"},
    {"--count-matches", "-l"},
    {"--count-matches", "-o"},
    {"--heading", "--no-heading"},
    {"--mmap", "--no-mmap"},
    {"-F", "-P"},
    {"-F", "-U"},
    {"-x", "-o"},
    {"--json", "-c"},
    {"--json", "-l"},
    {"--json", "--vimgrep"},
    {"--json", "--stats"},
    {"--json", "-o"},
    {"--json", "--count-matches"},
    {"--json", "--files-without-match"},
    {"-P", "--no-unicode"},
    {"-P", "--engine"},
    {"-F", "--engine"},
    {"-U", "--engine"},
    {"-v", "-o"},
    {"-v", "--count-matches"},
]


def make_flags(rng: random.Random) -> list[str]:
    """A random composable flag set, `--sort path` injected for determinism."""
    chosen: list[str] = []
    names: set[str] = set()

    def admits(name: str) -> bool:
        return not any(pair <= (names | {name}) for pair in _CONFLICTS)

    for _ in range(rng.randint(0, 4)):
        f = rng.choice(_SOLO)
        if f not in names and admits(f):
            names.add(f)
            chosen.append(f)
    for _ in range(rng.randint(0, 2)):
        f, values = rng.choice(_VALUED)
        if f not in names and admits(f):
            names.add(f)
            chosen += [f, rng.choice(values)]
    return ["--sort", "path", *chosen]


# ── the differential ──────────────────────────────────────────────────────────
def _rss_mb() -> float:
    """Peak RSS watermark across all children so far, in MiB."""
    return resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / _RSS_DIV


def compare(argv: list[str], cwd: str, watermark: dict[str, float]) -> dict:
    """Run both binaries on identical bytes; classify agreement or divergence."""
    before = _rss_mb()
    rc_rg, out_rg, _ = _oracle.run([RG, "--path-separator", "/", *argv], cwd, None)
    mid = _rss_mb()
    rc_g, out_g, err_g = _oracle.run([GIST, "rg", *argv], cwd, None)
    after = _rss_mb()
    # ru_maxrss is a monotone max over all children, so a rise is attributable to
    # the child that caused it. Only a rise is attributed — never a guess.
    if mid > before:
        watermark["rg"] = max(watermark["rg"], mid)
    if after > mid:
        watermark["gist"] = max(watermark["gist"], after)

    a = _oracle.norm_json(_oracle.norm_time(out_rg))
    b = _oracle.norm_json(_oracle.norm_time(out_g))
    if rc_rg == rc_g and a == b:
        return {"verdict": "agree"}
    if 124 in (rc_rg, rc_g):
        # Attribute the wall to the binary that hit it. rg timing out where gist
        # finished is not a gist robustness failure, and folding the two into one
        # "timeout" hides which tool was slow.
        return {"verdict": "timeout", "klass": "timeout-rg" if rc_rg == 124 else "timeout-gist", "rc": [rc_rg, rc_g]}
    if rc_g == 2 and _oracle.is_design_decline(err_g):
        return {"verdict": "declined", "why": err_g.decode(errors="replace").strip()[:120]}
    if rc_g == 2 and _oracle.is_malformed_refusal(err_g):
        return {"verdict": "malformed", "why": err_g.decode(errors="replace").strip()[:120]}
    if rc_rg == 2 and rc_g == 2:
        return {"verdict": "both_reject"}
    if rc_g < 0 or rc_rg < 0:  # killed by a signal
        return {"verdict": "crash", "klass": "crash-rg" if rc_rg < 0 else "crash-gist", "rc": [rc_rg, rc_g]}
    if (declared := _declared_boundary(argv, rc_rg, rc_g, a, b)) is not None:
        return declared
    return {
        "verdict": "divergent",
        "klass": _klass(rc_rg, rc_g, a, b),
        "rc": [rc_rg, rc_g],
        "bytes": [len(a), len(b)],
        "why": _first_diff(a, b) if a != b else f"exit {rc_rg} vs {rc_g}",
        "stderr": err_g.decode(errors="replace").strip()[:200],
    }


def _rg_version() -> str:
    """The oracle's own version string, or `?` when rg will not answer."""
    try:
        out = subprocess.run([RG, "--version"], capture_output=True, text=True).stdout
        return out.split("\n", 1)[0].replace("ripgrep ", "").strip() or "?"
    except OSError:
        return "?"


def _klass(rc_rg: int, rc_g: int, a: bytes, b: bytes) -> str:
    """A stable, observable class for one divergence, derived from the outputs alone.

    A total is the wrong thing to ratchet on its own: it lets a newly-introduced
    defect hide inside a count that another fix happened to lower by the same
    amount. Classing every divergence by the SHAPE of the disagreement — and
    deriving that shape from the two byte streams rather than from the argv that
    produced them — gives the certificate a per-class floor that a new root cause
    cannot slip under, while staying stable across seeds and iteration counts.
    """
    if a == b:
        return "exit-code"  # byte-identical output, different verdict
    la, lb = a.splitlines(), b.splitlines()
    shape = (
        "line-count"
        if len(la) != len(lb)
        else "line-content"
        if la != lb
        # `splitlines` agrees but the raw bytes do not: a terminator difference.
        else "trailing-bytes"
    )
    return f"{shape}+exit" if rc_rg != rc_g else shape


def _declared_boundary(argv: list[str], rc_rg: int, rc_g: int, a: bytes, b: bytes) -> dict | None:
    """Is this difference one of `surface.py`'s CATALOGUED boundaries?

    The flag catalog marks a handful of options `compatibility = .improvement`
    (`--binary` prints every matching line of a NUL-bearing file where rg prints
    one opaque summary and stops). Scoring those as bugs would make the fuzzer
    demand that gist abandon a documented feature; scoring them as "agree" would
    let a real bug hide behind a flag name. So the boundary table is imported
    from `surface.py` — one owner, same reasons — and the difference must still
    pass that boundary's residual check (for `--binary`: same exit code, same set
    of paths reported) or it falls through and is counted as a divergence.
    """
    for flag in argv:
        kind, why = surface.BOUNDARIES.get(flag, (None, None))
        if kind and surface._residual_holds(kind, rc_rg, rc_g, a, b):
            return {"verdict": "declared", "flag": flag, "residual": kind, "why": why}
    return None


def _first_diff(a: bytes, b: bytes) -> str:
    la, lb = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return f"line {i + 1}: rg={x[:70]!r} gist={y[:70]!r}"
    return f"line count rg={len(la)} gist={len(lb)}"


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iterations", type=int, default=500)
    ap.add_argument("--seed", type=int, default=0x6E15, help="same seed family as the certificate")
    ap.add_argument("--corpus", choices=sorted(CORPORA), help="restrict to one corpus")
    ap.add_argument("--json", type=Path, help="write the machine record here")
    ap.add_argument(
        "--publish-baseline",
        type=Path,
        help="write this run's residual as the committed shrink-only floor "
        "(the MEASUREMENT publishes; the certificate gate only ever reads)",
    )
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--max-report", type=int, default=12, help="divergences to print in full")
    ap.add_argument(
        "--keep",
        type=Path,
        help="build the corpora here and leave them (a printed `cwd` stays reproducible for triage)",
    )
    args = ap.parse_args()

    if not shutil.which(RG):
        print("fuzz: ripgrep is not on PATH — it IS the oracle here", file=sys.stderr)
        return 2
    if not Path(GIST).exists():
        print(f"fuzz: no gist at {GIST} (zig build -Doptimize=ReleaseFast)", file=sys.stderr)
        return 2

    names = [args.corpus] if args.corpus else sorted(CORPORA)
    rng = random.Random(args.seed)
    tally: Counter[str] = Counter()
    watermark = {"gist": 0.0, "rg": 0.0}
    bad: list[dict] = []

    # `--keep` swaps the self-deleting temp dir for a caller-named one so the `cwd`
    # printed with a divergence is still there to cd into. The corpora are rebuilt
    # from scratch either way — a stale tree would silently change the oracle.
    with contextlib.ExitStack() as stack:
        if args.keep:
            shutil.rmtree(args.keep, ignore_errors=True)
            args.keep.mkdir(parents=True)
            tmp = str(args.keep)
        else:
            tmp = stack.enter_context(tempfile.TemporaryDirectory(prefix="gist-fuzz-"))
        roots = {}
        for name in names:
            root = Path(tmp) / name
            root.mkdir()
            CORPORA[name](root)
            roots[name] = str(root)

        for i in range(args.iterations):
            name = names[i % len(names)]
            pattern = make_pattern(rng)
            argv = [*make_flags(rng), "-e", pattern, "."]
            out = compare(argv, roots[name], watermark)
            tally[out["verdict"]] += 1
            if args.verbose:
                print(f"  {out['verdict']:<12} [{name}] {shlex.join(argv)}")
            if out["verdict"] in ("divergent", "crash", "timeout"):
                bad.append({"iteration": i, "corpus": name, "argv": argv, **out})
                if len(bad) <= args.max_report:
                    print(f"\n{out['verdict'].upper()} #{i} [{name}]")
                    print(f"  rg   : rg --path-separator / {shlex.join(argv)}")
                    print(f"  gist : gist rg {shlex.join(argv)}")
                    print(f"  cwd  : {roots[name]}")
                    print(f"  why  : {out.get('why', out.get('rc'))}")

        # A 0o000 file inside the tree is unlinkable (only the parent's write bit
        # matters), but be explicit so cleanup can never fail on a mode we set.
        for root in roots.values():
            for p in Path(root).rglob("*"):
                if p.is_file() and not os.access(p, os.R_OK):
                    p.chmod(0o644)

    total = sum(tally.values())
    print(
        f"\nfuzz: {total} iterations over {len(names)} corpora (seed {args.seed})"
        f"  ·  agree {tally['agree']}"
        f"  ·  declined {tally['declined']}"
        f"  ·  malformed {tally['malformed']}"
        f"  ·  declared {tally['declared']}"
        f"  ·  both-reject {tally['both_reject']}"
        f"  ·  divergent {tally['divergent']}"
        f"  ·  timeout {tally['timeout']}"
        f"  ·  crash {tally['crash']}"
    )
    print(
        f"peak child RSS watermark: gist {watermark['gist']:.1f} MiB · rg {watermark['rg']:.1f} MiB"
        "  (attributed only where a child raised the watermark)"
    )

    residual = Counter(f.get("klass", "unclassified") for f in bad)
    if residual:
        print("residual by class (what the certificate ratchets):")
        for klass, n in sorted(residual.items()):
            print(f"  {n:4d}  {klass}")

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(
            json.dumps(
                {
                    "iterations": total,
                    "seed": args.seed,
                    "corpora": len(names),
                    "corpus_names": names,
                    "agree": tally["agree"],
                    "declined": tally["declined"],
                    "malformed": tally["malformed"],
                    "declared": tally["declared"],
                    "both_reject": tally["both_reject"],
                    "divergences": tally["divergent"],
                    "timeouts": tally["timeout"],
                    "crashes": tally["crash"],
                    # The residual counts EVERY unresolved failure (divergence,
                    # timeout, crash) by class — it is the thing the certificate
                    # ratchets, so it must not be narrower than the tail it names.
                    "residual": dict(sorted(residual.items())),
                    "residual_total": len(bad),
                    "peak_rss_mb": {k: round(v, 1) for k, v in watermark.items()},
                    "failures": bad,
                },
                indent=1,
            )
            + "\n"
        )
        print(f"record → {args.json}")

    if args.publish_baseline:
        args.publish_baseline.parent.mkdir(parents=True, exist_ok=True)
        args.publish_baseline.write_text(
            json.dumps(
                {
                    "_contract": (
                        "Shrink-only floor for the differential-fuzz residual, read by "
                        "bench/certificate/report/scanner.py --fuzz-baseline. The total may not "
                        "grow, no single class may grow, and a class absent from this file fails "
                        "the mint even when the total fell — a new root cause is news even when "
                        "the arithmetic improved. The `*-rg` classes are the exception on both "
                        "sides of the comparison: they record the ORACLE timing out or dying "
                        "where gist answered, so they are reported but never ratcheted (they "
                        "measure the host's load, not gist's conformance). Refresh ONLY in the "
                        "same PR as the fix that lowered it: python3 "
                        "bench/conformance/rgsuite/fuzz.py --iterations "
                        f"{total} --seed {args.seed} --publish-baseline <this file>"
                    ),
                    "iterations": total,
                    "seed": args.seed,
                    # The oracle defines the residual, so a floor that does not
                    # name its rg is a floor nobody can reproduce.
                    "rg_version": _rg_version(),
                    "residual": dict(sorted(residual.items())),
                    "residual_total": len(bad),
                },
                indent=1,
            )
            + "\n"
        )
        print(f"residual baseline → {args.publish_baseline}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
