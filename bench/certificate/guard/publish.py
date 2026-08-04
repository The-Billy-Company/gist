#!/usr/bin/env python3
"""The publish gate — a bundle may only enter git if it describes a public corpus.

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

WHY THIS EXISTS

Every certificate minted before the split was measured over a private monorepo,
and the bundle said so in five places at once: a `corpus-manifest.tsv` listing
twenty thousand proprietary paths with their sizes and hashes, a `machine.json`
naming that tree's roots and commit, and absolute `/Users/…` invocations in
`command-log.txt` and every `raw/*.json`. So the receipts were gitignored, and a
gate that reads committed evidence has been reporting "pending regeneration"
ever since. The claims stayed in the README; the proof left the repository.

Deleting the evidence was the right call and the wrong equilibrium. The fix is
not to remember to check before committing — it is to make an unpublishable
bundle **fail the mint**, so the question is answered by a gate rather than by
whoever is at the keyboard at 2am.

WHAT IT CHECKS

Three independent leaks, because they have three different shapes:

  1. **Scope.** `machine.json` must declare a `corpus_id` the charter knows, and
     its `roots` must be exactly what that corpus declares. A bundle minted over
     a tree nobody can fetch is unreproducible even when it leaks nothing.
  2. **Inventory.** Every `corpus-manifest.tsv` path must be repo-relative and
     under a prefix the charter allows. This is the big one: a manifest IS a
     file listing, so a private corpus cannot be partially redacted out of it.
  3. **Invocation.** No absolute home path, and no charter-denied substring, may
     appear anywhere in the bundle's text — the command log, the hyperfine
     exports, the machine metadata, or the certificate prose. An absolute path
     is both a leak and a reproducibility defect: nobody else has that directory.

The charter is `bench/certificate/corpus.toml`, per package and committed. It is
NOT vendored — what counts as a public corpus is a property of what the package
measures — but its schema is enforced here, and a malformed or absent charter
fails closed rather than waving a bundle through.
"""

from __future__ import annotations

import re
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
CERTIFICATE = HERE.parent  # guard → certificate
CHARTER_PATH = CERTIFICATE / "corpus.toml"

#: Absolute user-directory roots. Present in a bundle, each is simultaneously a
#: privacy leak and a reproducibility defect, which is why one pattern covers
#: both findings. The last alternative is the Windows spelling of the mistake.
HOME_PATHS = re.compile(r"(?:/Users/|/home/|/root/|[A-Za-z]:[\\/]Users[\\/])[^\s\"']*")

#: Files whose full text is scanned for leaked invocations. `raw/` is globbed.
SCANNED = ("command-log.txt", "machine.json", "CERTIFICATE.md", "tool-versions.txt")


@dataclass(frozen=True, slots=True)
class Corpus:
    """One publishable corpus, as `corpus.toml` declares it."""

    corpus_id: str
    description: str
    roots: tuple[str, ...]
    allow_prefixes: tuple[str, ...]
    fetch: str
    #: Optional path-and-bytes digest of the whole corpus. When a corpus is
    #: *generated* rather than cloned, this is what turns "run this recipe" into
    #: a verifiable claim: a reader regenerates the tree and compares. Cloned
    #: corpora pin a tag instead and leave it empty.
    sha256: str = ""


@dataclass(frozen=True, slots=True)
class PublishCharter:
    """The package's publishable-corpus policy."""

    corpora: dict[str, Corpus]
    deny_substrings: tuple[str, ...]

    def corpus(self, corpus_id: object) -> Corpus | None:
        """The declared corpus with this id, or None when it is unknown."""
        return self.corpora.get(corpus_id) if isinstance(corpus_id, str) else None


def load_charter(path: Path = CHARTER_PATH) -> tuple[PublishCharter | None, list[str]]:
    """Parse `corpus.toml`. A missing or malformed charter is a finding, not a default."""
    if not path.is_file():
        return None, [
            f"no publishable-corpus charter at {path} — a bundle cannot be judged "
            "public-safe without one (see the certificate README)"
        ]
    try:
        doc = tomllib.loads(path.read_text())
    except (OSError, tomllib.TOMLDecodeError) as error:
        return None, [f"{path.name} is not valid TOML: {error}"]

    problems: list[str] = []
    corpora: dict[str, Corpus] = {}
    for corpus_id, row in (doc.get("corpus") or {}).items():
        if not isinstance(row, dict):
            problems.append(f"{path.name}: [corpus.{corpus_id}] must be a table")
            continue
        missing = [k for k in ("description", "roots", "allow_prefixes", "fetch") if k not in row]
        if missing:
            problems.append(f"{path.name}: [corpus.{corpus_id}] missing {', '.join(missing)}")
            continue
        corpora[corpus_id] = Corpus(
            corpus_id=corpus_id,
            description=str(row["description"]),
            roots=tuple(str(x) for x in row["roots"]),
            allow_prefixes=tuple(str(x) for x in row["allow_prefixes"]),
            fetch=str(row["fetch"]),
            sha256=str(row.get("sha256", "")),
        )
    if not corpora:
        problems.append(f"{path.name}: declares no [corpus.<id>] — nothing is publishable")
    deny = tuple(str(x) for x in (doc.get("deny") or {}).get("substrings", ()))
    return PublishCharter(corpora, deny), problems


def roots_of(recorded: object) -> tuple[str, ...]:
    """The corpus roots a mint recorded, however that mint chose to spell them.

    Shell mints write the roots as one space-separated string (`"${ROOTS[*]}"`);
    a JSON-native producer would write a list. Both mean the same scope, and a
    comparison that only understood one of them would iterate a string into
    characters and report a mismatch that is really a spelling difference.

    """
    if isinstance(recorded, str):
        return tuple(recorded.split())
    return tuple(str(x) for x in recorded) if isinstance(recorded, (list, tuple)) else ()


def _scan_text(name: str, text: str, charter: PublishCharter) -> list[str]:
    """Absolute home paths and charter-denied substrings anywhere in one file."""
    problems = []
    for hit in dict.fromkeys(HOME_PATHS.findall(text)):
        problems.append(
            f"{name}: absolute home path {hit!r} — the bundle records a directory "
            "only this machine has; mint with package-relative invocations"
        )
    problems.extend(
        f"{name}: contains denied substring {denied!r} (corpus.toml [deny].substrings)"
        for denied in charter.deny_substrings
        if denied in text
    )
    return problems


def check_public_safe(bundle: Path, meta: dict[str, object]) -> list[str]:
    """Every reason this bundle must not be committed. Empty means publishable."""
    charter, problems = load_charter()
    if charter is None:
        return problems

    corpus = charter.corpus(meta.get("corpus_id"))
    if corpus is None:
        known = ", ".join(sorted(charter.corpora)) or "(none)"
        problems.append(
            f"machine.json corpus_id={meta.get('corpus_id')!r} is not a declared "
            f"publishable corpus — known: {known}. Re-mint over one of them, or "
            f"add it to corpus.toml with a fetch recipe a stranger can run."
        )
    else:
        minted_roots = roots_of(meta.get("roots"))
        if minted_roots != corpus.roots:
            problems.append(
                f"machine.json roots={list(minted_roots)} != corpus "
                f"{corpus.corpus_id} roots={list(corpus.roots)} — the bundle measured a "
                "different scope than the one it names"
            )
        minted = str(meta.get("corpus_sha256") or "")
        if corpus.sha256 and minted != corpus.sha256:
            problems.append(
                f"machine.json corpus_sha256={minted[:16] or '(absent)'}… != corpus "
                f"{corpus.corpus_id} sha256={corpus.sha256[:16]}… — the bundle did not "
                f"measure the tree its charter describes. Regenerate with: {corpus.fetch}"
            )

    manifest = bundle / "corpus-manifest.tsv"
    if manifest.is_file() and corpus is not None:
        offenders: list[str] = []
        for line_no, line in enumerate(manifest.read_text(errors="replace").splitlines(), 1):
            path = line.split("\t", 1)[0]
            if not path or path == "path":
                continue
            if path.startswith(("/", "~")) or ".." in Path(path).parts:
                offenders.append(f"line {line_no}: {path} is not repo-relative")
            elif not any(path.startswith(prefix) for prefix in corpus.allow_prefixes):
                offenders.append(f"line {line_no}: {path}")
            if len(offenders) >= 5:
                break
        if offenders:
            problems.append(
                f"corpus-manifest.tsv lists paths outside corpus {corpus.corpus_id} "
                f"(allowed: {', '.join(corpus.allow_prefixes)}):\n      "
                + "\n      ".join(offenders)
                + "\n      … a manifest is a full file listing; it cannot be partly redacted."
            )

    for name in SCANNED:
        candidate = bundle / name
        if candidate.is_file():
            problems.extend(_scan_text(name, candidate.read_text(errors="replace"), charter))
    for raw in sorted((bundle / "raw").glob("*.json")):
        problems.extend(_scan_text(f"raw/{raw.name}", raw.read_text(errors="replace"), charter))

    return problems


def main() -> int:
    """Report this package's publishable corpora, for a human deciding where to mint.

    `roots <id>` and `fetch <id>` are the machine forms, read by the vendored
    floor (`bench/apparatus/field.sh`) so that a mint never has to know what a
    corpus id MEANS. The charter states the roots and the recipe; the floor runs
    them. Adding a corpus is then a charter edit rather than a shell edit, and
    two packages certifying over one id cannot drift into two different trees.

    `roots` also lets the floor check BEFORE measuring that the tree it is about
    to walk is the corpus the bundle will claim. That agreement used to be
    checked only at publish — minutes too late, and skippable: a mint that never
    published could measure any tree at all while stamping a declared id on it.
    """
    charter, problems = load_charter()
    if (verb := sys.argv[1:2] and sys.argv[1]) in ("roots", "fetch"):
        if charter is None or len(sys.argv) != 3:
            print(f"usage: publish.py {verb} <corpus-id>", file=sys.stderr)
            return 2
        corpus = charter.corpora.get(sys.argv[2])
        if corpus is None:
            known = ", ".join(sorted(charter.corpora)) or "(none)"
            print(f"publish: no corpus {sys.argv[2]!r} in {CHARTER_PATH.name}; declared: {known}",
                  file=sys.stderr)
            return 2
        print(" ".join(corpus.roots) if verb == "roots" else corpus.fetch)
        return 0
    for problem in problems:
        print(f"  - {problem}")
    if charter is None:
        return 1
    print(f"publishable corpora declared in {CHARTER_PATH.name}:")
    for corpus in charter.corpora.values():
        print(f"\n  {corpus.corpus_id} — {corpus.description}")
        print(f"    roots    {' '.join(corpus.roots)}")
        print(f"    allows   {' '.join(corpus.allow_prefixes)}")
        print(f"    fetch    {corpus.fetch}")
    if charter.deny_substrings:
        print(f"\n  never present: {', '.join(charter.deny_substrings)}")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
