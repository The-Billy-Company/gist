#!/usr/bin/env python3
"""Earn a pull request's labels from facts, and keep the label set honest.

One declaration, and a row that says how it is earned. `.github/labels.json` is
the whole taxonomy: every label the automation may apply carries `paths` (which
files moved), `commit` (what the conventional title claims), `from` (how many
weighted lines changed), or `when` (a fact about an issue, like nobody having
classified it yet). A label with none of those is hand-applied, and this script
will never add or remove it. That is the entire ownership boundary, and it is
readable off the config rather than encoded here.

The boundary also narrows by subject, because only a pull request has a diff
and only an issue can be sitting unread. So `paths` and `from` are never asked
of an issue, `when` is never asked of a pull request, and neither can strip a
label the other earned.

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
    triage.py peers                do the sibling checkouts still agree?
    triage.py sync   [--prune]     reconcile the repository's labels with it
    triage.py apply  --pr N        set the earned labels on one pull request
    triage.py apply  --issue N     the same, for an issue: its type, and whether
                                   anybody has read it yet
    triage.py check  --pr N        is the title a conventional commit?

`verify` is what keeps the taxonomy honest, and `sync` refuses to write unless it
passes. It proves the glob and title rules against stated cases, and it fails
when any other file under `.github` — a Dependabot stream, an issue template —
asks for a label no row here declares. GitHub drops an unknown label without a
word, so that pull request simply arrives bare; catching it here is the
difference between a config bug and a mystery.

`--dry-run` prints the plan for `sync` and `apply` without writing.

Two forges, one set of rules. A label set is not a GitHub concept, so the only
part of this that knows which forge it is talking to is the wire: GitHub through
the `gh` CLI every runner carries, Forgejo through its own REST API, which `gh`
cannot speak at all. Forgejo announces itself by exporting `FORGEJO_API_URL` and
`FORGEJO_TOKEN`, so nothing has to be configured and a GitHub run never notices.
"""

from __future__ import annotations

import argparse
import contextlib
import fnmatch
import functools
import io
import json
import os
import pathlib
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

# Imported as a module rather than `from pathlib import Path`, so this file has no
# from-import to place. The same bytes are linted by five repositories, and their
# isort settings disagree about where a from-import belongs among the plain ones;
# with none present, there is nothing left for them to disagree about.
TAXONOMY = pathlib.Path(__file__).resolve().parent.parent / "labels.json"

# Only a pull request has a diff, and only an issue can be sitting unread, so a
# trigger is legible for one subject or the other. `commit` reads a title, which
# both of them have. A row carrying none of these is a human's, on either.
REACH = {
    "pr": frozenset({"paths", "commit", "from"}),
    "issue": frozenset({"commit", "when"}),
}
TRIGGERS = frozenset().union(*REACH.values())

# The closed vocabulary for `when`. `unlabeled` is a fact about the issue rather
# than a reading of its text: nobody has classified it yet.
WHENS = frozenset({"unlabeled"})

# Conventional Commits 1.0.0, minus the type vocabulary — that comes from the
# taxonomy, so the accepted prefixes and the `type/*` labels cannot disagree.
# The spec's colon-and-a-space is enforced, so `fix:no space` is a finding
# rather than a near miss — git log renders the two very differently.
TITLE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]+)\))?(?P<breaking>!)?"
    r": (?P<subject>.*\S.*)$"
)

# `labels: bug` and `labels: ["a", "b"]` — the two inline forms GitHub documents
# for Dependabot streams and issue templates. A bare `labels:` opening a nested
# block is deliberately not matched; that key belongs to something else.
CITES = re.compile(r"^[ \t]*labels:[ \t]*(\[[^\]]*\]|[^\[\s#][^#\n]*?)[ \t]*$", re.MULTILINE)


@functools.cache
def _shape(glob: str) -> re.Pattern[str]:
    """.gitignore's wildcards, compiled: `*` stops at a slash and `**` spans them."""
    out, i = [], 0
    while i < len(glob):
        if glob.startswith("/**/", i):  # a/**/b spans zero directories too
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


class Hub:
    """GitHub, spoken through the `gh` CLI every runner already carries."""

    def __init__(self, repo: str | None) -> None:
        self.repo = (
            repo
            or os.environ.get("GITHUB_REPOSITORY")
            or self.gh("repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner")
        )

    def gh(self, *args: str) -> str:
        # S603/S607: `gh` is resolved from PATH by name on purpose — it is
        # preinstalled on every GitHub runner and lives at a different path on each
        # platform, so a hardcoded one would be the fragile spelling. No shell is
        # involved and no argument is ever built from a pull request's contents.
        done = subprocess.run(  # noqa: S603
            ("gh", *args),  # noqa: S607
            capture_output=True,
            text=True,
            check=False,
        )
        if done.returncode:
            sys.exit(f"gh {' '.join(args)} failed:\n{done.stderr.strip()}")
        return done.stdout.strip()

    def labels(self) -> dict[str, dict]:
        listed = self.gh(
            "label",
            "list",
            "-R",
            self.repo,
            "--limit",
            "500",
            "--json",
            "name,color,description",
        )
        return {row["name"]: row for row in json.loads(listed or "[]")}

    def write(self, name: str, color: str, note: str) -> None:
        self.gh(
            "label",
            "create",
            name,
            "-R",
            self.repo,
            "--force",
            "--color",
            color,
            "--description",
            note,
        )

    def erase(self, name: str) -> None:
        self.gh("label", "delete", name, "-R", self.repo, "--yes")

    def subject(self, kind: str, number: int) -> dict:
        shown = json.loads(
            self.gh(kind, "view", str(number), "-R", self.repo, "--json", "title,labels")
        )
        return {
            "title": shown["title"],
            "pull": kind == "pr",
            "labels": {row["name"] for row in shown["labels"]},
        }

    def files(self, number: int) -> list[tuple[str, int]]:
        raw = self.gh(
            "api",
            "--paginate",
            f"repos/{self.repo}/pulls/{number}/files",
            "--jq",
            ".[] | [.filename, (.additions + .deletions)] | @tsv",
        )
        return [
            (path, int(lines))
            for path, lines in (line.split("\t") for line in raw.splitlines() if line)
        ]

    def relabel(self, kind: str, number: int, add: list[str], drop: list[str]) -> None:
        edit = [kind, "edit", str(number), "-R", self.repo]
        for flag, names in (("--add-label", add), ("--remove-label", drop)):
            if names:
                edit += [flag, ",".join(names)]
        self.gh(*edit)


class Forge:
    """Forgejo, over its own REST API, because `gh` cannot speak to it at all.

    Same taxonomy, same rules, same reconciliation — a label set is not a GitHub
    concept, and the only thing that differs between the two forges is the wire.
    Forgejo's own runner mints `FORGEJO_TOKEN` for the life of a workflow and
    scopes it to the one repository, and its documentation names changing labels
    as the reason `pull_request_target` exists there too.

    Two shapes differ enough to be worth naming. A label is edited and deleted by
    numeric id rather than by name, so the map is held and kept current as rows
    are written rather than re-fetched. And a pull request is an issue that
    happens to have a diff — both are addressed under `issues/{index}`, and only
    that route carries labels — so `kind` does not change the path here.
    """

    def __init__(self, api: str, token: str, repo: str) -> None:
        # The endpoint arrives from the environment, and a bearer token is about to
        # be attached to every request made to it. `urlopen` speaks file: and ftp:
        # as readily as https:, so a wrong-scheme value would not fail — it would
        # quietly read a local path, or send the token somewhere in the clear.
        if urllib.parse.urlparse(api).scheme not in {"http", "https"}:
            sys.exit(f"FORGEJO_API_URL must be an http(s) endpoint, not {api!r}")
        self.api, self.token, self.repo = api.rstrip("/"), token, repo
        self.known: dict[str, dict] | None = None

    def call(self, method: str, path: str, body: dict | None = None) -> object:
        data = json.dumps(body).encode() if body is not None else None
        # Both S310s below are the same audit — is the scheme one urlopen should
        # honor — and `__init__` is the only place a scheme enters this class.
        ask = urllib.request.Request(  # noqa: S310
            f"{self.api}/repos/{self.repo}/{path}",
            data=data,
            method=method,
        )
        ask.add_header("Authorization", f"token {self.token}")
        if data:
            ask.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(ask, timeout=30) as answer:  # noqa: S310
                raw = answer.read()
        except urllib.error.HTTPError as refused:
            sys.exit(
                f"forgejo {method} {path} → {refused.code}: "
                f"{refused.read().decode(errors='replace')[:400]}"
            )
        return json.loads(raw) if raw else None

    def paged(self, path: str) -> list[dict]:
        joiner = "&" if "?" in path else "?"
        out, page = [], 1
        while chunk := self.call("GET", f"{path}{joiner}limit=100&page={page}"):
            out += chunk
            if len(chunk) < 100:
                break
            page += 1
        return out

    def labels(self) -> dict[str, dict]:
        if self.known is None:
            self.known = {row["name"]: row for row in self.paged("labels")}
        return self.known

    def write(self, name: str, color: str, note: str) -> None:
        body = {"name": name, "color": f"#{color}", "description": note}
        known = self.labels()
        # A create has to hand back the row it minted, or the next write would
        # have no id to PATCH and would try to create the same label again.
        known[name] = (
            self.call("PATCH", f"labels/{known[name]['id']}", body)
            if name in known
            else self.call("POST", "labels", body)
        )

    def erase(self, name: str) -> None:
        self.call("DELETE", f"labels/{self.labels().pop(name)['id']}")

    def subject(self, kind: str, number: int) -> dict:
        shown = self.call("GET", f"issues/{number}")
        return {
            "title": shown["title"],
            "pull": shown.get("pull_request") is not None,
            "labels": {row["name"] for row in shown["labels"]},
        }

    def files(self, number: int) -> list[tuple[str, int]]:
        return [
            (row["filename"], row["additions"] + row["deletions"])
            for row in self.paged(f"pulls/{number}/files")
        ]

    def relabel(self, kind: str, number: int, add: list[str], drop: list[str]) -> None:
        known = self.labels()
        if add:
            self.call(
                "POST",
                f"issues/{number}/labels",
                {"labels": [known[name]["id"] for name in add]},
            )
        for name in drop:
            self.call("DELETE", f"issues/{number}/labels/{known[name]['id']}")


def forge(repo: str | None) -> Hub | Forge:
    """Whichever forge this run is actually talking to.

    Forgejo announces itself — its runner exports `FORGEJO_API_URL` and
    `FORGEJO_TOKEN` — so nothing has to be configured and a GitHub run never
    takes that path. GitHub is the fallback because it is where most of these
    repositories live and where `gh` is already installed.
    """
    api, token = os.environ.get("FORGEJO_API_URL"), os.environ.get("FORGEJO_TOKEN")
    if not (api and token):
        return Hub(repo)
    if named := repo or os.environ.get("GITHUB_REPOSITORY", ""):
        return Forge(api, token, named)
    sys.exit("FORGEJO_API_URL is set but the repository is not — pass --repo OWNER/NAME")


class Taxonomy:
    """The declared labels, and the three questions they answer."""

    def __init__(self, doc: dict) -> None:
        self.rows: list[dict] = doc["labels"]
        self.unweighted: tuple[str, ...] = tuple(doc.get("unweighted", ()))
        by_name = {row["name"] for row in self.rows}
        if len(by_name) != len(self.rows):
            sys.exit("labels.json: duplicate label name")

    @classmethod
    def load(cls, path: pathlib.Path = TAXONOMY) -> Taxonomy:
        return cls(json.loads(path.read_text()))

    def owned(self, subject: str) -> set[str]:
        """Rows this may add or remove on one kind of subject, and no others."""
        return {r["name"] for r in self.rows if REACH[subject] & r.keys()}

    @property
    def machine(self) -> set[str]:
        """Every row some rule can earn, whatever the subject."""
        return {r["name"] for r in self.rows if TRIGGERS & r.keys()}

    @property
    def marks(self) -> set[str]:
        return {r["name"] for r in self.rows if r.get("when") == "unlabeled"}

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
            lines for path, lines in changes if not any(hit(path, g) for g in self.unweighted)
        )

    def sized(self, lines: int) -> str | None:
        """The heaviest size floor this diff clears."""
        ladder = sorted((r["from"], r["name"]) for r in self.rows if "from" in r)
        return next((n for floor, n in reversed(ladder) if lines >= floor), None)

    def typed(self, title: str) -> str | None:
        found = TITLE.match(title.strip())
        return self.types.get(found["type"]) if found else None

    def sorts(self, title: str, on: set[str]) -> set[str]:
        """What an issue earns: the type its title claims, and whether it is unread.

        An issue title is prose far more often than it is a conventional commit,
        so one that does not parse earns nothing and is not a finding. The check
        that blocks on that grammar is for pull requests, whose titles become
        release history; holding a bug report to it would be hostile.
        """
        earned = {found} if (found := self.typed(title)) else set()
        # `unlabeled` asks whether a human has classified this issue, so the mark
        # this rule leaves cannot itself count as an answer — otherwise it would
        # earn its own removal on the next run and flip back and forth forever.
        return earned | self.marks if not (on - self.marks - earned) else earned


# The glob rules, stated as the cases that would break if the compiler drifted.
# Each is a claim about .gitignore's behavior, not about this implementation's.
GLOBS = (
    ("src/query.zig", "src/*", True),  # `*` covers one segment
    ("src/exec/query.zig", "src/*", False),  # and stops at the separator
    ("src/exec/query.zig", "src/**", True),  # `**` spans them
    ("src/a/b/c/query.zig", "src/**", True),
    ("src", "src/**", False),  # the slash has to be there
    ("src/exec", "src/exec/**", False),  # a subtree is not its own root
    ("src/execution/x.zig", "src/exec/**", False),  # nor is a longer sibling
    ("src/query.zig", "src/**/query.zig", True),  # `/**/` spans zero directories
    ("src/a/b/query.zig", "src/**/query.zig", True),
    ("services/vox/main.rs", "**/vox/**", True),  # a leading `**/` is optional
    ("vox/main.rs", "**/vox/**", True),
    ("Cargo.toml", "Cargo.toml", True),  # slashless: the name, any depth
    ("bindings/rust/Cargo.toml", "Cargo.toml", True),
    ("bindings/Cargo.toml.bak", "Cargo.toml", False),
    ("a/b/notes.md", "*.md", True),
    ("a+b/c.rs", "a+b/**", True),  # path metacharacters are literal
    ("axb/c.rs", "a+b/**", False),
)


# The title grammar, stated as parses rather than as labels, so a repository that
# declares a different set of commit types still holds itself to the same spec.
TITLES = (
    ("feat: add a thing", "feat"),
    ("fix(engine): stop the leak", "fix"),
    ("feat!: drop the old ABI", "feat"),  # breaking, no scope
    ("refactor(surface)!: rename the verb", "refactor"),  # breaking, with scope
    ("fix:no space", None),  # the spec wants ": "
    ("fix: ", None),  # and a real subject
    ("FIX: shouting", None),
    ("just a sentence", None),
    ("feat(: unbalanced", None),
)


def verify(tax: Taxonomy) -> int:
    """Is the config sound? Offline, tokenless, and safe to run on a fork's PR."""
    bad = [(p, g, want) for p, g, want in GLOBS if hit(p, g) is not want]
    for path, glob, want in bad:
        print(
            f"::error::glob {glob!r} should{'' if want else ' not'} match {path!r}",
            file=sys.stderr,
        )

    for title, want in TITLES:
        found = TITLE.match(title)
        got = found["type"] if found else None
        if got != want:
            bad.append((title, got, want))
            print(
                f"::error::title {title!r} parsed as {got!r}, expected {want!r}",
                file=sys.stderr,
            )

    # A mark has to survive being re-read, or it earns its own removal forever.
    for name in sorted(tax.marks):
        settled = tax.sorts("a bug report, in prose", {name, "bug"})
        if name not in tax.sorts("a bug report, in prose", set()) or name in settled:
            bad.append((name, "when", "unlabeled"))
            print(
                f"::error::{name!r} does not survive a second reading: it must be "
                f"earned on an unlabeled issue and released once one is classified",
                file=sys.stderr,
            )

    declared = {row["name"] for row in tax.rows}
    for name, where in sorted(cited(TAXONOMY.parent).items()):
        if name in declared:
            continue
        bad.append((name, where, None))
        print(
            f"::error file={where[0]}::label {name!r} is asked for by "
            f"{', '.join(sorted(set(where)))} but no row in {TAXONOMY.name} "
            f"declares it, so GitHub will drop it silently",
            file=sys.stderr,
        )

    for row in tax.rows:
        if (word := row.get("when")) and word not in WHENS:
            bad.append((row["name"], "when", word))
            print(
                f"::error::{row['name']!r} is earned `when: {word}`, which is not "
                f"a question this script knows how to ask ({', '.join(sorted(WHENS))})",
                file=sys.stderr,
            )

    dead = sorted(n for n in tax.machine if "/" not in n)
    for name in dead:
        print(
            f"::error::{name!r} is earned by a rule but sits outside every "
            f"namespace, so `sync --prune` could never clean it up",
            file=sys.stderr,
        )

    bad += wired(tax)

    if bad or dead:
        return 1
    print(
        f"ok: {len(GLOBS)} glob and {len(TITLES)} title cases, {len(declared)} "
        f"labels, {len(tax.types)} commit types, every citation resolves, "
        f"both forges wired"
    )
    return 0


def wired(tax: Taxonomy) -> list[tuple]:
    """Does the Forgejo leg still do the things only it has to?

    The GitHub leg is exercised constantly — every pull request in every one of
    these repositories runs it. The Forgejo leg runs on one repository's mirror,
    which no CI job here can reach and no fork's pull request holds a token for, so
    without this it would be the one path that ships unexecuted. Answering it from
    a table rather than a socket costs nothing and needs no credential.

    What is checked is only what differs from GitHub. There, a label is named; here
    it is a numbered object, so every write and every removal has to carry an id —
    including the id of a row this same run just created. And there, an issue and a
    pull request are separate events; here a pull request IS an issue with a diff,
    so the sort path sees every pull request opened and has to hand it back.
    """
    faults: list[tuple] = []
    seen: list[tuple[str, str, object]] = []
    already: list[dict] = []
    # `apply` narrates what it decided, which is the point when a human ran it and
    # noise when this did. Only the requests it made are being read here.
    quiet = contextlib.redirect_stdout(io.StringIO())

    def answer(method: str, path: str, body: dict | None = None) -> object:
        seen.append((method, path, body))
        if method == "GET":  # an issue, or the instance's own label set, one page
            return subject if path.startswith("issues/") else already
        if method == "POST" and path == "labels":
            return {**body, "id": 900 + len(seen)}
        return {**body, "id": 1} if method == "PATCH" else []

    def forge() -> Forge:
        made = Forge("https://forge.invalid/api/v1", "not-a-token", "owner/name")
        made.call = answer  # type: ignore[method-assign]
        return made

    # A pull request reaching the sort path — which on Forgejo is every pull
    # request — must be handed back to the label job untouched.
    subject = {"title": "feat: a diff", "labels": [], "pull_request": {"merged": False}}
    with quiet:
        apply(tax, forge(), 1, "issue", dry=False)
    if any("labels" in path for _, path, _ in seen if path.startswith("issues/1/")):
        faults.append(("forgejo", "sort", "labeled a pull request"))
        print(
            "::error::the issue path labeled a pull request; on Forgejo the "
            "`issues` event fires for both, so it has to decline one",
            file=sys.stderr,
        )

    # An issue with nothing on it earns its mark, and the mark goes out as an id.
    subject, seen[:] = {"title": "prose, not a commit message", "labels": []}, []
    marks, hub = sorted(tax.marks), forge()
    with quiet:
        apply(tax, hub, 2, "issue", dry=False)
    put = [body for method, path, body in seen if method == "POST" and path == "issues/2/labels"]
    ids = {hub.known[name]["id"] for name in marks} if hub.known else set()
    if marks and not any(isinstance(b, dict) and set(b["labels"]) == ids for b in put):
        faults.append(("forgejo", "relabel", put))
        print(
            f"::error::{', '.join(marks)} did not reach Forgejo as the numeric "
            f"id of a row it had just minted (sent {put!r})",
            file=sys.stderr,
        )

    # What `sync` does to a mirror comes down to this one write and the two cases it
    # has to tell apart. A row the instance already carries is corrected in place by
    # its id — there is no route that PATCHes a label by name, and creating it again
    # is an error rather than an update. A row it does not carry is created, and the
    # id handed back has to be kept, or writing that name again duplicates it
    # instead of editing what was just made.
    #
    # `sync` itself is deliberately not called: it opens by running this very check,
    # so reaching back into it here is a loop, and the part it would add — walking
    # the rows, diffing, reporting — is forge-agnostic and already runs on GitHub.
    stale = tax.rows[0]
    already, seen[:] = [{**stale, "id": 41, "color": "ffffff"}], []
    hub = forge()
    hub.write(stale["name"], stale["color"].lstrip("#"), stale.get("description", ""))
    hub.write("zzz/undeclared", "000000", "")
    hub.write("zzz/undeclared", "111111", "")  # the same name again: edit, not create
    calls = [(method, path) for method, path, _ in seen if method in {"POST", "PATCH"}]
    if ("PATCH", "labels/41") not in calls:
        faults.append(("forgejo", "write", stale["name"]))
        print(
            f"::error::a label the instance already carried was not corrected by "
            f"its id ({calls!r}), so a mirror's existing labels could never be "
            f"updated",
            file=sys.stderr,
        )
    if [method for method, _ in calls].count("POST") != 1:
        faults.append(("forgejo", "write", calls))
        print(
            f"::error::writing one new label twice did not create it once and then "
            f"edit it ({calls!r}); the id a create hands back is not being kept",
            file=sys.stderr,
        )
    return faults


def cited(root: pathlib.Path) -> dict[str, list[str]]:
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
                # `*` is release.yml's documented catch-all, not a label anybody
                # expects to exist, and demanding a row for it would be nonsense.
                if name and name != "*":
                    asked.setdefault(name, []).append(str(path.relative_to(root.parent)))
    return asked


# Where the sibling repositories have to agree. `area/` and `topic/` are each
# repository's own map of itself and are meant to differ; the release contract, the
# size ramp, the triage statuses, and the issue vocabulary are one palette shared
# across all of them, so a disagreement there is drift rather than intent.
SHARED = ("type/", "size/", "status/")


def kin(root: pathlib.Path) -> list[pathlib.Path]:
    """Sibling checkouts carrying this same script, found beside this one."""
    return sorted(
        peer
        for peer in root.parent.iterdir()
        if peer.is_dir() and peer != root and (peer / ".github/scripts/triage.py").is_file()
    )


def common(rows: list[dict]) -> dict[str, dict]:
    return {r["name"]: r for r in rows if r["name"].startswith(SHARED) or "/" not in r["name"]}


def peers(tax: Taxonomy) -> int:
    """Do the sibling checkouts still agree where they are supposed to?

    One script and one palette live in several repositories, and nothing inside
    any one of them can see the others — a CI run has only its own clone. Drift is
    therefore an authoring hazard rather than a merge hazard: it happens the moment
    somebody improves the engine in one repository and forgets the rest. So this
    check runs where the checkouts actually sit side by side, and with none on disk
    it has nothing to compare and says so instead of pretending to pass.

    A name one repository carries and another does not is reported but does not
    fail: a private repository has no use for `good first issue`, and that is a
    decision rather than a mistake. A name they both carry and describe
    differently is the failure, because there is only one palette.
    """
    root, mine = TAXONOMY.parent.parent, pathlib.Path(__file__).resolve()
    if not (found := kin(root)):
        print(f"no sibling checkout beside {root.name} — nothing to compare")
        return 0

    here, drift = common(tax.rows), 0
    for peer in found:
        notes: list[tuple[bool, str]] = []
        if (peer / ".github/scripts/triage.py").read_bytes() != mine.read_bytes():
            notes.append((True, "triage.py differs — the engine is meant to be one file"))
        there = common(json.loads((peer / ".github/labels.json").read_text())["labels"])
        for name in sorted(here.keys() | there.keys()):
            if here.get(name) == there.get(name):
                continue
            absent = name not in here or name not in there
            notes.append(
                (
                    not absent,
                    f"{name}: "
                    + (
                        f"only in {root.name if name in here else peer.name}"
                        if absent
                        else "declared differently in the two"
                    ),
                )
            )

        drift += sum(bad for bad, _ in notes)
        print(f"{peer.name}: {'ok' if not notes else f'{len(notes)} to look at'}")
        for bad, note in notes:
            print(f"  {'✗' if bad else '·'} {note}")

    print(f"{len(found)} siblings, {len(here)} shared rows, {drift} drifted")
    return 1 if drift else 0


def sync(tax: Taxonomy, hub: Hub | Forge, prune: bool, dry: bool) -> int:
    # Writing a label set the rest of `.github` contradicts would just make the
    # contradiction permanent, so the config has to hold before anything moves.
    if verify(tax):
        return 1

    have, declared = hub.labels(), {row["name"] for row in tax.rows}
    for row in tax.rows:
        name, color = row["name"], row["color"].lstrip("#")
        note = row.get("description", "")
        was = have.get(name)
        # Forgejo hands a color back with its `#`, GitHub without one.
        if was and was["color"].lstrip("#").lower() == color.lower() and was["description"] == note:
            continue
        verb = "update" if was else "create"
        print(f"{verb} {name} #{color} — {note}")
        if not dry:
            hub.write(name, color, note)

    # Only inside a namespace this file declares: a bare label was never ours.
    stale = sorted(
        n for n in have if "/" in n and n.split("/", 1)[0] in tax.namespaces and n not in declared
    )
    for name in stale:
        print(f"{'prune' if prune else 'stale (keep)'} {name}")
        if prune and not dry:
            hub.erase(name)

    # Everything else the repository holds. Not a finding and never deleted —
    # a bot's own label lives here, and so does a maintainer's invention — but
    # naming it is the difference between a deliberate exception and a leak,
    # and it is the one kind of drift `verify` cannot see from disk alone.
    for name in sorted(have.keys() - declared - set(stale)):
        print(f"unclaimed {name} #{have[name]['color'].lstrip('#')}")
    return 0


def apply(tax: Taxonomy, hub: Hub | Forge, number: int, kind: str, dry: bool) -> int:
    """Reconcile one pull request's or one issue's labels with what it earns."""
    shown = hub.subject(kind, number)
    on = shown["labels"]

    # Forgejo's `issues` event fires for pull requests too — there, a pull request
    # *is* an issue with a diff — so a sort job sees every pull request opened and
    # would race the label job to call one `needs-triage`. GitHub keeps the two
    # events apart and never reaches this.
    if kind == "issue" and shown["pull"]:
        print(f"#{number} is a pull request — the label job owns it, not the sort job")
        return 0

    if kind == "issue":
        want, said = tax.sorts(shown["title"], on), "issue"
    else:
        changes = hub.files(number)
        lines = tax.weighed(changes)
        want = tax.matched([path for path, _ in changes])
        want |= {e for e in (tax.sized(lines), tax.typed(shown["title"])) if e}
        said = f"{len(changes)} files, {lines} weighted lines"

    add = sorted(want - on)
    drop = sorted((on & tax.owned(kind)) - want)
    print(f"#{number} {said}")
    print(f"  keep {sorted(on & want) or '—'}\n  add  {add or '—'}\n  drop {drop or '—'}")
    if dry or not (add or drop):
        return 0

    # A label the taxonomy declares may not exist on the forge yet, and neither
    # forge will attach one it has never heard of.
    missing = set(add) - hub.labels().keys()
    for row in (r for r in tax.rows if r["name"] in missing):
        hub.write(row["name"], row["color"].lstrip("#"), row.get("description", ""))
    hub.relabel(kind, number, add, drop)
    return 0


def check(tax: Taxonomy, hub: Hub | Forge, pr: int) -> int:
    title = hub.subject("pr", pr)["title"]
    if tax.typed(title):
        print(f"ok: {title}")
        return 0
    types = ", ".join(sorted(tax.types))
    found = TITLE.match(title.strip())
    why = (
        f"unknown type {found['type']!r}"
        if found
        else "not shaped like `type: subject` or `type(scope): subject`"
    )
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
        print(
            json.dumps(
                {
                    "owned": {s: sorted(tax.owned(s)) for s in REACH},
                    "types": tax.types,
                    "namespaces": sorted(tax.namespaces),
                    "unweighted": list(tax.unweighted),
                },
                indent=2,
            )
        )
        return 0
    # GitHub's order, not the file's: the file groups by family to stay readable,
    # but what a maintainer wants to preview is the dropdown they will actually see.
    for row in sorted(tax.rows, key=lambda r: r["name"]):
        how = next(
            (f"{k}={row[k]}" for k in ("paths", "commit", "from", "when") if k in row),
            "by hand",
        )
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
    verbs.add_parser("peers", parents=[parent])
    verbs.add_parser("sync", parents=[parent]).add_argument("--prune", action="store_true")
    # `apply` reads either subject. `check` blocks on a title that is about to
    # become a commit message, which is only ever a pull request's.
    subject = verbs.add_parser("apply", parents=[parent]).add_mutually_exclusive_group(
        required=True
    )
    subject.add_argument("--pr", type=int)
    subject.add_argument("--issue", type=int)
    verbs.add_parser("check", parents=[parent]).add_argument("--pr", type=int, required=True)

    args = cli.parse_args(argv)
    tax = Taxonomy.load()
    if args.verb == "show":
        return show(tax, args.json)
    if args.verb == "verify":
        return verify(tax)
    if args.verb == "peers":
        return peers(tax)
    hub = forge(args.repo)
    if args.verb == "sync":
        return sync(tax, hub, args.prune, args.dry)
    if args.verb == "apply":
        pull = args.pr is not None
        return apply(
            tax,
            hub,
            args.pr if pull else args.issue,
            "pr" if pull else "issue",
            args.dry,
        )
    return check(tax, hub, args.pr)


if __name__ == "__main__":
    sys.exit(main())
