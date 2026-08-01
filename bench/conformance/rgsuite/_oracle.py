#!/usr/bin/env python3
"""Shared replay oracle for the rgsuite differential proof.

`run.py` (the scoreboard), `dbg.py` (the single-case inspector), and
`check_results.py` (the anti-staleness gate) all need the *same* three things:
materialize a mined fixture, run real `rg` and `gist rg` on byte-identical
inputs, and normalize the inherently non-deterministic slices of their output
before a byte-exact diff. Keeping that one implementation here means the debugger
can never diverge from the scorer, and a normalization the scorer trusts is the
exact one a human eyeballs.

ripgrep is always the oracle — we never assert a hardcoded expected string. The
mined `terminal` field records which stream ripgrep's own test asserted on
(`stdout` / `exit` / `stderr` / `output`), and `pcre2` records that the upstream
`rgtest!` was guarded by `is_pcre2()` — whose harness (`upstream/ripgrep/tests/util.rs`,
`TestCommand::cmd`) injects `--pcre2` into every command. We reproduce that
injection so a lookaround/backreference case runs against the same engine
ripgrep's suite ran it against.
"""

from __future__ import annotations

import base64
import contextlib
import os
from pathlib import Path
import re
import subprocess


HERE = Path(__file__).resolve().parent
# The CLI (`rg` verb), not gist-bench. `GIST_BIN` first — the same override
# `flags.py` / `modes.py` / `transforms.py` already honor, and the only way to
# point this suite at the `gist` binary once it ships from its own package rather
# than from this one's `zig-out`. The in-tree path stays the default so a
# single-package checkout needs no environment at all.
GIST = Path(os.environ.get("GIST_BIN") or HERE.parents[2] / "zig-out" / "bin" / "gist")
RG = "rg"

# gist's default soft output cap (the agent-context guard, corpus.zig) would clip
# a high-hit case and diverge from ripgrep's uncapped output; this differential
# oracle needs the full stream, so lift the soft cap for every gist child (both
# engines inherit os.environ). The hard OOM ceiling stays on.
os.environ.setdefault("GIST_UNCAP", "1")


def materialize(rec: dict, root: Path) -> None:
    """Reconstruct a mined test's on-disk fixture under `root`."""
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


def run(cmd: list[str], cwd: str, stdin_bytes: bytes | None, engine_env: dict | None = None):
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


def argv_for(rec: dict) -> list[str]:
    """The mined argv, with `--pcre2` injected for an `is_pcre2()`-guarded case.

    ripgrep's test harness (`TestCommand::cmd`) prepends `--pcre2` to every
    command a pcre2-guarded `rgtest!` runs; without the injection the mined argv
    (which usually omits an explicit `-P`) would run on the default engine and
    the lookaround/backref the test exercises would never reach PCRE2. We inject
    only when the argv doesn't already select it, so an explicit `-P`/`--pcre2`
    case is untouched.
    """
    argv = list(rec["argv"])
    if rec.get("pcre2") and not any(a in ("-P", "--pcre2") for a in argv):
        return ["--pcre2", *argv]
    return argv


def rg_cmd(rec: dict) -> list[str]:
    """The real-ripgrep command for a record (the oracle)."""
    return [RG, "--path-separator", "/", *argv_for(rec)]


def gist_cmd(rec: dict) -> list[str]:
    """The `gist rg` command for a record (the subject under test)."""
    return [str(GIST), "rg", *argv_for(rec)]


def sort_lines(b: bytes) -> bytes:
    """Sort a byte blob's lines (the `eqnice_sorted!` order-agnostic oracle)."""
    ls = b.decode("utf-8", "replace").strip("\n").split("\n") if b.strip() else []
    return ("\n".join(sorted(ls)) + ("\n" if ls else "")).encode()


# `--stats` prints two wall-clock lines (`… seconds spent searching`, `… seconds
# total`) that are inherently non-deterministic. ripgrep's own tests only assert
# `contains("seconds")`, never the value — so we normalize both sides' timing
# lines to a fixed token before the byte-exact diff (not a correctness property).
_SECONDS = re.compile(rb"^[0-9.]+ (seconds spent searching|seconds total)$", re.MULTILINE)


def norm_time(b: bytes) -> bytes:
    """Collapse `--stats` wall-clock lines to a fixed token."""
    return _SECONDS.sub(rb"T \1", b)


# `--json` carries the same inherently non-reproducible accounting the text
# `--stats` block does: wall-clock `elapsed`/`elapsed_total` objects and the
# printer-internal `bytes_printed` byte count. ripgrep's own JSON tests assert
# structure + counts, never these — so we normalize just those fields (on BOTH
# sides) before the byte-exact diff, exactly like the `seconds` normalization.
_ELAPSED = re.compile(rb'"elapsed(?:_total)?":\{[^}]*\}')
_BYTES_PRINTED = re.compile(rb'"bytes_printed":\d+')


def norm_json(b: bytes) -> bytes:
    """Collapse `--json` wall-clock + byte-count fields to fixed values."""
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


def exercises_ignore(rec: dict) -> bool:
    """True when a case relies on a deliberately-unsupported ignore source."""
    for f in rec["files"]:
        if f["path"].rsplit("/", 1)[-1] in UNSUPPORTED_IGNORE_FILES:
            return True
    return any(a in UNSUPPORTED_IGNORE_FLAGS for a in rec["argv"])


_ANSI = re.compile(rb"\x1b\[[0-9;]*m")


def strip_ansi(b: bytes) -> bytes:
    """Drop ANSI SGR codes (gist paints its own palette — color.zig)."""
    return _ANSI.sub(b"", b)


def uses_color(rec: dict) -> bool:
    """True when a case turns color on (its ANSI codes are gist's own palette)."""
    return any(
        a in ("--color", "--colors") or a.startswith(("--color=", "--colors=")) for a in rec["argv"]
    )


# gist's PURPOSEFUL engine declines: the linear-time default engine refuses a
# construct outside its guaranteed-linear syntax (lookaround, backreferences,
# `(?x)/(?U)/(?R)`), and it compiles ONE engine so mixed per-pattern `(?i)`/`(?u)`
# demands are irreconcilable — in every such case gist exits 2 with the exact
# guidance to reach for `-P`/`--pcre2`/`--engine auto` or rg. This is a documented
# design boundary (serial.zig `buildMatcher`/`combinePatterns`), NOT a bug: gist
# never silently computes a wrong answer, it declines loud and points the way. A
# `stdout`-terminal case already scores NA on any gist exit-2; these signatures
# extend that SAME judgment to `exit`/`err`-terminal cases, so one decline isn't
# FAIL in one test and NA in another purely because of which stream rg asserted on.
DESIGN_DECLINE_SIGNATURES = (
    b"gist compiles one engine",
    b"outside gist's linear-time syntax",
    b"unsupported by gist's engine",
)


def is_design_decline(err: bytes) -> bool:
    """True when gist's stderr is one of its documented engine declines (→ NA)."""
    return any(sig in err for sig in DESIGN_DECLINE_SIGNATURES)


# gist's OTHER exit-2 class, which makes the opposite claim: not "the linear
# engine wants PCRE2" but "no grammar here accepts this at all". The CLI prints
# this line only after asking PCRE2 and being refused too (`writ/arm.zig: blame`),
# so the phrase is that probe's verdict rather than a guess about it — which is
# also why the two classes must be read apart. gist used to print the decline
# above for BOTH, so a malformed pattern was blamed on lookaround and sent to a
# flag that cannot help.
#
# rg answers these anyway, and the reason is worth stating because it is not a
# grammar gist lacks: rg wraps every pattern in `(?:...)`, which pairs a stray
# paren of the user's with one of its own. `)(` becomes `(?:)()` — a VALID regex
# matching the empty string at every position, which is what rg then reports
# (`--json` shows an empty submatch per column). So rg's 0/1 here is not evidence
# that the pattern is valid; rg silently searched for something the user did not
# write. gist refuses it, and PCRE2 agrees there is nothing to compile.
#
# Scored NA — a documented divergence, not a PASS: gist cannot claim parity with
# an answer it considers wrong, and not a FAIL: refusing a malformed pattern is
# the fail-closed contract working.
MALFORMED_SIGNATURES = (b"no engine here compiles it",)


def is_malformed_refusal(err: bytes) -> bool:
    """True when gist refused a pattern NO grammar it has accepts (→ NA)."""
    return any(sig in err for sig in MALFORMED_SIGNATURES)
