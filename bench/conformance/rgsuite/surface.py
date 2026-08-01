#!/usr/bin/env python3
"""Flag-surface conformance: gist vs ripgrep over ripgrep's OWN documented flags.

`run.py` scores the cases ripgrep's integration suite happens to contain. That
is a strong proof of the semantics rg chose to test, and a weak proof of the
surface rg chose to DOCUMENT: a flag ripgrep ships but never writes a `rgtest!`
for is invisible to a mined suite, so a mined suite cannot answer "what fraction
of ripgrep does gist reproduce?" without begging the question. This module asks
the complementary question against a denominator ripgrep controls and we do not.

THE DENOMINATOR
    `rg --generate complete-bash` is emitted from ripgrep's own flag table (the
    same table its `--help` and man page come from), so the long-flag list is
    ripgrep's definition of its surface, not ours. `rg --generate man` supplies
    which of those flags take a value. Both are read at run time from the live
    `rg` on PATH — the denominator moves when ripgrep's does, and a flag added
    upstream shows up here as an unclassified miss rather than silently outside
    the accounting.

THE VERDICT PER FLAG
    Each flag is exercised on a fixed miniature tree and both binaries' stdout
    and exit code are compared byte-for-byte after the same normalizations the
    mined oracle applies (`_oracle.norm_time` / `norm_json`).

        identical   byte-identical stdout + equal exit code
        boundary    differs, and the difference is a DECLARED, catalogued one
                    (gist's own palette, gist's superset type registry, gist's
                    own identity strings) — each row carries the reason and a
                    residual check proving the difference is only that
        divergent   differs for no declared reason — a bug, and it is counted
                    against conformance
        rejected    gist exits 2 "unknown flag" where rg accepts — a hole in the
                    surface, counted against conformance

    `identical + boundary` is the conformance numerator. Rejections and
    undeclared divergences are the only ways to lose a point, and a boundary
    must justify itself with a residual check or it is scored as divergent.

Usage
    python3 bench/rgsuite/surface.py                 # human table
    python3 bench/rgsuite/surface.py --json OUT.json # machine record (Layer I)
    python3 bench/rgsuite/surface.py --only no-hidden --verbose
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import _oracle

GIST = str(_oracle.GIST)
RG = _oracle.RG

# `-i` → `--ignore-case`, learned from ripgrep's own man page by `rg_flags()`.
# A short flag inherits its long partner's probe value and declared boundary, so
# every table in this module is keyed on one spelling per option.
ALIAS: dict[str, str] = {}


def declared(table: dict, flag: str, default=None):
    """`table[flag]`, falling back to the flag's long partner."""
    return table.get(flag, table.get(ALIAS.get(flag, ""), default))

# A value for every value-taking rg flag, chosen so the flag actually does
# something on the fixture rather than erroring out. A value-taking flag with no
# entry here is reported as `unprobed` and counted in the denominator, so this
# table cannot silently shrink the surface being claimed.
VALUES = {
    "--after-context": "1",
    "--before-context": "1",
    "--context": "1",
    "--buffer-size": "8K",
    "--color": "never",
    "--colors": "match:fg:red",
    "--context-separator": "--",
    "--dfa-size-limit": "10M",
    "--encoding": "utf-8",
    "--engine": "default",
    "--field-context-separator": "-",
    "--field-match-separator": ":",
    "--file": "pat.txt",
    "--generate": "man",
    "--glob": "*.rs",
    "--hostname-bin": "hostname",
    "--hyperlink-format": "none",
    "--iglob": "*.RS",
    "--ignore-file": "extra.ignore",
    "--max-columns": "80",
    "--max-count": "1",
    "--max-depth": "1",
    "--max-filesize": "1M",
    "--path-separator": "/",
    "--pre": "cat",
    "--pre-glob": "*.rs",
    "--regex-size-limit": "10M",
    "--regexp": "fn",
    "--replace": "X",
    "--sort": "path",
    "--sortr": "path",
    "--threads": "2",
    "--type": "rust",
    "--type-add": "foo:*.foo",
    "--type-clear": "rust",
    "--type-not": "rust",
}

# Flags whose whole job is to choose or suppress an ordering: forcing `--sort
# path` alongside them would test our injection instead of the flag. Their
# output is therefore a SET, and the fair oracle is the one ripgrep applies to
# itself in exactly this situation — `eqnice_sorted!`, which sorts both sides
# before comparing because rg's own walk order is thread-scheduling dependent.
NO_SORT = {"--sort", "--sortr", "--sort-files", "--no-sort-files", "--threads"}
SET_VALUED = {"--threads", "--no-sort-files"}

# Flags that replace the positional pattern (it arrives through the flag).
PATTERN_IN_FLAG = {"--regexp", "-e", "--file", "-f"}

# Whole modes that need no pattern (a path is still meaningful), and the
# lifecycle flags that answer about the binary and take nothing at all.
NO_PATTERN = {"--files"}
NO_ARGS = {"--type-list", "--version", "--help", "--generate", "--pcre2-version"}

# ---------------------------------------------------------------------------
# Declared boundaries. Each entry says WHY a byte difference is not a bug and,
# crucially, names a residual check that must still hold — a boundary whose
# residual fails is reported as divergent, so this table can excuse a palette
# but can never excuse a wrong answer.
#
#   residual="ansi"      identical once SGR codes are stripped from both sides
#   residual="registry"  every type rg defines exists in gist with AT LEAST rg's
#                        globs — the containment is per type, not per line, so a
#                        type gist extends still proves rg's rows are covered
#   residual="identity"  the tool is naming ITSELF; only the exit code must match
#   residual="superset"  gist prints MORE than rg for the same verdict: rg's
#                        reported paths must still all be present, so the
#                        boundary can add lines but never lose a file rg found
#   residual="silent0"   BOTH printed nothing and rg still claims success: the
#                        only admitted shape is rg exit 0 / gist exit 1 with two
#                        empty streams, where gist's code is the coherent one
# ---------------------------------------------------------------------------
BOUNDARIES = {
    "--pretty": ("ansi", "gist paints its own OKLCH-derived palette (catalog: --colors)"),
    "-p": ("ansi", "gist paints its own OKLCH-derived palette (catalog: --colors)"),
    "--colors": ("ansi", "one SGR sequence per element where rg emits one per attribute"),
    "--color": ("ansi", "gist's palette under --color always"),
    "--type-list": ("registry", "gist's type registry is a declared strict superset of rg's"),
    "--version": ("identity", "each tool names itself"),
    "--help": ("identity", "each tool documents its own surface"),
    "--generate": ("identity", "each tool generates ITS OWN man page and completions"),
    "--pcre2-version": ("identity", "gist reports its vendored PCRE2 build"),
    "--debug": ("identity", "each tool's own diagnostic channel (stderr; stdout must match)"),
    "--trace": ("identity", "each tool's own diagnostic channel (stderr; stdout must match)"),
    "--stats": ("identity", "gist reports its own extra counters after rg's block"),
    "--binary": (
        "superset",
        "catalogued improvement (catalog: --binary, compatibility=.improvement): a code "
        "locator prints every matching line of a NUL-bearing file where rg prints one "
        "opaque `binary file matches` summary and stops",
    ),
    "--files-without-match": (
        "silent0",
        "measured rg self-contradiction: over a tree holding ANY walked NUL-bearing "
        "file, `rg --files-without-match` exits 0 while printing no path at all — and "
        "it does so whether or not that file matches (`bytes searched: 0` in its own "
        "--stats block). Its Summary printer suppresses binary paths while its exit "
        "code counts them, so the code says `found` and the stream says `none`. gist "
        "exits 1, which is what this mode's exit code means: 0 iff a path was listed",
    ),
}


# ---------------------------------------------------------------------------
# The adverse lane.
#
# A single canonical probe per flag proves gist ACCEPTS the flag and agrees with
# rg on that invocation — and it cannot distinguish a working negation from a
# no-op, because most negations name the default, so doing nothing looks right.
# Every pair below puts the negation where a no-op would be VISIBLE: after the
# positive flag it undoes, on a fixture where the two answers differ. If gist
# silently swallowed `--no-hidden`, `-uu --no-hidden` would keep finding
# `.hidden.rs` and this lane would fail while the probe lane stayed green.
#
# Every pair is scored against live rg exactly like the probe lane, so these are
# not hand-written expectations — ripgrep remains the oracle.
UNDO_PAIRS = [
    ("hidden", ["-uu", "--no-hidden", "hidden", "."]),
    ("hidden-explicit", ["--hidden", "--no-hidden", "hidden", "."]),
    ("ignore", ["--no-ignore", "--ignore", "ignored", "."]),
    ("ignore-vcs", ["--no-ignore-vcs", "--ignore-vcs", "ignored", "."]),
    ("text", ["-a", "--no-text", "fn", "."]),
    ("binary", ["--binary", "--no-binary", "fn", "."]),
    ("invert", ["-v", "--no-invert-match", "fn", "."]),
    ("fixed", ["-F", "--no-fixed-strings", "f.", "."]),
    ("byte-offset", ["-b", "--no-byte-offset", "fn", "."]),
    ("multiline", ["-U", "--no-multiline", "fn.let", "."]),
    ("json", ["--json", "--no-json", "fn", "."]),
    ("json-then-l", ["--json", "-l", "--no-json", "fn", "."]),
    ("pcre2", ["-P", "--no-pcre2", "fn", "."]),
    ("pre", ["--pre", "cat", "--no-pre", "fn", "."]),
    ("sort-files", ["--sort-files", "--no-sort-files", "fn", "."]),
    ("glob-ci", ["--iglob", "*.RS", "--glob-case-insensitive", "--no-glob-case-insensitive", "fn", "."]),
    ("crlf", ["--crlf", "--no-crlf", "fn", "."]),
    ("max-columns-preview", ["-M", "4", "--max-columns-preview", "--no-max-columns-preview", "fn", "."]),
    ("one-file-system", ["--one-file-system", "--no-one-file-system", "fn", "."]),
    ("search-zip", ["-z", "--no-search-zip", "fn", "."]),
    ("encoding", ["-E", "utf-16", "--no-encoding", "fn", "."]),
    ("type-clear-search", ["--type-clear", "rust", "fn", "."]),
    ("type-clear-then-t", ["--type-clear", "rust", "-t", "rust", "fn", "."]),
    ("type-clear-readd", ["--type-clear", "rust", "--type-add", "rust:*.rs", "-t", "rust", "fn", "."]),
    ("type-clear-list", ["--type-clear", "rust", "--type-list"]),
    # The positive direction has to keep working too: a negation implemented by
    # clobbering shared state would break its own partner.
    ("hidden-order", ["--no-hidden", "-uu", "hidden", "."]),
    ("ignore-order", ["--ignore", "--no-ignore", "ignored", "."]),
]

# The `--sort path` injection is unsafe for an ordering pair; everything else
# gets it so the comparison is a sequence rather than a scheduling accident.
UNDO_UNORDERED = {"sort-files"}

# A pair whose output is a type listing inherits `--type-list`'s declared
# boundary — gist's registry is a superset, so a raw byte diff would fail on
# gist's EXTRA types and tell us nothing about the flag under test. But
# containment alone would also pass a `--type-clear` that did nothing, so this
# residual adds the missing half: the cleared name must be absent from gist's
# listing too, read out of the pair's own argv rather than restated here.
UNDO_RESIDUAL = {"type-clear-list": "registry-cleared"}


def adverse(cwd: str) -> list[dict]:
    """Score every undo pair against live rg. Each row is pass/fail, no excuses."""
    rows = []
    for name, argv in UNDO_PAIRS:
        full = argv if name in UNDO_UNORDERED else ["--sort", "path", *argv]
        rc_rg, out_rg, _ = _oracle.run([RG, *full], cwd, None)
        rc_g, out_g, err_g = _oracle.run([GIST, "rg", *full], cwd, None)
        norm = _oracle.sort_lines if name in UNDO_UNORDERED else (lambda b: b)
        a, b = norm(_oracle.norm_json(out_rg)), norm(_oracle.norm_json(out_g))
        ok = rc_rg == rc_g and a == b
        if not ok and UNDO_RESIDUAL.get(name) == "registry-cleared":
            cleared = full[full.index("--type-clear") + 1].encode()
            ok = _residual_holds("registry", rc_rg, rc_g, a, b) and cleared not in _type_registry(b)
        row = {"pair": name, "argv": full, "rc": [rc_rg, rc_g], "ok": ok}
        if name in UNDO_RESIDUAL:
            row["residual"] = UNDO_RESIDUAL[name]
        if not ok:
            row["why"] = _diff_note(a, b) if a != b else (
                f"exit {rc_rg} vs {rc_g}: {err_g.decode(errors='replace').strip()[:100]}"
            )
        rows.append(row)
    return rows


def fixture(root: Path) -> None:
    """A miniature tree with enough shape to make every flag class observable."""
    (root / "a.rs").write_text("fn main() {\n    let x = 1;\n}\n")
    (root / "b.py").write_text("def fn_two():\n    return 2\n")
    (root / "sub").mkdir(exist_ok=True)
    (root / "sub" / "c.go").write_text("func fn() int { return 3 }\n")
    (root / ".gitignore").write_text("ign.txt\n")
    (root / "ign.txt").write_text("fn ignored\n")
    (root / ".hidden.rs").write_text("fn hidden() {}\n")
    (root / "pat.txt").write_text("fn\n")
    (root / "extra.ignore").write_text("nothing-matches-this\n")
    # A NUL-bearing file, so every flag that touches the binary decision is
    # OBSERVABLE here: without it `--binary`, `-a`, `--no-text`, and the `-uuu`
    # ladder all probe a tree where the binary path never runs, and a flag that
    # did nothing at all would score identical.
    (root / "bin.dat").write_bytes(b"fn head\n\x00\x01 fn buried\nfn tail\n")


def argv_for(flag: str) -> list[str]:
    """The probe argv for one flag: the flag, its value, and a fair base."""
    value = declared(VALUES, flag)
    argv = [flag, value] if value is not None else [flag]
    canon = ALIAS.get(flag, flag)
    if canon in NO_ARGS:
        return argv
    if canon not in NO_SORT:
        argv = ["--sort", "path", *argv]
    return [*argv, "."] if canon in PATTERN_IN_FLAG or canon in NO_PATTERN else [*argv, "fn", "."]


def probe(flag: str, cwd: str) -> dict:
    """Run one flag through both binaries and classify the difference."""
    argv = argv_for(flag)
    rc_rg, out_rg, _ = _oracle.run([RG, *argv], cwd, None)
    rc_g, out_g, err_g = _oracle.run([GIST, "rg", *argv], cwd, None)

    set_valued = ALIAS.get(flag, flag) in SET_VALUED

    def norm(b: bytes) -> bytes:
        b = _oracle.norm_json(_oracle.norm_time(b))
        return _oracle.sort_lines(b) if set_valued else b

    out_rg, out_g = norm(out_rg), norm(out_g)
    row = {"flag": flag, "rc": [rc_rg, rc_g], "bytes": [len(out_rg), len(out_g)]}
    if set_valued:
        row["oracle"] = "sorted (rg's own eqnice_sorted!: this flag disclaims order)"

    if rc_rg == rc_g and out_rg == out_g:
        return {**row, "verdict": "identical"}
    if rc_g == 2 and rc_rg != 2 and b"unknown" in err_g.lower():
        return {**row, "verdict": "rejected", "why": err_g.decode(errors="replace").strip()[:120]}

    kind, why = declared(BOUNDARIES, flag, (None, None))
    if kind and _residual_holds(kind, rc_rg, rc_g, out_rg, out_g):
        return {**row, "verdict": "boundary", "residual": kind, "why": why}
    return {**row, "verdict": "divergent", "why": _diff_note(out_rg, out_g)}


def _residual_holds(kind: str, rc_rg: int, rc_g: int, out_rg: bytes, out_g: bytes) -> bool:
    """A declared boundary must still prove the difference is ONLY the declared one."""
    if kind == "ansi":
        return rc_rg == rc_g and _oracle.strip_ansi(out_rg) == _oracle.strip_ansi(out_g)
    if kind == "registry":
        rgt, gt = _type_registry(out_rg), _type_registry(out_g)
        return rc_rg == rc_g and all(name in gt and rgt[name] <= gt[name] for name in rgt)
    if kind == "identity":
        return rc_rg == rc_g
    if kind == "silent0":
        return rc_rg == 0 and rc_g == 1 and not out_rg and not out_g
    if kind == "superset":
        # The improvement may add LINES; it may not change which files matched or
        # the exit code. rg's suppressing summary still names its path, so the two
        # path sets are directly comparable.
        # rg may drop a whole file: measured, `rg --binary -e P ./elf.bin` prints
        # `binary file matches …`, but adding `-C 2` prints NOTHING and exits 1 for
        # the same file — its context path discards the binary notice. So the
        # boundary admits gist reporting MORE files and never fewer; a path rg
        # found and gist missed still fails.
        if rc_rg == rc_g:
            return _paths(out_rg) <= _paths(out_g)
        # The same self-inconsistency seen alone rather than in a tree: rg silent
        # and claiming no-match, gist reporting the lines. Nothing wider.
        return rc_rg == 1 and rc_g == 0 and not out_rg and bool(out_g)
    raise AssertionError(f"unknown residual kind {kind!r}")


def _paths(b: bytes) -> set[bytes]:
    """The set of paths a `path:…` stream reports (order and count discarded).

    A candidate is rejected if it carries a control byte. That is not cosmetic:
    the one stream this is asked about is `--binary`, where gist prints the
    matching lines of a NUL-bearing file in full — binary content embeds both
    `:` and `\n`, so a naive split manufactures phantom "paths" out of the very
    lines the boundary exists to permit. No filesystem path in either tool's
    output can contain a control byte, so dropping them keeps the check about
    which FILES were reported.
    """
    out: set[bytes] = set()
    for line in b.splitlines():
        # `--null` spells the path terminator as NUL, not `:` — take whichever
        # field separator comes first so the boundary check reads both postures.
        cut = min((i for i in (line.find(b":"), line.find(b"\x00")) if i >= 0), default=-1)
        if cut < 0:
            continue
        head = line[:cut]
        if not any(c < 0x20 or c == 0x7F for c in head):
            out.add(head)
    return out


def _type_registry(b: bytes) -> dict[bytes, set[bytes]]:
    """Parse `--type-list` output into `{type: {glob, …}}`."""
    out: dict[bytes, set[bytes]] = {}
    for line in b.splitlines():
        name, _, globs = line.partition(b": ")
        if globs:
            out[name] = {g.strip() for g in globs.split(b",")}
    return out


def _diff_note(a: bytes, b: bytes) -> str:
    """The first differing line pair, for a human reading the failure."""
    la, lb = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(la, lb)):
        if x != y:
            return f"line {i + 1}: rg={x[:60]!r} gist={y[:60]!r}"
    return f"line count rg={len(la)} gist={len(lb)}"


def rg_flags() -> tuple[list[str], set[str]]:
    """ripgrep's own documented flag surface, and which entries take a value.

    Both spellings count. A short flag is not a free pass: `-M` and
    `--max-columns` reach the same option through different parser paths (glued
    values, bundling, the `-uu` repetition ladder), and it is the short path that
    a caller's muscle memory actually types.
    """
    comp = subprocess.run(
        [RG, "--generate", "complete-bash"], capture_output=True, text=True, check=True
    ).stdout
    man = subprocess.run(
        [RG, "--generate", "man"], capture_output=True, text=True, check=True
    ).stdout
    plain = man.replace("\\fB", "").replace("\\fP", "").replace("\\fI", "").replace("\\-", "-")

    longs = set(re.findall(r"--[a-z0-9][a-z0-9-]*", comp))
    # A short flag is only documented where the man page's entry line declares
    # it, which is also the only place its long partner is named. Recording the
    # pairing lets a short flag inherit its partner's probe value and declared
    # boundary, so the table below stays keyed on ONE spelling per option.
    for m in re.finditer(r"^-([a-zA-Z0-9]), (--[a-z0-9-]+)", plain, re.M):
        ALIAS[f"-{m.group(1)}"] = m.group(2)
    shorts = set(re.findall(r"^-([a-zA-Z0-9])(?:,|\s|$)", plain, re.M))
    takes = {m.group(1) for m in re.finditer(r"(--[a-z0-9-]+)=", plain)}
    takes |= {s for s in (f"-{c}" for c in shorts) if ALIAS.get(s) in takes}
    return sorted(longs) + sorted(f"-{s}" for s in shorts), takes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", type=Path, help="write the machine record here")
    ap.add_argument("--only", help="probe just the flags containing this substring")
    ap.add_argument("--verbose", action="store_true", help="print every row, not just the losses")
    args = ap.parse_args()

    if not shutil.which(RG):
        print("surface: ripgrep is not on PATH — it IS the denominator here", file=sys.stderr)
        return 2
    if not Path(GIST).exists():
        print(f"surface: no gist at {GIST} (zig build -Doptimize=ReleaseFast)", file=sys.stderr)
        return 2

    longs, takes = rg_flags()
    if args.only:
        longs = [f for f in longs if args.only in f]

    rows, undo = [], []
    with tempfile.TemporaryDirectory() as d:
        fixture(Path(d))
        for flag in longs:
            if flag in takes and declared(VALUES, flag) is None:
                rows.append({"flag": flag, "verdict": "unprobed", "why": "no probe value declared"})
                continue
            rows.append(probe(flag, d))
        if not args.only:
            undo = adverse(d)

    tally = Counter(r["verdict"] for r in rows)
    conforming = tally["identical"] + tally["boundary"]
    pct = 100.0 * conforming / len(rows) if rows else 0.0

    for r in rows:
        if args.verbose or r["verdict"] not in ("identical", "boundary"):
            print(f"  {r['verdict']:<10} {r['flag']:<34} {r.get('why', '')}")
    if tally["boundary"]:
        print("\ndeclared boundaries (each residual verified against rg this run):")
        for r in rows:
            if r["verdict"] == "boundary":
                print(f"  {r['flag']:<20} residual={r['residual']:<9} {r['why']}")
    print(
        f"\nrg documented flags (long + short): {len(rows)}"
        f"  ·  identical {tally['identical']}"
        f"  ·  declared boundary {tally['boundary']}"
        f"  ·  divergent {tally['divergent']}"
        f"  ·  rejected {tally['rejected']}"
        f"  ·  unprobed {tally['unprobed']}"
    )
    print(f"conformance (identical + declared boundary) / documented = {pct:.1f}%")

    undo_bad = [u for u in undo if not u["ok"]]
    if undo:
        for u in undo_bad:
            print(f"  UNDO-FAIL  {u['pair']:<24} {u.get('why', '')}")
        print(f"adverse undo pairs: {len(undo) - len(undo_bad)}/{len(undo)} agree with rg")

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(
            json.dumps(
                {
                    "denominator": len(rows),
                    "denominator_source": "rg --generate complete-bash (longs) + man page entry lines (shorts, value grammar, short↔long pairing)",
                    "rg_version": subprocess.run(
                        [RG, "--version"], capture_output=True, text=True, check=False
                    ).stdout.splitlines()[0],
                    "identical": tally["identical"],
                    "boundary": tally["boundary"],
                    "divergent": tally["divergent"],
                    "rejected": tally["rejected"],
                    "unprobed": tally["unprobed"],
                    "conformance_pct": round(pct, 1),
                    "adverse_total": len(undo),
                    "adverse_passed": len(undo) - len(undo_bad),
                    "rows": rows,
                    "adverse": undo,
                },
                indent=1,
            )
            + "\n"
        )
        print(f"record → {args.json}")
    # Fail-closed: a rejection, an undeclared divergence, an unprobed
    # value-taking flag, or a negation that does not actually negate.
    return 1 if (tally["divergent"] or tally["rejected"] or tally["unprobed"] or undo_bad) else 0


if __name__ == "__main__":
    sys.exit(main())
