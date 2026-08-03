#!/usr/bin/env python3
"""Earn a pull request's labels from facts, and keep the label set honest.

Three rules, one declaration. `.github/labels.json` is the whole taxonomy:
every label the automation may apply says, on its own row, how it is earned —
`paths` (which files moved), `commit` (what the conventional title claims), or
`from` (how many weighted lines changed). A label with none of those is
hand-applied, and this script will never add or remove it. That is the entire
ownership boundary, and it is readable off the config rather than encoded here.

Namespaces are load-bearing rather than decorative. GitHub sorts labels
alphabetically everywhere it lists them, so `area/` `lang/` `size/` `status/`
`topic/` `type/` group themselves in every dropdown, filter, and PR row without
GitHub offering any ordering knob. What stays bare is the issue vocabulary —
`bug`, `enhancement`, `question` — which sits outside every declared namespace,
and that is exactly why `sync --prune` cannot touch it.

Globs read the way .gitignore's do, which is the way anyone who works in this
tree already expects. A pattern holding a `/` is matched against the whole path,
where `*` stops at a separator and `**` spans them — so `src/exec/**` is that
whole subtree while `src/*.zig` is only the modules sitting at the root of
`src/`. A pattern holding no `/` is matched against the file's name at any
depth, so `Cargo.toml` finds the one in `bindings/rust/` without a caller having
to guess how deep it is buried.

    triage.py show   [--json]      the taxonomy as resolved, and what it owns
    triage.py verify               is the config sound? offline, and needs no token
    triage.py sync   [--prune]     reconcile the repository's labels with it
    triage.py apply  --pr N        set the earned labels on one pull request
    triage.py check  --pr N        is the title a conventional commit?

`verify` is what keeps the taxonomy honest, and `sync` refuses to write unless it
passes. It proves the glob and title rules against stated cases, and it fails
when any other file under `.github` — a Dependabot stream, an issue template —
asks for a label no row here declares. GitHub drops an unknown label without a
word, so that pull request simply arrives bare; catching it here is the
difference between a config bug and a mystery.

`--dry-run` prints the plan for `sync` and `apply` without writing. Everything
else shells `gh`, which is preinstalled on every GitHub runner and already the
way this repository talks to its own forge.
"""

from __future__ import annotations

import argparse
import fnmatch
import functools
import json
import os
import re
import subprocess
import sys
from pathlib import Path

TAXONOMY = Path(__file__).resolve().parent.parent / "labels.json"

# A row carrying any of these is machine-owned; a row carrying none is a human's.
TRIGGERS = frozenset({"paths", "commit", "from"})

# Conventional Commits 1.0.0, minus the type vocabulary — that comes from the
# taxonomy, so the accepted prefixes and the `type/*` labels cannot disagree.
# The spec's colon-and-a-space is enforced, so `fix:no space` is a finding
# rather than a near miss — git log renders the two very differently.
TITLE = re.compile(r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<breaking>!)?"
                   r": (?P<subject>.*\S.*)$")

# `labels: bug` and `labels: ["a", "b"]` — the two inline forms GitHub documents
# for Dependabot streams and issue templates. A bare `labels:` opening a nested
# block is deliberately not matched; that key belongs to something else.
CITES = re.compile(r"^[ \t]*labels:[ \t]*(\[[^\]]*\]|[^\[\s#][^#\n]*?)[ \t]*$", re.M)


@functools.lru_cache(maxsize=None)
def _shape(glob: str) -> re.Pattern[str]:
    """.gitignore's wildcards, compiled: `*` stops at a slash and `**` spans them."""
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("/**/", i):      # a/**/b spans zero directories too
            out.append("/(?:.+/)?")
            i += 4
        elif glob.startswith("**/", i) and not i:
            out.append("(?:.+/)?")
            i += 3
        elif glob.startswith("**", i):
            out.append(".*")
            i += 2
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out) + r"\Z")


def hit(path: str, glob: str) -> bool:
    """.gitignore's rule: a slashless pattern is about the name, not the path."""
    if "/" not in glob:
        return fnmatch.fnmatch(path.rpartition("/")[2], glob)
    return _shape(glob).match(path) is not None


def gh(*args: str, check: bool = True) -> str:
    done = subprocess.run(("gh", *args), capture_output=True, text=True)
    if check and done.returncode:
        sys.exit(f"gh {' '.join(args)} failed:\n{done.stderr.strip()}")
    return done.stdout.strip()


def repository() -> str:
    return os.environ.get("GITHUB_REPOSITORY") or gh(
        "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"
    )


class Taxonomy:
    """The declared labels, and the three questions they answer."""

    def __init__(self, doc: dict) -> None:
        self.rows: list[dict] = doc["labels"]
        self.unweighted: tuple[str, ...] = tuple(doc.get("unweighted", ()))
        by_name = {row["name"] for row in self.rows}
        if len(by_name) != len(self.rows):
            sys.exit("labels.json: duplicate label name")

    @classmethod
    def load(cls, path: Path = TAXONOMY) -> "Taxonomy":
        return cls(json.loads(path.read_text()))

    @property
    def owned(self) -> set[str]:
        return {r["name"] for r in self.rows if TRIGGERS & r.keys()}

    @property
    def namespaces(self) -> set[str]:
        return {n.split("/", 1)[0] for n in (r["name"] for r in self.rows) if "/" in n}

    @property
    def types(self) -> dict[str, str]:
        return {r["commit"]: r["name"] for r in self.rows if "commit" in r}

    def matched(self, paths: list[str]) -> set[str]:
        """Labels whose globs any changed path satisfies."""
        return {
            row["name"]
            for row in self.rows
            if any(hit(p, g) for g in row.get("paths", ()) for p in paths)
        }

    def weighed(self, changes: list[tuple[str, int]]) -> int:
        """Changed lines, ignoring the paths nobody reads line by line."""
        return sum(
            lines
            for path, lines in changes
            if not any(hit(path, g) for g in self.unweighted)
        )

    def sized(self, lines: int) -> str | None:
        """The heaviest size floor this diff clears."""
        ladder = sorted((r["from"], r["name"]) for r in self.rows if "from" in r)
        return next((n for floor, n in reversed(ladder) if lines >= floor), None)

    def typed(self, title: str) -> str | None:
        found = TITLE.match(title.strip())
        return self.types.get(found["type"]) if found else None


# The glob rules, stated as the cases that would break if the compiler drifted.
# Each is a claim about .gitignore's behavior, not about this implementation's.
GLOBS = (
    ("src/query.zig", "src/*", True),               # `*` covers one segment
    ("src/exec/query.zig", "src/*", False),         # and stops at the separator
    ("src/exec/query.zig", "src/**", True),         # `**` spans them
    ("src/a/b/c/query.zig", "src/**", True),
    ("src", "src/**", False),                       # the slash has to be there
    ("src/exec", "src/exec/**", False),             # a subtree is not its own root
    ("src/execution/x.zig", "src/exec/**", False),  # nor is a longer sibling
    ("src/query.zig", "src/**/query.zig", True),    # `/**/` spans zero directories
    ("src/a/b/query.zig", "src/**/query.zig", True),
    ("services/vox/main.rs", "**/vox/**", True),    # a leading `**/` is optional
    ("vox/main.rs", "**/vox/**", True),
    ("Cargo.toml", "Cargo.toml", True),             # slashless: the name, any depth
    ("bindings/rust/Cargo.toml", "Cargo.toml", True),
    ("bindings/Cargo.toml.bak", "Cargo.toml", False),
    ("a/b/notes.md", "*.md", True),
    ("a+b/c.rs", "a+b/**", True),                   # path metacharacters are literal
    ("axb/c.rs", "a+b/**", False),
)


# The title grammar, stated as parses rather than as labels, so a repository that
# declares a different set of commit types still holds itself to the same spec.
TITLES = (
    ("feat: add a thing", "feat"),
    ("fix(engine): stop the leak", "fix"),
    ("feat!: drop the old ABI", "feat"),                 # breaking, no scope
    ("refactor(surface)!: rename the verb", "refactor"),  # breaking, with scope
    ("fix:no space", None),                              # the spec wants ": "
    ("fix: ", None),                                     # and a real subject
    ("FIX: shouting", None),
    ("just a sentence", None),
    ("feat(: unbalanced", None),
)


def verify(tax: Taxonomy) -> int:
    """Is the config sound? Offline, tokenless, and safe to run on a fork's PR."""
    bad = [(p, g, want) for p, g, want in GLOBS if hit(p, g) is not want]
    for path, glob, want in bad:
        print(f"::error::glob {glob!r} should{'' if want else ' not'} match {path!r}",
              file=sys.stderr)

    for title, want in TITLES:
        found = TITLE.match(title)
        got = found["type"] if found else None
        if got != want:
            bad.append((title, got, want))
            print(f"::error::title {title!r} parsed as {got!r}, expected {want!r}",
                  file=sys.stderr)

    declared = {row["name"] for row in tax.rows}
    for name, where in sorted(cited(TAXONOMY.parent).items()):
        if name in declared:
            continue
        bad.append((name, where, None))
        print(f"::error file={where[0]}::label {name!r} is asked for by "
              f"{', '.join(sorted(set(where)))} but no row in {TAXONOMY.name} "
              f"declares it, so GitHub will drop it silently", file=sys.stderr)

    dead = sorted(n for n in tax.owned if "/" not in n)
    for name in dead:
        print(f"::error::{name!r} is earned by a rule but sits outside every "
              f"namespace, so `sync --prune` could never clean it up", file=sys.stderr)

    if bad or dead:
        return 1
    print(f"ok: {len(GLOBS)} glob and {len(TITLES)} title cases, {len(declared)} "
          f"labels, {len(tax.types)} commit types, every citation resolves")
    return 0


def cited(root: Path) -> dict[str, list[str]]:
    """Every label another config asks GitHub to apply, and which file asks.

    Dependabot and the issue templates name labels by string, and GitHub silently
    drops the ones that do not exist — no warning, no failed run, just a pull
    request that arrives unlabeled. This is how that stops being invisible.
    """
    asked: dict[str, list[str]] = {}
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in {".yml", ".yaml", ".md"}:
            continue
        for raw in CITES.findall(path.read_text(errors="ignore")):
            for name in raw.strip().strip("[]").split(","):
                name = name.strip().strip("\"'")
                if name:
                    asked.setdefault(name, []).append(str(path.relative_to(root.parent)))
    return asked


def existing(repo: str) -> dict[str, dict]:
    listed = gh("label", "list", "-R", repo, "--limit", "500", "--json",
                "name,color,description")
    return {row["name"]: row for row in json.loads(listed or "[]")}


def sync(tax: Taxonomy, repo: str, prune: bool, dry: bool) -> int:
    # Writing a label set the rest of `.github` contradicts would just make the
    # contradiction permanent, so the config has to hold before anything moves.
    if verify(tax):
        return 1

    have, declared = existing(repo), {row["name"] for row in tax.rows}
    for row in tax.rows:
        name, color = row["name"], row["color"].lstrip("#")
        note = row.get("description", "")
        was = have.get(name)
        if was and was["color"].lower() == color.lower() and was["description"] == note:
            continue
        verb = "update" if was else "create"
        print(f"{verb} {name} #{color} — {note}")
        if not dry:
            gh("label", "create", name, "-R", repo, "--color", color,
               "--description", note, "--force")

    # Only inside a namespace this file declares: a bare label was never ours.
    stale = sorted(
        n for n in have
        if "/" in n and n.split("/", 1)[0] in tax.namespaces and n not in declared
    )
    for name in stale:
        print(f"{'prune' if prune else 'stale (keep)'} {name}")
        if prune and not dry:
            gh("label", "delete", name, "-R", repo, "--yes")

    # Everything else the repository holds. Not a finding and never deleted —
    # a bot's own label lives here, and so does a maintainer's invention — but
    # naming it is the difference between a deliberate exception and a leak,
    # and it is the one kind of drift `verify` cannot see from disk alone.
    for name in sorted(have.keys() - declared - set(stale)):
        print(f"unclaimed {name} #{have[name]['color']}")
    return 0


def touched(repo: str, pr: int) -> list[dict]:
    raw = gh("api", "--paginate", f"repos/{repo}/pulls/{pr}/files",
             "--jq", ".[] | {path: .filename, lines: (.additions + .deletions)}")
    return [json.loads(line) for line in raw.splitlines() if line]


def apply(tax: Taxonomy, repo: str, pr: int, dry: bool) -> int:
    shown = json.loads(gh("pr", "view", str(pr), "-R", repo, "--json", "title,labels"))
    files = touched(repo, pr)
    changes = [(f["path"], f["lines"]) for f in files]
    lines = tax.weighed(changes)

    want = tax.matched([f["path"] for f in files])
    for earned in (tax.sized(lines), tax.typed(shown["title"])):
        if earned:
            want.add(earned)

    on = {label["name"] for label in shown["labels"]}
    add = sorted(want - on)
    drop = sorted((on & tax.owned) - want)
    print(f"#{pr} {len(files)} files, {lines} weighted lines")
    print(f"  keep {sorted(on & want) or '—'}\n  add  {add or '—'}\n  drop {drop or '—'}")
    if dry or not (add or drop):
        return 0

    # A label the taxonomy declares may not exist yet; `gh pr edit` needs it to.
    missing = set(add) - existing(repo).keys()
    for row in (r for r in tax.rows if r["name"] in missing):
        gh("label", "create", row["name"], "-R", repo, "--force",
           "--color", row["color"].lstrip("#"),
           "--description", row.get("description", ""))
    edit = ["pr", "edit", str(pr), "-R", repo]
    for flag, names in (("--add-label", add), ("--remove-label", drop)):
        if names:
            edit += [flag, ",".join(names)]
    gh(*edit)
    return 0


def check(tax: Taxonomy, repo: str, pr: int) -> int:
    title = gh("pr", "view", str(pr), "-R", repo, "--json", "title", "-q", ".title")
    if tax.typed(title):
        print(f"ok: {title}")
        return 0
    types = ", ".join(sorted(tax.types))
    found = TITLE.match(title.strip())
    why = (f"unknown type {found['type']!r}" if found
           else "not shaped like `type: subject` or `type(scope): subject`")
    print(
        f"::error title=Pull request title is not a conventional commit::"
        f"{title!r} is {why}. The squash commit becomes release history, so the "
        f"title is the commit message. Accepted types: {types}. "
        f"Append `!` after the type or scope for a breaking change.",
        file=sys.stderr,
    )
    return 1


def show(tax: Taxonomy, as_json: bool) -> int:
    if as_json:
        print(json.dumps({"owned": sorted(tax.owned), "types": tax.types,
                          "namespaces": sorted(tax.namespaces),
                          "unweighted": list(tax.unweighted)}, indent=2))
        return 0
    # GitHub's order, not the file's: the file groups by family to stay readable,
    # but what a maintainer wants to preview is the dropdown they will actually see.
    for row in sorted(tax.rows, key=lambda r: r["name"]):
        how = next((f"{k}={row[k]}" for k in ("paths", "commit", "from") if k in row),
                   "by hand")
        print(f"{row['name']:22s} #{row['color']:6s}  {how}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parent = argparse.ArgumentParser(add_help=False)
    parent.add_argument("--repo", default=None, help="OWNER/NAME (default: this one)")
    parent.add_argument("--dry-run", action="store_true", dest="dry")

    cli = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    verbs = cli.add_subparsers(dest="verb", required=True)
    verbs.add_parser("show", parents=[parent]).add_argument("--json", action="store_true")
    verbs.add_parser("verify", parents=[parent])
    verbs.add_parser("sync", parents=[parent]).add_argument("--prune", action="store_true")
    for verb in ("apply", "check"):
        verbs.add_parser(verb, parents=[parent]).add_argument("--pr", type=int, required=True)

    args = cli.parse_args(argv)
    tax = Taxonomy.load()
    if args.verb == "show":
        return show(tax, args.json)
    if args.verb == "verify":
        return verify(tax)
    repo = args.repo or repository()
    if args.verb == "sync":
        return sync(tax, repo, args.prune, args.dry)
    if args.verb == "apply":
        return apply(tax, repo, args.pr, args.dry)
    return check(tax, repo, args.pr)


if __name__ == "__main__":
    sys.exit(main())
