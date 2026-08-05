"""The repository README, corrected for a package index that is not GitHub.

Every index this project publishes to shows a README as the project's page, and
every one of them shows it somewhere other than the repository. A relative link
resolves against whatever page displays it, so ``src/root.zig`` - correct on
GitHub - is a 404 under ``pypi.org/project/<name>/``, and crates.io resolves it
against the crate's own subdirectory rather than the repository root, which is
worse: the URL is well-formed and points at a file that was never there.

So the copy an index gets carries absolute links, built against the
``repository`` URL the manifest already declares, in the form that serves what
the target is: ``raw`` for an image, ``tree`` or ``blob`` for everything else,
chosen by whether the path is a directory on disk. An image is the case worth
spelling out - point one at ``blob`` and it resolves, returns a web page, and
renders as a broken image with nothing having 404'd. A target that is not in the
repository at all fails here rather than becoming a dead link on a published
page.

Headings are left alone: both renderers mint their own heading ids *and* rewrite
in-document ``#anchor`` links to match, so a table of contents survives
untouched. GitHub's alert syntax does not survive - ``> [!NOTE]`` has no meaning
off GitHub and renders as literal text - so it is lowered to a bold lead line.

Two callers, one rewriter. ``bindings/python/hatch_readme.py`` calls
:func:`render` at wheel-build time, where a metadata hook can hand PyPI a
description that exists only in the artifact. Cargo has no such hook, so for
crates.io the CLI below writes the corrected copy to a gitignored file that
``readme`` points at - and since ``cargo build`` never reads it while
``cargo package`` refuses without it, forgetting to mint one is loud and
confined to the release.

pkg.go.dev is the third index and the one exception: it renders the README at
the Go module root and resolves its links against the repository, so nothing
there needs correcting. A target that has moved is still a dead link on that
page, though, and a Go module has no build step to notice - so ``--check``
covers it too.

The README itself stays written for the repository it lives in.
"""

from __future__ import annotations

import argparse
import re
import sys
import tomllib
from collections.abc import Iterator
from pathlib import Path

# The Go module root. pkg.go.dev shows the README it finds there, verbatim, and
# resolves its links against the repository - so that one is not corrected here,
# only checked.
GO_MODULE = "bindings/go"

# Where a published page points. `main` rather than the tag being built: the tag
# does not exist yet when the artifact is made, and a reader following a link out
# of the description wants the file as it stands.
BRANCH = "main"

# What the corrected copy is called when it has to exist as a file - inside an
# sdist, and beside the crate manifest. Not `README.md`: both places keep their
# own, and two files claiming that name would have to decide which one they meant.
SHIPPED = "PROJECT_README.md"

# The link forms a Markdown document can carry. Reference definitions
# (`[id]: url`) are matched too, so a switch to that style cannot quietly
# smuggle a relative target past this.
_INLINE = re.compile(r"(?P<head>!?\[[^\]]*\]\()(?P<target>[^)\s]+)(?P<tail>(?:\s+\"[^\"]*\")?\))")
_REFERENCE = re.compile(r"(?P<head>^\[[^\]]+\]:\s+)(?P<target>\S+)(?P<tail>.*)$")
_FENCE = re.compile(r"^\s*(?:```|~~~)")
_ALERT = re.compile(r"^(?P<quote>\s*>\s*)\[!(?P<kind>[A-Z]+)\]\s*$")

# A target nobody has to resolve: an anchor into this same page, or an address
# that already names its own host.
_ALREADY_ABSOLUTE = ("#", "http://", "https://", "mailto:", "//")


def absolutize(target: str, root: Path, repo: str, *, image: bool = False) -> str:
    """One link target, as an address that means the same thing from anywhere."""
    if target.startswith(_ALREADY_ABSOLUTE):
        return target
    path, _, fragment = target.partition("#")
    if not (on_disk := root / path).exists():
        message = (
            f"README.md links to {path!r}, which is not in the repository. "
            "A relative link becomes an absolute URL in a published description, "
            "so a dead one here is a 404 on the index. Fix the link or delete it."
        )
        raise ValueError(message)
    # `raw` is a redirect to the raw host, which keeps this derived from the one
    # declared URL rather than assembling a second host by hand.
    kind = "raw" if image else "tree" if on_disk.is_dir() else "blob"
    return f"{repo}/{kind}/{BRANCH}/{path.rstrip('/')}" + (f"#{fragment}" if fragment else "")


def _walk(readme: str) -> Iterator[tuple[str, bool]]:
    """Each line, and whether a renderer reads it as prose. Inside a fence,
    ``[a](b)`` is a sample somebody is meant to copy, not a link."""
    fenced = False
    for line in readme.splitlines():
        if _FENCE.match(line):
            fenced = not fenced
            yield line, False
        else:
            yield line, not fenced


def rewrite(readme: str, root: Path, repo: str) -> str:
    """The document with every relative target absolutized and alerts lowered."""

    def one(match: re.Match[str]) -> str:
        target = absolutize(match["target"], root, repo, image=match["head"].startswith("!"))
        return f"{match['head']}{target}{match['tail']}"

    out = []
    for line, prose in _walk(readme):
        if prose and (alert := _ALERT.match(line)):
            # The blank quote line keeps the label its own paragraph rather than
            # letting it run into the sentence below it.
            quote = alert["quote"].rstrip()
            out += [f"{quote} **{alert['kind'].capitalize()}**", quote]
            continue
        out.append(_REFERENCE.sub(one, _INLINE.sub(one, line)) if prose else line)
    return "\n".join(out) + "\n"


def dead_targets(readme: str, base: Path) -> list[str]:
    """The relative targets that resolve to nothing, for a document published as
    written rather than corrected - pkg.go.dev renders the Go module's README
    verbatim and resolves its links against the repository itself, so a target
    that is not there is a dead link on the module's landing page."""
    return [
        target
        for line, prose in _walk(readme)
        if prose
        for match in (*_INLINE.finditer(line), *_REFERENCE.finditer(line))
        if not (target := match["target"]).startswith(_ALREADY_ABSOLUTE)
        and not (base / target.partition("#")[0]).exists()
    ]


def render(root: Path, repo: str) -> str:
    """The repository's README, ready for an index that is not the repository."""
    return rewrite((root / "README.md").read_text(encoding="utf-8"), root, repo)


def declared_repository(manifest: Path) -> str:
    """The `repository` URL a manifest states, which is the base every rewritten
    link is built against. Read rather than passed, so the address on the page
    cannot drift from the address the package claims."""
    table = tomllib.loads(manifest.read_text(encoding="utf-8"))
    url = table.get("package", {}).get("repository") or table["project"]["urls"]["Repository"]
    return url.rstrip("/")


def main(argv: list[str] | None = None) -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "bindings/rust/Cargo.toml",
        help="manifest whose `repository` URL the links are built against",
    )
    parser.add_argument(
        "--out",
        type=Path,
        help=f"where to write it (default: {SHIPPED} beside the manifest)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="render and discard - proves every link resolves, writes nothing",
    )
    args = parser.parse_args(argv)

    try:
        page = render(root, declared_repository(args.manifest))
    except ValueError as dead:
        print(f"registry_readme: {dead}", file=sys.stderr)
        return 1

    if args.check:
        module = root / GO_MODULE / "README.md"
        if module.is_file() and (dead := dead_targets(module.read_text("utf-8"), module.parent)):
            print(
                f"registry_readme: {GO_MODULE}/README.md links to {dead}, which pkg.go.dev "
                "publishes as written - a target that is not there is a dead link on the "
                "module's landing page.",
                file=sys.stderr,
            )
            return 1
        print(f"registry_readme: {len(page)} bytes, every link resolves")
        return 0
    out = args.out or args.manifest.parent / SHIPPED
    out.write_text(page, encoding="utf-8")
    print(f"registry_readme: wrote {out.relative_to(root)} ({len(page)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
