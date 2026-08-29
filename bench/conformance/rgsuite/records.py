#!/usr/bin/env python3
"""gist ⇄ ripgrep differential proof for three surfaces a mined rg suite cannot reach.

`run.py` replays ripgrep's *own* integration tests, which is a strong proof of the
semantics rg chose to write down and no proof at all of three areas where rg has
nothing to write down:

  * **by-value escapes.** rg *rejects* `\\N{NAME}` and every octal spelling — it
    reads `\\007` as a backreference, answers "backreferences are not supported",
    and points at `-P`. A suite mined from rg therefore contains no case for the
    majority of this family, and its absence looks like coverage. The spellings rg
    *does* accept are proven byte-for-byte against it here; the ones it refuses are
    refereed by Python `re`, which accepts them.
  * **the `--null-data` record model.** rg's suite has no record holding an
    interior newline, so it never asks what `^` means inside one. That is the only
    question in the mode: a record is NUL-delimited, so it may contain `\\n`, and
    every anchor's meaning follows from whether you believe it may.
  * **verbose mode.** rg accepts `(?x)`, so this is not a spelling it refuses —
    it is a spelling where rg's own suite never crosses the mode with the two
    places verbose is *not* supposed to reach. It wraps every pattern in `(?:…)`,
    including a lone one, so a pattern ending in a `#` comment loses the `)` it
    just appended; and it strips trivia *through* a character class, where `re`
    and PCRE2 both stop. Both are refereed by `re` below.

GROUND TRUTH, AND A REFEREE WHEN GROUND TRUTH IS THE THING IN DISPUTE

Ripgrep is the oracle for every cell it can answer, byte-for-byte on stdout and
exit code — there is no expected-output table in this file, so there is nothing to
bandaid. Where the two tools disagree, a tool-to-tool diff can only report that
they do; the question underneath is which one describes the language. For this
mode that has a neutral answer, so `re` referees: split the file on NUL by hand,
hand each record to Python's `re` with `re.MULTILINE` (making `^`/`$` the
`\\n`-boundary assertions both line tools agree they are), and compare all three.

DECLARED BOUNDARIES

Six families of difference are declared rather than fixed, and each is a
PREDICATE THAT RE-PROVES ITS OWN CASE on every run — re-running the tools under
the condition that isolates the cause — rather than a name the author decided to
forgive. A family that stops reproducing its mechanism stops being excused and is
scored divergent. Nothing outside the six may differ:

  residual="re_referee"   the record model. Excused only when gist reproduces the
                          `re` answer exactly and rg does not. Catches rg missing
                          a record's own start for `^` (it reads `^` as "after a
                          `\\n`", so a record beginning after a NUL is not a line
                          start to it), and printing a whole record as the `-o` row
                          for a match it rejected.
  residual="nul_in_slice" `\\z` under `--null-data`. rg matches zero records for
                          every `X\\z` and for the bare nullable `\\z` too, which
                          must hold at every haystack's end under any coherent
                          reading. It strips the `\\n` terminator before matching
                          but keeps the NUL, so `\\z` lands after a separator byte.
                          Refereed by `re` like the family above.
  residual="text_notice"  rg counts its own "binary file matches" NOTICE as a
                          line, so `-c` over a NUL-bearing file reads one high.
                          Orthogonal to anchors and pre-existing. Proof: re-run
                          both under `--text`, which retires binary detection and
                          changes nothing else; the boundary holds only if they
                          then agree byte-for-byte.
  residual="rg_rejects"   rg has no grammar for the spelling (exit 2). gist's
                          answer must equal `re`'s over the same bytes, so the
                          superset is proven to be RIGHT and not merely accepted.
  residual="rg_wrapper"    rg's own `(?:…)` pattern wrapper swallowing the `)` it
                          appended, because under verbose the pattern ended inside
                          a `#` comment. Not a missing grammar: proof is that rg
                          ANSWERS the same pattern with a newline appended — which
                          is insignificant whitespace under verbose and terminates
                          a comment, so it cannot change the language — and then
                          answers exactly what gist did.
  residual="class_trivia" rg stripping verbose trivia through a `[…]`, where `re`
                          and PCRE2 both stop: `[a b]` is `[ab]` to rg, `[ ]` an
                          empty class it rejects, `[#]` a comment that eats the
                          class. Two-sided proof — rg must answer identically for
                          rg's OWN claimed reading of the pattern (trivia deleted
                          through the class), and gist must equal `re`.
  residual="vimgrep_no_column"
                          rg emitting a `--vimgrep` row with fewer fields than its
                          own `path:line:column:text` format defines, for a record
                          whose match its printer re-derived and discarded. Excused
                          only when both tools already agree byte-for-byte in `-o`
                          and `-c` — so it cannot cover a disagreement about
                          matching — and every differing row reconstructs as rg's
                          with a column inserted.

Every family's population is pinned in `records_baseline.json` by EXACT count, not
a shrink-only floor: this grid is deterministic, so a family that grows or shrinks
is news either way. If ripgrep fixes its `^`, this lane fails and the boundary
should be deleted rather than refreshed.

stdlib-only. Fixtures are generated into a temp dir each run (the generator here is
the committed contract), so nothing large or machine-specific is tracked.

Subcommands: run [--publish-baseline PATH] | bench
"""

from __future__ import annotations

import argparse
import atexit
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[2]  # rgsuite → conformance → bench → repo
BASELINE = HERE / "records_baseline.json"
FIX = Path()  # temp fixture root, set in main()

RG = os.environ.get("RG_BIN", "rg")
GIST = ""  # resolved in main()

# gist caps its own output by default (agent-context guard); rg has no such cap, so
# lift the soft ceiling for byte-exact parity. The hard OOM ceiling stays on. The
# daemon and answer keep are stood down so every cell is a cold, self-contained run.
ENV = {
    **os.environ,
    "GIST_UNCAP": "1",
    "GIST_NO_AUTOSERVE": "1",
    "GIST_NO_KEEP": "1",
    "GIST_HINTS": "0",
}

# ───────────────────────── fixtures ─────────────────────────

# The four terminator shapes a record can have, because every remaining question in
# this mode turns on one of them: content with or without an interior newline,
# crossed with a final record that does or does not carry its NUL. `two` adds the
# only shape the others cannot express — a second record, so "a record's own start"
# is a position that is neither the file's start nor preceded by a `\n`.
RECORD_BODIES = {
    "nl_unterm": b"ab\n",
    "nl_term": b"ab\n\x00",
    "plain_unterm": b"ab",
    "plain_term": b"ab\x00",
    "two": b"ab\ncd\n\x00ef\x00",
    # Three records with interior newlines, é, and a record whose content is a bare
    # newline — the shape that made `^` and `$` disagree in the first place.
    "mixed": b"aex\nzz\nehead\x00mid \xc3\xa9 mid\n\xc3\xa9tail\nzz\x00\nzzlead\nx\x00",
}

# A newline-delimited file for the escape lane. Holds one instance of every
# character the escape grid names, so a spelling that resolves to the wrong
# codepoint answers "no match" instead of quietly matching something adjacent.
ESCAPE_CHARS = {
    "e_acute": "\u00e9",
    "u_diaeresis": "\u00fc",
    "snowman": "\u2603",
    "pile": "\U0001f4a9",
    "cjk_first": "\u4e00",
    "hangul_ga": "\uac00",
    "nbsp": "\u00a0",
    "bell": "\x07",
    "soh": "\x01",
    "guillemet": "\u00ab\u00bb",
}


# The verbose corpus. Every line exists to make ONE trivia question visible, which
# the escape corpus structurally cannot: every line there holds a space, so a class
# that keeps its space and a class that drops it match the same 43 lines and the
# difference hides. Here a space, a tab, a `#`, and an `a`/`b` each appear on a line
# that carries none of the others.
VERBOSE_LINES = [
    "alpha 42 beta",  # a, b, space, digits — the ordinary verbose target
    "x y",  # a space and nothing else the classes name
    "zzz",  # neither a space nor a/b: the negative line
    "q#w",  # a `#` with no space, so a comment rule inside a class is visible
    "u\tv",  # a tab: whitespace that is not a space
    "ALPHA 7",  # the caseless target
    "func main",  # for `^ func`
    "one two three",
]


def gen_fixtures(root: Path) -> None:
    """Write the record bodies, the escape corpus, and the NUL-bearing file."""
    rec = root / "rec"
    rec.mkdir(parents=True)
    for name, body in RECORD_BODIES.items():
        (rec / name).write_bytes(body)

    # The escape corpus: each target character on its own labeled line, then bulk
    # lines so a prefilter has a corpus to skip rather than a six-line file where
    # every strategy costs the same.
    lines = [f"{k} [{v}] end" for k, v in ESCAPE_CHARS.items()]
    lines += [f"{w} filler line {i}" for i, w in enumerate(("alpha", "beta") * 200)]
    (root / "esc.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    # Same content with no final newline: the unterminated-tail shape.
    (root / "esc_unterm.txt").write_text("\n".join(lines), encoding="utf-8")
    # A NUL in a newline-delimited file — binary detection, for the text_notice
    # boundary. Deliberately NOT record mode.
    (root / "bin.txt").write_bytes(b"alpha\nbe\x00ta\ngamma\n")

    # The verbose corpus, plus bulk so a prefilter has something to skip.
    vrb = VERBOSE_LINES + [f"{w} filler line {i}" for i, w in enumerate(("alpha", "beta") * 100)]
    (root / "vrb.txt").write_text("\n".join(vrb) + "\n", encoding="utf-8")


# ───────────────────────── grids ─────────────────────────

# Spellings ripgrep accepts. rg is the oracle for these, byte-for-byte.
ESCAPE_SHARED = [
    r"\u00e9",
    r"\u{00e9}",
    r"\U000000e9",
    r"\u2603",
    r"\U0001F4A9",
    r"\u{1F4A9}",
    r"\U{2603}",
    r"\u00e9nd",  # escape then literal: the join must not swallow a byte
    r"[\u00e9\u00fc]",  # inside a class
    r"[\u00ab-\u00bb]",  # as a range bound
    r"\u00e9\w+",
    r"^\u00e9",  # anchored: the prefilter and the anchor must agree
    r"(?i)\u00e9",
    r"\u00e9{1}",
    r"(?-u)\u00c3\u00a9",  # byte mode: two raw bytes, rg's reading too
]

# Spellings ripgrep refuses outright and Python `re` accepts. `re` is the oracle.
ESCAPE_ONLY = [
    r"\N{SNOWMAN}",
    r"\N{PILE OF POO}",
    r"\N{LATIN SMALL LETTER E WITH ACUTE}",
    r"\N{NO-BREAK SPACE}",
    r"\N{NBSP}",  # NameAliases
    r"\N{ALERT}",  # NameAliases, control
    r"\N{CJK UNIFIED IDEOGRAPH-4E00}",  # algorithmic
    r"\N{HANGUL SYLLABLE GA}",  # algorithmic
    r"\007",
    r"\01",
    r"\0",
    r"[\N{SNOWMAN}\N{ALERT}]",  # a name inside a class
]

# One representative per output frame that derives from the model differently: the
# plain frame, both count tallies, the two span frames, the boolean, the inverted
# walk. A model error is invisible in some of these and loud in others, which is
# the reason to cross every pattern with all of them rather than pick one.
FRAMES = [
    ("plain", ["-n"]),
    ("count", ["-c"]),
    ("countm", ["--count-matches"]),
    ("only", ["-o", "-b"]),
    ("vimgrep", ["--vimgrep"]),
    ("files", ["-l"]),
    ("invert", ["-v", "-n"]),
]

# What a record's anchors can be asked. `^`/`$` at every position a record affords,
# patterns that CROSS a newline (so the haystack is provably not decomposable into
# lines), and the two haystack anchors whose whole meaning is the record's own ends.
RECORD_PATTERNS = [
    "^zz",
    r"^\u00e9",
    "^a",
    "^.",
    "^",
    "^$",
    "$",
    "x$",
    r"\u00e9$",
    r"^[a-z]+$",
    r"^\w+$",
    r"\n",  # crosses: consumes the newline itself
    r"\nzz",
    r"[\n]",
    r"[\n]+",
    r"[\nz]+",
    r"a\nz",
    r"(?s)d.\u00e9",
    r"\A",
    r"\Azz",
    r"zz\z",
    r"(?m)^zz",
    r"(?-m)^zz",
]

RECORD_FILES = list(RECORD_BODIES)

# Verbose spellings ripgrep accepts, where it is the oracle byte-for-byte. Chosen
# for the places verbose is NOT supposed to reach as much as the places it is: a
# brace bound, a lazy quantifier split by a space, an escaped space, and a `\#`.
VERBOSE_SHARED = [
    r"(?x) alpha \s+ \d+",
    r"(?x)alpha\s+\d+",  # the same language with no trivia to skip
    r"(?x) a\ b",  # an escaped space is a literal space, not trivia
    r"(?x) \b [a-z] \w+ \b",
    r"(?x) (?: alpha | beta )",
    r"(?ix) ALPHA",  # reconciles beside `i`
    r"(?x-u) \w+",  # and beside `u`
    r"(?x) ^ func \s+ \w+",  # an anchor whose prefilter must agree with it
    r"(?x) three $",
    r"(?x) a{1,2}",  # a bound is not trivia-bearing
    r"(?x) b *?",  # `b *?` is one lazy star, not a star and an optional
    r"(?x) \# literal hash",  # an escaped `#` is not a comment
    r"(?x: alpha \s+ \d+ )",  # scoped: never a leading directive, so never reconciled
    r"(?-x) one two",  # the directive turning the mode OFF
]

# Patterns ripgrep's own `(?:…)` pattern wrapper destroys before its engine sees
# them: the pattern ENDS inside a `#` comment, so the `)` rg appends is swallowed
# and rg reports "unclosed group" for a pattern it would otherwise accept.
VERBOSE_WRAPPED = [
    r"(?x) alpha \s+ \d+  # the count",
    r"(?x) beta # one word",
    r"(?x) ^ func  # an anchored comment",
    r"(?x)#only a comment",  # the degenerate case: the whole pattern is a comment
]

# Where ripgrep applies verbose trivia INSIDE a character class and `re`/PCRE2 do
# not. Each shape isolates one half of that rule: deleted whitespace, and a `#`
# read as a comment opener.
VERBOSE_CLASS = [
    r"(?x) [a b]",  # rg reads `[ab]`; re/PCRE2 read a, space, b
    r"(?x) [0-9 a-f]",
    r"(?x) [ ]",  # rg's rule empties the class outright
    r"(?x) alpha [#] filler",  # rg opens a comment inside the class
]


@dataclass
class Cell:
    """One differential cell: the argv both tools get, and where it runs."""

    name: str
    args: list[str]
    path: str
    pattern: str


def _escape_cells() -> list[Cell]:
    out = []
    for f in ("esc.txt", "esc_unterm.txt", "bin.txt"):
        for frame, flags in FRAMES:
            for pat in ESCAPE_SHARED + ESCAPE_ONLY:
                out.append(Cell(f"esc:{frame}:{pat}:{f}", [*flags, pat], f, pat))
    return out


def _verbose_cells() -> list[Cell]:
    out = []
    for frame, flags in FRAMES:
        for pat in VERBOSE_SHARED + VERBOSE_WRAPPED + VERBOSE_CLASS:
            out.append(Cell(f"vrb:{frame}:{pat}", [*flags, pat], "vrb.txt", pat))
    return out


def _record_cells() -> list[Cell]:
    out = []
    for f in RECORD_FILES:
        for frame, flags in FRAMES:
            for pat in RECORD_PATTERNS:
                out.append(
                    Cell(
                        f"rec:{frame}:{pat}:{f}",
                        ["--null-data", *flags, pat],
                        f"rec/{f}",
                        pat,
                    )
                )
    return out


# ───────────────────────── the referee ─────────────────────────


def _records(data: bytes) -> list[bytes]:
    """The records both tools split out: NUL-delimited, terminator not content.

    A trailing NUL closes the last record rather than opening an empty one — the
    same rule `\\n` gets in the document model.
    """
    parts = data.split(b"\x00")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


def _lines(data: bytes) -> list[bytes]:
    """The same question for the document model, where `\\n` terminates a line."""
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return parts


def _compile(pat: str) -> re.Pattern[str]:
    """`re` reads the pattern as written.

    Running it through `unicode_escape` first mangles `\\u00e9` into two latin-1
    bytes — the referee's own bug, which showed up as cells where it disagreed with
    BOTH tools. `\\z` is spelled `\\Z` here and means the same absolute end.
    """
    return re.compile(pat.replace(r"\z", r"\Z"), re.MULTILINE)


def re_count(pat: str, data: bytes, *, record_mode: bool) -> int:
    """Haystacks holding at least one match, per `re` — what `-c` reports."""
    rx = _compile(pat)
    hays = _records(data) if record_mode else _lines(data)
    return sum(1 for h in hays if rx.search(h.decode("utf-8", "surrogateescape")))


def re_rows(pat: str, data: bytes, *, record_mode: bool) -> list[str]:
    """The `-o` rows a search must print, spelled out.

    `re.finditer` gives the matches; a printer then owes two rules on top, both
    rg-measured and both already documented at `Rows` in `emit/output.zig`, so this
    is that type's spec rather than a second opinion:

      * an empty match sitting exactly at the previous match's end is not a row
        (the progress rule — `a*` over "aa" prints one row, not two);
      * an empty match at the end of a haystack that never got its terminator is
        not a row (`x*` over "ab" is two rows, not three) — the position exists,
        but there is no separator byte after it for the match to sit before.

    Everything else prints, including a zero-width row, which is an empty line.
    """
    rx = _compile(pat)
    term = b"\x00" if record_mode else b"\n"
    hays = _records(data) if record_mode else _lines(data)
    out: list[str] = []
    for i, hay in enumerate(hays):
        text = hay.decode("utf-8", "surrogateescape")
        terminated = i + 1 < len(hays) or data.endswith(term)
        last_end = None
        for m in rx.finditer(text):
            empty = m.end() == m.start()
            if empty and (
                m.start() == last_end or (not terminated and m.start() == len(text))
            ):
                continue
            out.append(text[m.start() : m.end()])
            last_end = m.end()
    return out


# ───────────────────────── process runner ─────────────────────────


@dataclass
class Out:
    rc: int
    data: bytes
    err: bytes


def run(exe: str, args: list[str], path: str) -> Out:
    p = subprocess.run(
        [exe, *args, path], cwd=str(FIX), env=ENV, capture_output=True, timeout=90
    )
    return Out(p.returncode, p.stdout, p.stderr)


def _tool_count(exe: str, cell: Cell) -> int | None:
    nul = ["--null-data"] if "--null-data" in cell.args else []
    o = run(exe, [*nul, "-c", cell.pattern], cell.path)
    if o.rc == 2:
        return None
    out = o.data.replace(b"\x00", b"").strip()
    # `-c` prints `path:N` when more than one file is searched and bare `N` for one.
    return int(out.rsplit(b":", 1)[-1]) if out else 0


def _tool_rows(exe: str, cell: Cell) -> list[str] | None:
    nul = ["--null-data"] if "--null-data" in cell.args else []
    o = run(exe, [*nul, "-o", cell.pattern], cell.path)
    if o.rc == 2:
        return None
    if not o.data:
        return []
    term = b"\x00" if nul else b"\n"
    # Every row ends with the terminator, so the split's last element is the empty
    # tail after it. Dropping THAT rather than stripping the byte is what keeps "one
    # empty row" distinguishable from "no rows"; conflating them made a dozen cells
    # read as though both tools were wrong.
    return [r.decode("utf-8", "surrogateescape") for r in o.data.split(term)[:-1]]


# ───────────────────────── declared boundaries ─────────────────────────


def _re_expect(cell: Cell) -> tuple[int, list[str]] | None:
    """What `re` says the `-c` tally and `-o` rows are, or None if it cannot say."""
    data = (FIX / cell.path).read_bytes()
    record_mode = "--null-data" in cell.args
    try:
        return (
            re_count(cell.pattern, data, record_mode=record_mode),
            re_rows(cell.pattern, data, record_mode=record_mode),
        )
    except (re.error, UnicodeDecodeError, ValueError):
        return None


def _re_referees(cell: Cell, *, want_family: str) -> bool:
    """Does `re` back gist over rg on this cell's own question?

    Asked in the `-c` and `-o` frames, which are the two that state a fact about the
    language rather than a layout. A cell in any other frame is excused only if the
    same pattern and file are refereed in those, so a boundary can never be claimed
    for a frame nobody checked.
    """
    if (want := _re_expect(cell)) is None:
        return False
    want_c, want_o = want
    g_c, r_c = _tool_count(GIST, cell), _tool_count(RG, cell)
    if g_c is None:
        return False
    if want_family == "rg_rejects":
        # rg cannot answer at all; gist must still be RIGHT, not merely accepted.
        g_o = _tool_rows(GIST, cell)
        return r_c is None and g_c == want_c and g_o == want_o
    if r_c is None:
        return False
    g_o, r_o = _tool_rows(GIST, cell), _tool_rows(RG, cell)
    agrees = g_c == want_c and g_o == want_o
    rg_wrong = r_c != want_c or r_o != want_o
    return agrees and rg_wrong


def _vimgrep_no_column(cell: Cell, g: Out, r: Out) -> bool:
    """rg emitting a `--vimgrep` row with fewer fields than its own format defines.

    `--vimgrep` is `path:line:column:text`. Over a multi-record file rg drops the
    COLUMN on a record whose match its printer re-derived and discarded, falling
    through to `sink_fast_multi_line`, which prints the block verbatim with no
    column — the same mechanism `flags.py::_ANCHOR_EMPTY_AT_EOF` names under `-U`.

    Proof, not assertion, in two parts: both tools must already agree byte-for-byte
    in the two frames that state a FACT about the match (`-o` and `-c`), so this
    cannot excuse a disagreement about matching; and every differing row must be
    reconstructible as rg's row with a column field inserted, so a wrong line, path,
    or text cannot slip through as a missing column.
    """
    if "--vimgrep" not in cell.args:
        return False
    if _tool_rows(GIST, cell) != _tool_rows(RG, cell):
        return False
    if _tool_count(GIST, cell) != _tool_count(RG, cell):
        return False
    term = b"\x00" if "--null-data" in cell.args else b"\n"
    gr, rr = g.data.split(term), r.data.split(term)
    if len(gr) != len(rr):
        return False
    for a, b in zip(gr, rr):
        if a == b:
            continue
        # `path:line:col:text` vs `path:line:text` — drop gist's third field.
        parts = a.split(b":", 3)
        if len(parts) != 4 or not parts[2].isdigit():
            return False
        if b":".join((parts[0], parts[1], parts[3])) != b:
            return False
    return True


def _reargs(cell: Cell, pat: str) -> list[str]:
    """The cell's own argv with a different pattern — the flags and frame unchanged."""
    return [*cell.args[:-1], pat]


def _rg_wrapper(cell: Cell, g: Out) -> bool:
    """rg's own `(?:…)` pattern wrapper eating the `)` it just appended.

    rg wraps EVERY pattern, including a lone one, and under verbose a pattern may
    end inside a `#` comment — so the `)` lands after the `#` and is swallowed,
    and rg reports "unclosed group" for a pattern its own engine accepts.

    Proof, in the shape that separates a missing grammar from a broken wrapper:
    hand rg the same pattern with a newline appended. A newline is insignificant
    whitespace under verbose AND terminates a comment, so it cannot change the
    language — it only gives the wrapper somewhere to close. The boundary holds
    only if rg then answers, and answers exactly what gist did. If rg fixes its
    wrapper this family stops reproducing and should be deleted, not refreshed.
    """
    if cell.pattern.find("#", cell.pattern.find(")")) < 0:
        return False
    r2 = run(RG, _reargs(cell, cell.pattern + "\n"), cell.path)
    return r2.rc != 2 and (r2.rc, r2.data) == (g.rc, g.data)


def _rg_class_reading(pat: str) -> str:
    """rg's verbose rule, stated once: trivia deleted EVERYWHERE, classes included.

    `re` and PCRE2 both stop applying verbose inside `[…]` — a space there is a
    member and `#` is a literal. rg does not, so `[a b]` is `[ab]` to it, `[ ]` is
    an empty class it rejects, and `[#]` opens a comment that eats the class.
    """
    out: list[str] = []
    i = 0
    while i < len(pat):
        c = pat[i]
        if c == "\\" and i + 1 < len(pat):
            out.append(pat[i : i + 2])
            i += 2
        elif c == "#":
            nl = pat.find("\n", i)
            i = len(pat) if nl < 0 else nl + 1
        elif c.isspace():
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _class_trivia(cell: Cell, g: Out, r: Out) -> bool:
    """rg applying verbose trivia inside a character class, where `re` does not.

    Two-sided proof, so neither half can carry a real disagreement:

      * rg's answer for the pattern must equal rg's answer for rg's OWN claimed
        reading of it (trivia deleted through the class), in this cell's exact
        frame — which is what demonstrates the deletion is the cause rather than
        a guess. It covers the rejecting shapes too: `[ ]` becomes `[]` and rg
        refuses both, `[#]` becomes a truncated `[` and rg refuses both.
      * gist's answer must equal `re`'s, so the side gist took is the reference
        implementation's and not merely the other one.
    """
    if "[" not in cell.pattern:
        return False
    reading = _rg_class_reading(cell.pattern)
    if reading == cell.pattern:
        return False
    r2 = run(RG, _reargs(cell, reading), cell.path)
    if (r2.rc, r2.data) != (r.rc, r.data):
        return False
    if g.rc == 2:
        return False
    return _re_backs_gist(cell)


def _re_backs_gist(cell: Cell) -> bool:
    """gist's `-c` and `-o` equal `re`'s over the same bytes. Says nothing of rg."""
    if (want := _re_expect(cell)) is None:
        return False
    return (_tool_count(GIST, cell), _tool_rows(GIST, cell)) == want


def _text_notice(cell: Cell) -> bool:
    """rg counting its own binary NOTICE as a line.

    Proof: re-run both with `--text`, which retires binary detection and changes
    nothing else. The boundary holds only if they then agree byte-for-byte.
    """
    if "--null-data" in cell.args or "-a" in cell.args:
        return False
    if b"\x00" not in (FIX / cell.path).read_bytes():
        return False
    g = run(GIST, ["-a", *cell.args], cell.path)
    r = run(RG, ["-a", *cell.args], cell.path)
    return (g.rc, g.data) == (r.rc, r.data)


def classify(cell: Cell, g: Out, r: Out) -> tuple[str, str]:
    """(verdict, family) for one cell. Ripgrep is the oracle unless a residual holds."""
    if g.rc == 2 and r.rc == 2:
        # An error message's wording is each tool's own; that both refused is the fact.
        return "both_refuse", ""
    if (g.rc, g.data) == (r.rc, r.data):
        return "identical", ""
    if r.rc == 2 and g.rc != 2:
        # Three ways rg can refuse what gist answers, and they are different facts:
        # its wrapper broke, its class rule differs, or it has no grammar at all.
        # Checked most-specific first so a wrapper failure is never filed as a
        # missing grammar.
        if _rg_wrapper(cell, g):
            return "boundary", "rg_wrapper"
        if _class_trivia(cell, g, r):
            return "boundary", "class_trivia"
        return ("boundary", "rg_rejects") if _re_referees(cell, want_family="rg_rejects") \
            else ("divergent", "")
    if "[" in cell.pattern and _class_trivia(cell, g, r):
        return "boundary", "class_trivia"
    if _text_notice(cell):
        return "boundary", "text_notice"
    if _vimgrep_no_column(cell, g, r):
        return "boundary", "vimgrep_no_column"
    if r"\z" in cell.pattern and "--null-data" in cell.args:
        if _re_referees(cell, want_family="nul_in_slice"):
            return "boundary", "nul_in_slice"
    if _re_referees(cell, want_family="re_referee"):
        return "boundary", "re_referee"
    return "divergent", ""


# ───────────────────────── run ─────────────────────────


def _mini_diff(a: bytes, b: bytes, ctx: int = 2) -> str:
    ga, gb = a.split(b"\n"), b.split(b"\n")
    for i, (x, y) in enumerate(zip(ga, gb)):
        if x != y:
            lo, hi = max(0, i - ctx), i + ctx + 1
            return (
                "    gist: " + b"\\n".join(ga[lo:hi]).decode("utf-8", "replace")[:200]
                + "\n    rg  : " + b"\\n".join(gb[lo:hi]).decode("utf-8", "replace")[:200]
            )
    return f"    length differs: gist={len(a)} rg={len(b)}"


def _rg_version() -> str:
    out = subprocess.run([RG, "--version"], capture_output=True).stdout
    return out.split()[1].decode() if out.split() else "unknown"


def do_run(publish: str | None) -> int:
    cells = _escape_cells() + _verbose_cells() + _record_cells()
    tally = {"identical": 0, "both_refuse": 0, "divergent": 0}
    families: dict[str, int] = {}
    fails: list[str] = []

    for c in cells:
        g = run(GIST, [*c.args, "--no-index"], c.path)
        r = run(RG, c.args, c.path)
        verdict, family = classify(c, g, r)
        if verdict == "boundary":
            families[family] = families.get(family, 0) + 1
            continue
        tally[verdict] += 1
        if verdict == "divergent":
            fails.append(
                f"{c.name}: gist rc={g.rc} rg rc={r.rc}\n" + _mini_diff(g.data, r.data)
            )

    boundary_total = sum(families.values())
    report = {
        "cases": len(cells),
        "identical": tally["identical"],
        "both_refuse": tally["both_refuse"],
        "boundary": dict(sorted(families.items())),
        "boundary_total": boundary_total,
    }

    for f in fails[:20]:
        print(f"DIVERGE {f}")
    if len(fails) > 20:
        print(f"… and {len(fails) - 20} more")

    print(
        f"\n{len(cells)} cases: {tally['identical']} identical, {boundary_total} at a "
        f"declared boundary, {tally['both_refuse']} refused by both, "
        f"{tally['divergent']} unjustified"
    )
    for name, n in report["boundary"].items():
        print(f"  boundary {name}={n}")

    if publish:
        Path(publish).write_text(
            json.dumps(
                {
                    "_contract": (
                        "Exact-count contract for bench/conformance/rgsuite/records.py. "
                        "This grid is deterministic, so every number here is exact rather "
                        "than a shrink-only floor: a boundary family that grows or shrinks "
                        "is news either way. If ripgrep fixes the behavior a family "
                        "describes, this lane fails and the family should be DELETED from "
                        "records.py rather than refreshed here. Refresh only in the same PR "
                        "as the change that moved it: python3 "
                        "bench/conformance/rgsuite/records.py run --publish-baseline "
                        "bench/conformance/rgsuite/records_baseline.json"
                    ),
                    "rg_version": _rg_version(),
                    **report,
                },
                indent=1,
            )
            + "\n"
        )
        print(f"published baseline → {publish}")
        return 1 if fails else 0

    if not BASELINE.exists():
        print(f"no baseline at {BASELINE} — publish one with --publish-baseline")
        return 1 if fails else 0

    want = json.loads(BASELINE.read_text())
    drift = [
        f"{k}: {want[k]} → {report[k]}"
        for k in ("cases", "identical", "both_refuse", "boundary_total")
        if want.get(k) != report[k]
    ]
    for fam in sorted(set(want.get("boundary", {})) | set(report["boundary"])):
        a, b = want.get("boundary", {}).get(fam), report["boundary"].get(fam)
        if a != b:
            drift.append(f"boundary {fam}: {a} → {b}")
    if drift:
        print("\nBASELINE DRIFT (records_baseline.json):")
        for d in drift:
            print(f"  {d}")
        print(f"  rg_version baseline={want.get('rg_version')} live={_rg_version()}")
    return 1 if (fails or drift) else 0


def do_bench() -> int:
    """Time the record model against rg — the decomposition's whole point."""
    corpus = FIX / "big.nul"
    if not corpus.exists():
        rec = (b"alpha beta gamma\nmid value tail\n\xc3\xa9top delta\n" * 64) + b"\x00"
        corpus.write_bytes(rec * 400)
    print(f"{'pattern':28}{'gist ms':>10}{'rg ms':>10}{'x':>7}")
    for pat in ("^zzsentinel", r"^\w+ mid", "^(?:alpha|beta|gamma)", r"^[a-z]+ [a-z]+"):
        args = ["--null-data", "-c", pat]
        g = _median(GIST, [*args, "big.nul"])
        r = _median(RG, [*args, "big.nul"])
        print(f"{pat:28}{g:10.1f}{r:10.1f}{r / g:6.2f}x")
    return 0


def _median(exe: str, args: list[str]) -> float:
    ts = []
    for _ in range(7):
        t0 = time.perf_counter()
        subprocess.run([exe, *args], cwd=str(FIX), env=ENV, capture_output=True)
        ts.append((time.perf_counter() - t0) * 1e3)
    return sorted(ts)[len(ts) // 2]


def _find_gist() -> str:
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
    if not out.exists():
        sys.exit("no gist binary found after `zig build`")
    return str(out)


def main() -> int:
    global FIX, GIST
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd")
    r = sub.add_parser("run", help="the differential grid (default)")
    r.add_argument("--publish-baseline", metavar="PATH")
    sub.add_parser("bench", help="time the record model against rg")
    args = ap.parse_args()

    GIST = _find_gist()
    FIX = Path(tempfile.mkdtemp(prefix="rgsuite-records-"))
    atexit.register(shutil.rmtree, FIX, True)
    gen_fixtures(FIX)

    if args.cmd == "bench":
        return do_bench()
    return do_run(getattr(args, "publish_baseline", None))


if __name__ == "__main__":
    sys.exit(main())
