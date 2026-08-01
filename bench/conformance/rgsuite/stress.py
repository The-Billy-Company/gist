#!/usr/bin/env python3
"""Robustness lane: does either tool CRASH, HANG, or BLOAT on hostile input?

WHY A FOURTH LANE
    The other three lanes all ask "is the answer right?" — `run.py` replays
    ripgrep's own tests, `surface.py` probes its documented flags, `fuzz.py`
    generates invocations nobody wrote down. None of them asks the question the
    word "mature" actually means to an operator: *does it ever surprise me?* A
    tool that returns the right bytes and then wedges the terminal for ninety
    seconds, or takes the machine's whole RAM on one 64 MiB line, is not mature
    no matter how conformant it is.

    So this lane drops the byte-parity question entirely and measures three
    process-level properties per invocation:

      * **no crash** — exits by exiting (rc in {0,1,2}), never by signal, never
        with a rc the CLI contract doesn't define,
      * **no hang** — finishes inside the wall-clock budget,
      * **bounded memory** — peak RSS stays under a cap that does not scale with
        the input, measured from the kernel (`wait4`'s `ru_maxrss`), not guessed.

    Both binaries run every case, and BOTH verdicts are published. That is the
    point: this is the one lane where the evidence can flow the other way, and
    an honest maturity claim has to be able to record that.

WHAT IS BEING FED IN
    The adversarial tree is `../corpora/torture.py` — already the package's
    deterministic hostile corpus (cap-edge files, 5 MiB single lines, CRLF
    straddles, invalid UTF-8, NUL-bearing binary, a 120-deep nest, a symlink
    cycle, a dangling link). This lane imports it rather than inventing a second
    one, and adds only the shapes torture has no reason to carry: a 64 MiB
    single line with no terminator, a multi-megabyte NUL desert, a
    mode-000 unreadable file, and a self-referential symlink.

    Patterns are the classic engine bombs: nested quantifiers, a bounded-repeat
    explosion, an all-alternation prefilter defeat, a nullable pattern over a
    giant line, and `.*.*.*` over a line with no match (the shape that makes a
    backtracker quadratic).

USAGE
    python3 stress.py                      # full slate, both binaries
    python3 stress.py --json out.json      # machine record for the certificate
    python3 stress.py --rss-cap-mb 512     # tighten the memory bound
    python3 stress.py --timeout 10 --list

EXIT
    Non-zero if GIST is not clean on every case. ripgrep's own failures are
    recorded and reported, never gated on — this lane cannot be made to pass by
    ripgrep getting worse.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apparatus" / "corpora"))
import torture  # noqa: E402  (sibling corpus generator, imported for its build())

HERE = Path(__file__).resolve().parent
GIST = str(HERE.parents[2] / "zig-out" / "bin" / "gist")
RG = "rg"

# rg's exit contract, which gist adopts: 0 match, 1 no match, 2 error. Anything
# else — or a death by signal — is the crash this lane exists to catch.
OK_RC = (0, 1, 2)

MB = 1 << 20


# ── the hostile tree ─────────────────────────────────────────────────────────
def build_corpus(root: Path) -> None:
    """The torture tree plus the four shapes this lane needs that it lacks."""
    torture.build(root)
    extra = root / "stress"
    extra.mkdir(parents=True, exist_ok=True)
    # 64 MiB of one line, unterminated: the file that makes a line-buffered
    # reader's "one line" the whole file, and a nullable pattern's match count
    # equal to its length.
    (extra / "one_line_64m.txt").write_bytes(b"a" * (64 * MB))
    # A NUL desert: binary detection has to fire on byte 0 and stay fired.
    (extra / "nul_desert.dat").write_bytes(b"\x00" * (8 * MB))
    # Alternating NUL/text, so binary detection re-decides per chunk.
    (extra / "nul_striped.dat").write_bytes((b"text line here\n" + b"\x00" * 4096) * 512)
    unreadable = extra / "unreadable.txt"
    unreadable.write_bytes(b"secret NEEDLE_UNREADABLE\n")
    os.chmod(unreadable, 0o000)
    (extra / "readable.txt").write_bytes(b"NEEDLE_BESIDE_UNREADABLE\n")
    # A link that is its own target — the degenerate case of a walk cycle.
    selfl = extra / "self_link"
    if selfl.is_symlink() or selfl.exists():
        selfl.unlink()
    os.symlink("self_link", selfl)


# ── the case slate ───────────────────────────────────────────────────────────
# (axis, name, argv-tail). Every argv is run from the corpus root by both tools.
CASES: tuple[tuple[str, str, list[str]], ...] = (
    # ── adversarial patterns ────────────────────────────────────────────────
    ("pattern", "nested-quantifier", ["-e", "(a+)+$", "stress/one_line_64m.txt"]),
    ("pattern", "nested-quantifier-pcre2", ["-P", "-e", "(a+)+$", "stress/one_line_64m.txt"]),
    ("pattern", "bounded-repeat-bomb", ["-e", "(a{100}){100}", "stress/one_line_64m.txt"]),
    ("pattern", "alternation-64", ["-e", "|".join(f"z{i:02d}" for i in range(64)), "."]),
    ("pattern", "nullable-over-giant", ["-c", "-e", "x*", "stress/one_line_64m.txt"]),
    ("pattern", "dotstar-cubed", ["-e", ".*.*.*=.*", "stress/one_line_64m.txt"]),
    ("pattern", "unicode-class-storm", ["-e", r"(\p{L}|\p{N}|\p{P}){3,}", "enc"]),
    ("pattern", "backtrack-classic-pcre2", ["-P", "-e", "^(a|a?)+$", "stress/one_line_64m.txt"]),
    # 33.5 M lazy matches on one 64 MiB line. gist counts them in ~8.7 s; rg was
    # still running past 600 s when this case was written, which is why the lane
    # publishes BOTH verdicts instead of gating on gist's alone.
    ("pattern", "lazy-multiline-count", ["-U", "-c", "-e", r"a[\s\S]*?a", "stress/one_line_64m.txt"]),
    ("pattern", "greedy-multiline-scan", ["-U", "-c", "-e", r"a[\s\S]*a", "stress/one_line_64m.txt"]),
    # ── giant lines / giant files ───────────────────────────────────────────
    ("giant", "giant-line-match", ["-e", "NEEDLE_GIANT_LINE", "lines/giant_line.txt"]),
    ("giant", "giant-line-print", ["-e", "a+", "stress/one_line_64m.txt"]),
    ("giant", "giant-line-multiline", ["-U", "-e", "a[\\s\\S]*a", "stress/one_line_64m.txt"]),
    ("giant", "giant-line-only-matching", ["-o", "-e", "a", "lines/giant_line.txt"]),
    ("giant", "giant-line-json", ["--json", "-e", "a+", "stress/one_line_64m.txt"]),
    ("giant", "giant-line-vimgrep", ["--vimgrep", "-e", "x", "lines/giant_line.txt"]),
    ("giant", "giant-line-replace", ["-r", "Z", "-e", "a", "lines/giant_line.txt"]),
    # ── binary / encoding ───────────────────────────────────────────────────
    ("binary", "nul-desert", ["-e", "x", "stress/nul_desert.dat"]),
    ("binary", "nul-striped-text", ["-a", "-e", "text", "stress/nul_striped.dat"]),
    ("binary", "invalid-utf8-lossy", ["-E", "utf8", "-e", ".", "enc/invalid_utf8.txt"]),
    ("binary", "utf16-guessed", ["-E", "utf-16le", "-e", "NEEDLE", "enc/utf16le_bom.txt"]),
    ("binary", "binary-tree-walk", ["-e", "NEEDLE", "enc"]),
    # ── filesystem hostility ────────────────────────────────────────────────
    ("fs", "symlink-cycle-follow", ["-L", "-e", "NEEDLE_CYCLE", "links"]),
    ("fs", "self-link-follow", ["-L", "-e", "anything", "stress/self_link"]),
    ("fs", "dangling-link-follow", ["-L", "-e", "NEEDLE", "broken"]),
    ("fs", "unreadable-file", ["-e", "NEEDLE", "stress"]),
    ("fs", "unreadable-explicit", ["-e", "NEEDLE", "stress/unreadable.txt"]),
    ("fs", "deep-nest", ["-e", "NEEDLE_DEEP_NEST", "deep"]),
    ("fs", "fanout-3000", ["-e", "NEEDLE_FANOUT", "fanout"]),
    ("fs", "whole-hostile-tree", ["-e", "NEEDLE", "."]),
    ("fs", "whole-tree-hidden-noignore", ["-uuu", "-e", "NEEDLE", "."]),
)


class Outcome:
    """One (tool, case) measurement: how it ended, how long, how much RSS."""

    __slots__ = ("verdict", "rc", "signal", "seconds", "rss_mb")

    def __init__(self, verdict: str, rc: int, signal: int, seconds: float, rss_mb: float):
        self.verdict, self.rc, self.signal = verdict, rc, signal
        self.seconds, self.rss_mb = seconds, rss_mb

    def as_dict(self) -> dict:
        return {
            "verdict": self.verdict, "rc": self.rc, "signal": self.signal,
            "seconds": round(self.seconds, 3), "rss_mb": round(self.rss_mb, 1),
        }

    def cell(self) -> str:
        tag = {"clean": "ok", "hang": "HANG", "crash": "CRASH", "bloat": "BLOAT"}[self.verdict]
        return f"{tag} {self.seconds:.2f}s {self.rss_mb:.0f}MB"


# `ru_maxrss` is bytes on Darwin and KiB on Linux — the one platform difference
# this lane has to know about, and getting it wrong would silently scale every
# published memory number by 1024.
_RSS_DIV = 1.0 if platform.system() == "Darwin" else 1024.0


def measure(argv: list[str], cwd: Path, timeout: float, rss_cap_mb: float) -> Outcome:
    """Run `argv`, and report how it ended rather than what it printed.

    Output is discarded on purpose: this lane's questions are all about the
    process, and a pipe the parent has to drain would make the measurement
    depend on the parent's read cadence. `wait4` is what makes peak RSS a
    kernel-reported fact instead of a sampled guess — a poll loop can miss a
    spike between samples, `ru_maxrss` cannot.
    """
    t0 = time.monotonic()
    proc = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
    deadline = t0 + timeout
    killed = False
    while True:
        pid, status, ru = os.wait4(proc.pid, os.WNOHANG)
        if pid:
            break
        if not killed and time.monotonic() > deadline:
            proc.kill()
            killed = True
        time.sleep(0.004)
    proc.returncode = 0  # the child is already reaped; keep Popen from waiting again
    seconds = time.monotonic() - t0
    rss_mb = ru.ru_maxrss / _RSS_DIV / MB
    if killed:
        return Outcome("hang", -1, 0, seconds, rss_mb)
    sig = os.WTERMSIG(status) if os.WIFSIGNALED(status) else 0
    rc = -sig if sig else os.WEXITSTATUS(status)
    if sig or rc not in OK_RC:
        return Outcome("crash", rc, sig, seconds, rss_mb)
    if rss_mb > rss_cap_mb:
        return Outcome("bloat", rc, 0, seconds, rss_mb)
    return Outcome("clean", rc, 0, seconds, rss_mb)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--timeout", type=float, default=30.0, help="wall-clock budget per case (s)")
    ap.add_argument("--rss-cap-mb", type=float, default=1024.0, help="peak-RSS bound per case (MiB)")
    ap.add_argument("--json", type=Path, help="write the machine record here")
    ap.add_argument("--axis", action="append", help="only these axes (pattern/giant/binary/fs)")
    ap.add_argument("--list", action="store_true", help="print the slate and exit")
    ap.add_argument("--keep", type=Path, help="build the corpus here and leave it")
    args = ap.parse_args()

    cases = [c for c in CASES if not args.axis or c[0] in args.axis]
    if args.list:
        for axis, name, tail in cases:
            print(f"{axis:8} {name:26} {' '.join(tail)}")
        return 0
    if not Path(GIST).exists():
        print(f"stress: no gist binary at {GIST} (zig build -Doptimize=ReleaseFast)", file=sys.stderr)
        return 2
    if not shutil.which(RG):
        print("stress: ripgrep not installed — this lane compares against live rg", file=sys.stderr)
        return 2

    tmp = args.keep or Path(tempfile.mkdtemp(prefix="gist-stress-"))
    try:
        build_corpus(tmp)
        rg_ver = subprocess.run([RG, "--version"], capture_output=True, text=True).stdout.split("\n")[0]
        rows, records = [], []
        bad_gist, rg_worse = 0, []
        for axis, name, tail in cases:
            g = measure([GIST, "rg", *tail], tmp, args.timeout, args.rss_cap_mb)
            r = measure([RG, *tail], tmp, args.timeout, args.rss_cap_mb)
            if g.verdict != "clean":
                bad_gist += 1
            if r.verdict != "clean" and g.verdict == "clean":
                rg_worse.append((name, r.verdict))
            rows.append((axis, name, g, r))
            records.append({"axis": axis, "case": name, "argv": tail,
                            "gist": g.as_dict(), "rg": r.as_dict()})
            print(f"{'FAIL' if g.verdict != 'clean' else 'ok  '} {axis:8} {name:26} "
                  f"gist={g.cell():22} rg={r.cell()}", flush=True)

        print(f"\n{len(rows)} hostile cases  ·  timeout {args.timeout:g}s  ·  "
              f"RSS cap {args.rss_cap_mb:g} MiB  ·  {rg_ver}")
        print(f"gist: {len(rows) - bad_gist}/{len(rows)} clean (no crash, no hang, bounded memory)")
        if rg_worse:
            print(f"ripgrep is NOT clean on {len(rg_worse)}: " +
                  ", ".join(f"{n} ({v})" for n, v in rg_worse))
        else:
            print("ripgrep: clean on every case too")
        # Peak of the peaks, the number an operator actually feels.
        gmax = max(rows, key=lambda t: t[2].rss_mb)
        rmax = max(rows, key=lambda t: t[3].rss_mb)
        print(f"worst peak RSS — gist {gmax[2].rss_mb:.0f} MiB ({gmax[1]})  ·  "
              f"rg {rmax[3].rss_mb:.0f} MiB ({rmax[1]})")
        gslow = max(rows, key=lambda t: t[2].seconds)
        rslow = max(rows, key=lambda t: t[3].seconds)
        print(f"slowest        — gist {gslow[2].seconds:.2f}s ({gslow[1]})  ·  "
              f"rg {rslow[3].seconds:.2f}s ({rslow[1]})")

        if args.json:
            args.json.write_text(json.dumps({
                "rg_version": rg_ver, "timeout_s": args.timeout, "rss_cap_mb": args.rss_cap_mb,
                "cases": len(rows), "gist_clean": len(rows) - bad_gist,
                "gist_unclean": bad_gist,
                "rg_unclean": [{"case": n, "verdict": v} for n, v in rg_worse],
                "gist_worst_rss_mb": round(gmax[2].rss_mb, 1),
                "rg_worst_rss_mb": round(rmax[3].rss_mb, 1),
                "gist_slowest_s": round(gslow[2].seconds, 3),
                "rg_slowest_s": round(rslow[3].seconds, 3),
                "records": records,
            }, indent=1) + "\n")
        return 1 if bad_gist else 0
    finally:
        if not args.keep:
            # The mode-000 file would defeat rmtree; hand every entry back a mode.
            for p in tmp.rglob("*"):
                if not p.is_symlink():
                    try:
                        os.chmod(p, 0o700)
                    except OSError:
                        pass
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
