#!/usr/bin/env python3
r"""gist INDEXED-PCRE2 correctness — differential vs an INDEPENDENT engine (Python `re`).

gist is (as far as we know) the only tool that runs PCRE2 *behind a trigram/shadow
index*: the persisted index elides *reading* files a required-literal (or shadow-
spliced) analysis proves can't match, and vendored PCRE2-JIT runs only on the
survivors (`src/kernel/regex/pcre2/`, `serial.zig` `trigramFilter`/`IndexSkip`).
That is the whole win — and its whole risk: a prefilter that drops a file which
really matches is a silent FALSE NEGATIVE. Fast-but-wrong is a lie.

Two existing gates each have a blind spot this one closes:
  • `index_elision_parity.sh` proves `indexed == --no-index` — but the oracle is
    gist against ITSELF, so a bug in gist's PCRE2 wiring hides.
  • `bench/rgsuite/modes.py` proves `gist -P == rg -P` — but ripgrep's `-P` is ALSO
    PCRE2, so a shared PCRE2 semantic bug hides.

The independent oracle here is Python's stdlib `re` — the `sre` bytecode VM, a
different engine lineage from PCRE2 entirely — scanning the RAW corpus bytes. So
parity means the indexed answer is RIGHT, not merely "PCRE2-self-consistent." It is
a THREE-WAY differential per pattern, reported so a break localizes:

  oracle  = Python `re.search` per line over raw bytes            (independent truth)
  idx     = gist -P --no-pcre2-unicode -n -H  WITH the on-disk index (the path we ship)
  noidx   = idx + --no-index                                       (gist's own full scan)

  idx == oracle   → INDEPENDENT PARITY  (the indexed set is semantically correct)
  idx == noidx    → INDEX SAFETY        (elision changed speed, never results)

The corpus is engineered to break a naïve prefilter, so correctness is only
interesting BECAUSE of the index:
  • decoys carrying the required literal's trigrams that PCRE2 must REJECT
    (lookahead fails, backref mismatch) — exactness under an admitted-but-no-match set;
  • a shadow-splice pattern `(foo)bar\1` whose literal is the 9-byte "foobarfoo";
  • a literal-free backref `(\w{3,})\s+\1` the prefilter can't help at all (full scan);
  • hundreds of trigram-free noise files that MUST be elided yet never surface;
  • a post-index edit (freshness) that gains a match and must still be found.

Engine parity is kept honest: `--no-pcre2-unicode` (ASCII byte classes) is matched
against Python **bytes** patterns, compared at LINE-EXISTENCE granularity (not spans,
where greedy/empty-match rendering legitimately differs), under rg's line-terminator
model. PCRE-only constructs (`\z`, `\<`, `\>`, possessive/atomic) are out of scope;
lookaround, backreferences and `(?P<name>)` are genuinely shared by both engines.

stdlib-only. The corpus + index are built in a temp dir under a temp `GIST_DIR`, so
this never touches a coworker's real index. Subcommand: run.
"""

from __future__ import annotations

import argparse
import atexit
from dataclasses import dataclass, field
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time


HERE = Path(__file__).resolve().parent
KERNEL = HERE.parents[3]  # oracle → gates → conformance → bench → repo

# gist soft-caps its own output (agent-context guard); lift it so a high-hit query
# is byte-complete for the set comparison. The hard OOM ceiling stays on.
os.environ.setdefault("GIST_UNCAP", "1")


def _find_gist() -> str:
    """Resolve the gist ReleaseFast binary — `GIST_BIN` override, else build it.
    Always absolute: the differential runs gist with `cwd` set to the corpus."""
    if env := os.environ.get("GIST_BIN"):
        return str(Path(env).resolve())
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


# ───────────────────────── independent oracle (Python `re`) ─────────────────────────

Hit = tuple[str, int]  # (relpath, 1-based line number)


def _lines(data: bytes) -> list[bytes]:
    """Split `data` into lines under ripgrep's terminator model: each `\\n` ends a
    line; a trailing `\\n` opens no phantom empty final line; content after the last
    `\\n` is still a line; the empty file has zero lines."""
    if not data:
        return []
    body = data[:-1] if data.endswith(b"\n") else data
    return body.split(b"\n")


def _walk(corpus: Path) -> list[str]:
    """Every regular file gist would search, as posix relpaths — skipping the dotfiles
    and VCS/build dirs gist's walk prunes (the corpus never plants any, so this is
    just the same universe both sides see)."""
    out: list[str] = []
    for p in sorted(corpus.rglob("*")):
        if p.is_file() and not any(part.startswith(".") for part in p.relative_to(corpus).parts):
            out.append(p.relative_to(corpus).as_posix())
    return out


def oracle_hits(pattern: str, corpus: Path, files: list[str]) -> set[Hit] | None:
    """The independent ground truth: `(relpath, lineno)` for every line whose RAW
    bytes `re.search` accepts. `None` when Python rejects the pattern (grammar scope —
    the case isn't comparable, exactly like the Zig differentials' tri-state skip)."""
    try:
        rx = re.compile(pattern.encode())
    except re.error:
        return None
    hits: set[Hit] = set()
    for rel in files:
        for i, line in enumerate(_lines((corpus / rel).read_bytes()), start=1):
            if rx.search(line):
                hits.add((rel, i))
    return hits


# ───────────────────────── gist under test ─────────────────────────


@dataclass
class GistOut:
    hits: set[Hit]
    rc: int


def gist_hits(gist: str, pattern: str, corpus: Path, *, indexed: bool) -> GistOut:
    """Run `gist -P --no-pcre2-unicode -n -H <pattern>` over the corpus (cwd) and parse
    the `path:lineno:` prefix of every emitted line into the hit set. `indexed=False`
    appends `--no-index` (gist's own full-scan oracle). rc: 0 match / 1 none / 2 error."""
    argv = ["-P", "--no-pcre2-unicode", "-n", "-H", "-e", pattern]
    if not indexed:
        argv.append("--no-index")
    p = subprocess.run(
        [gist, *argv],
        cwd=str(corpus),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=90,
    )
    hits: set[Hit] = set()
    for ln in p.stdout.split(b"\n"):
        if not ln:
            continue
        parts = ln.split(b":", 2)
        if len(parts) < 3 or not parts[1].isdigit():
            continue
        rel = parts[0].decode("utf-8", "replace")
        rel = rel[2:] if rel.startswith("./") else rel
        hits.add((rel, int(parts[1])))
    return GistOut(hits, p.returncode)


# ───────────────────────── adversarial corpus ─────────────────────────


@dataclass
class Pat:
    """One adversarial pattern + why it stresses the indexed-PCRE2 path."""

    pat: str
    why: str


# Each pattern is hand-verified to live in the PCRE2 ∩ Python-`re` shared core, so a
# divergence is a real gist bug, never an engine-gap artifact. The corpus below plants
# matches, literal-carrying decoys, and noise for every one.
CURATED = [
    Pat(r"func\s+\w+\(", "required literal 'func'; plain regex, index-prefiltered"),
    Pat(r"func\s+\w+(?=\()", "lookahead: 'func' required, '(' is zero-width — decoys carry 'func'"),
    Pat(r"import\s+(?!type)\w+", "neg-lookahead: 'import' required; 'import type' decoys must reject"),
    Pat(r"(?<=@)\w+", "lookbehind: only the tail is consumed; '@' is the prefilter anchor"),
    Pat(r"(?<!no_)Handler", "neg-lookbehind: 'no_Handler' decoys must reject, 'Handler' required"),
    Pat(r"(\w+) \1", "backref: repeated word — literal-free, prefilter declines to full scan"),
    Pat(r"(\w{3,})\s+\1", "backref, literal-free by construction — the hardest full-scan class"),
    Pat(r"(foo)bar\1", "shadow-splice: required literal upgrades to the 9-byte 'foobarfoo'"),
    Pat(r"(?P<w>\w+)-(?P=w)", "named backref: 'ab-ab' matches, 'ab-cd' (a decoy) rejects"),
    Pat(r"(?i)error", "caseless literal: ASCII fold only under --no-pcre2-unicode"),
    Pat(r"^\s*return\b", "anchored + word boundary; 'return' required"),
    Pat(r"\bTODO\b", "word-bounded literal; 'TODOS'/'aTODO' decoys must reject"),
    Pat(r"WalletService", "rare literal — the elision showcase (touched files ≈ the hits)"),
    Pat(r"0x[0-9a-f]{2,}", "class + counted repetition; '0x' below the trigram floor → full scan"),
    Pat(r"[A-Z][a-z]{2,}\d+", "mixed class run; no usable literal → full scan, must stay exact"),
]


def gen_corpus(root: Path) -> None:
    """Write the adversarial corpus. Signal files carry deliberate matches AND
    literal-carrying decoys (admitted by the prefilter, rejected by PCRE2); bulk noise
    carries none of the trigrams so it must be elided yet never surface."""
    root.mkdir(parents=True, exist_ok=True)

    def w(name: str, text: str) -> None:
        p = root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(text.encode())

    # Signal: genuine matches for the curated patterns.
    w("src/handlers.go", "\n".join([
        "func Serve(w http.ResponseWriter) {",       # func\s+\w+\( and lookahead
        "func handle(r *Request) error {",
        "\treturn nil",                                 # ^\s*return\b
        "\t// TODO wire the WalletService here",       # \bTODO\b, WalletService
        "}",
    ]) + "\n")
    w("src/imports.go", "\n".join([
        "import fmt",                                   # import\s+(?!type)
        "import strings",
        "// import type decoy — neg-lookahead must reject this line",  # decoy for import(?!type)
    ]) + "\n")
    w("src/refs.txt", "\n".join([
        "ping @griffin now",                            # (?<=@)\w+
        "email me @support later",
        "hello hello world",                            # (\w+) \1 and (\w{3,})\s+\1
        "the the end",
        "ab-ab pair",                                   # (?P<w>\w+)-(?P=w)
        "ab-cd decoy",                                  # named-backref decoy (rejects)
    ]) + "\n")
    w("src/shadow.txt", "\n".join([
        "foobarfoo spliced",                            # (foo)bar\1 via shadow literal
        "foobar foo apart — decoy, no splice",          # decoy: has foo+bar+foo, not contiguous
    ]) + "\n")
    w("src/mixed.txt", "\n".join([
        "ERROR loud",                                   # (?i)error
        "silent error here",
        "addr 0xDEADbeef 0x4f",                         # 0x[0-9a-f]{2,}
        "Widget42 and Gadget7",                         # [A-Z][a-z]{2,}\d+
        "no_Handler is a decoy",                        # neg-lookbehind decoy (rejects)
        "the real Handler runs",                        # (?<!no_)Handler matches
    ]) + "\n")

    # Literal-carrying decoys that the prefilter ADMITS but PCRE2 must REJECT — proves
    # exactness (no over-match) and that the survivor set is genuinely PCRE2-checked.
    w("src/decoys.txt", "\n".join([
        "func = lambda x: x",                           # 'func' present, no \s+\w+\(
        "refunc(y)",                                    # 'func' substring, lookahead context absent
        "funcy foobar()",                               # 'func' then non-space → no match
        "TODOS list",                                   # 'TODO' present, \b fails
        "aTODO note",
        "importance matters",                           # 'import' substring, \s+ absent
    ]) + "\n")

    # Overwhelming noise: none of the trigrams above, so every file is elided by the
    # index yet must never appear in any result set (false-positive floor).
    for i in range(180):
        w(f"noise/pkg_{i}.go", f"package noise{i}\n\ntype ty{i} struct {{ v int }}\n")


# ───────────────────────── safe-core generator (breadth) ─────────────────────────


class Gen:
    """A conservative generator over the PCRE2 ∩ Python-`re` shared core. No unbounded
    quantifier ever sits on a group (kills catastrophic backtracking Python can't
    time-out of), no PCRE-only constructs. Lookahead/backref use literals only, so a
    generated pattern is always comparable when both engines accept it."""

    ATOMS = ("a", "b", "c", "A", "0", "1", "_", ".", r"\d", r"\w", r"\s", "[a-c]", "[^a-c]", "[0-9]")
    QUANTS = ("", "*", "+", "?", "{1,2}", "{2,3}", "*?", "+?")

    def __init__(self, r: random.Random):
        self.r = r

    def _atom(self) -> str:
        return self.r.choice(self.ATOMS) + self.r.choice(self.QUANTS)

    def pattern(self) -> str:
        parts = ["^"] if self.r.random() < 0.3 else []
        n = 1 + self.r.randrange(3)
        for _ in range(n):
            roll = self.r.random()
            if roll < 0.15:  # lookahead / neg-lookahead on a literal
                parts.append(("(?=" if self.r.random() < 0.5 else "(?!") + self.r.choice("abc") + ")")
            elif roll < 0.25:  # a capture + later backref
                parts.append(r"(\w+)")
            else:
                parts.append(self._atom())
        if r"(\w+)" in "".join(parts) and self.r.random() < 0.6:
            parts.append(r"\1")
        if self.r.random() < 0.3:
            parts.append("$")
        return "".join(parts)


# ───────────────────────── differential run ─────────────────────────


@dataclass
class Report:
    parity: list[str] = field(default_factory=list)  # idx != oracle (semantic)
    safety: list[str] = field(default_factory=list)  # idx != noidx (elision dropped/added)
    checked: int = 0
    skipped: int = 0


def _diff(a: set[Hit], b: set[Hit], la: str, lb: str) -> str:
    only_a = sorted(a - b)[:4]
    only_b = sorted(b - a)[:4]
    return f"only-in-{la}={only_a}  only-in-{lb}={only_b}"


def check(gist: str, corpus: Path, files: list[str], pattern: str, rep: Report, why: str = "") -> None:
    """One three-way comparison: gist-indexed vs Python-`re` oracle vs gist --no-index."""
    oracle = oracle_hits(pattern, corpus, files)
    idx = gist_hits(gist, pattern, corpus, indexed=True)
    if oracle is None or idx.rc == 2:  # either engine declined ⇒ grammar scope, skip
        rep.skipped += 1
        return
    noidx = gist_hits(gist, pattern, corpus, indexed=False)
    rep.checked += 1
    tag = f"/{pattern}/" + (f"  [{why}]" if why else "")
    if idx.hits != oracle:
        rep.parity.append(f"{tag}\n    {_diff(idx.hits, oracle, 'gist', 'python')}")
    if idx.hits != noidx.hits:
        rep.safety.append(f"{tag}\n    {_diff(idx.hits, noidx.hits, 'indexed', 'no-index')}")


def do_run(gist: str, corpus: Path, seeds: int) -> int:
    """Index the corpus, run curated + generated + freshness three-way checks."""
    env = {**os.environ}
    subprocess.run([gist, "index"], cwd=str(corpus), env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    files = _walk(corpus)
    rep = Report()

    print(f"=== indexed-PCRE2 oracle: {len(CURATED)} curated + {seeds} generated over {len(files)} files ===")
    for pc in CURATED:
        check(gist, corpus, files, pc.pat, rep, pc.why)

    for seed in range(seeds):
        g = Gen(random.Random(seed * 0x9E3779B97F4A7C15))
        check(gist, corpus, files, g.pattern(), rep)

    # Freshness: append a match to a noise file that had NONE at index time. The
    # index's trigram data is now stale; the freshness overlay (mtime > anchor) must
    # still force the read so the indexed run finds it — else a silent false negative.
    time.sleep(1.1)
    (corpus / "noise" / "pkg_7.go").write_text(
        "package noise7\n\nfunc LateService() error { return nil } // WalletService arrives late\n"
    )
    fresh_files = _walk(corpus)
    for pat in (r"WalletService", r"func\s+\w+\(", r"^\s*return\b"):
        check(gist, corpus, fresh_files, pat, rep, "freshness (post-index edit)")

    print(f"\nchecked={rep.checked}  skipped(grammar-scope)={rep.skipped}")
    if not rep.parity and not rep.safety:
        print("✓ ALL PASS — indexed PCRE2 == Python re (independent parity) and == --no-index (index safety)")
        return 0
    for f in rep.parity:
        print("✗ PARITY   " + f)
    for f in rep.safety:
        print("⚠ SAFETY   " + f)
    print(f"\n{len(rep.parity)} parity fail(s), {len(rep.safety)} index-safety fail(s)")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run", help="build an adversarial corpus, index it, run the differential")
    pr.add_argument("--seeds", type=int, default=200, help="generated safe-core patterns")
    a = ap.parse_args()
    if a.cmd != "run":
        return 0

    work = Path(tempfile.mkdtemp(prefix="gist-idxpcre-"))
    atexit.register(lambda: shutil.rmtree(work, ignore_errors=True))
    # Hermetic index home — never touch a coworker's real .local/gist-verify.
    os.environ["GIST_DIR"] = str(work / "gist-dir")
    corpus = work / "corpus"
    gen_corpus(corpus)
    gist = _find_gist()
    print(f"gist={gist}\nGIST_DIR={os.environ['GIST_DIR']}\ncorpus={corpus}\n")
    return do_run(gist, corpus, a.seeds)


if __name__ == "__main__":
    sys.exit(main())
