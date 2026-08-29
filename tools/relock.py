#!/usr/bin/env python3
"""Re-pin a Cargo.lock's own packages to the manifests beside them.

A lockfile records a version for every package in the resolved graph, and some
of those packages are ours: this crate, and the sibling engine it is built over.
Nothing rewrites those numbers. release-please moves a manifest through its
`x-release-please-version` annotation and stops there, and `irregex` versions on
a schedule of its own and moves without asking gist at all. So a committed lock
drifts from the workspace it claims to describe, from both directions, and
`cargo publish --locked` — whose whole job is to publish the graph that was
tested — refuses to reconcile the difference. gist's v1.2.0 and v1.2.2 both died
exactly there, with the wheel and the Go module already out.

The repair is a `version = "..."` rewrite and nothing else. Local packages are
discovered by walking the manifest graph from a starting directory — the root
package, then each `path` dependency, transitively — and each one's declared
version is read off disk and written into its `[[package]]` block. No registry
is contacted and nothing is re-resolved, so no third-party pin can move: what
gets published is still the graph that was tested, one version number later.

Driven from the lock rather than from the manifests, so a local package that is
outside the resolved graph (an optional path dependency, say) is reported and
skipped instead of demanded. The one hard requirement is the root package's own
block — without it this lock does not belong to this manifest, and rewriting it
would be a guess.

    python3 tools/relock.py bindings/rust           # re-pin in place
    python3 tools/relock.py bindings/rust --check   # exit 1 if a pin is behind
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import tomllib
from collections.abc import Iterator

# Every table a `path = ` dependency can be written in. Cargo also accepts them
# under `[target.<cfg>]` and `[workspace]`, and a local package reached only
# through one of those is exactly as able to stall `--locked` as a direct one.
DEP_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")


def dep_tables(manifest: dict) -> Iterator[dict]:
    scopes = [manifest, manifest.get("workspace"), *manifest.get("target", {}).values()]
    for scope in scopes:
        if not isinstance(scope, dict):
            continue
        for name in DEP_TABLES:
            table = scope.get(name)
            if isinstance(table, dict):
                yield table


def load(directory: pathlib.Path) -> dict:
    path = directory / "Cargo.toml"
    try:
        return tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise SystemExit(f"relock: cannot read {path}: {exc}") from exc


def declared_version(directory: pathlib.Path, manifest: dict) -> str:
    """This package's version, following `version.workspace = true` upward."""
    declared = manifest.get("package", {}).get("version")
    if isinstance(declared, str):
        return declared
    for candidate in (directory, *directory.parents):
        if not (candidate / "Cargo.toml").is_file():
            continue
        inherited = load(candidate).get("workspace", {}).get("package", {}).get("version")
        if isinstance(inherited, str):
            return inherited
    raise SystemExit(f"relock: {directory}/Cargo.toml declares no resolvable package version")


def local_packages(start: pathlib.Path) -> tuple[str, dict[str, str]]:
    """The root package's name, and name → declared version for every local one."""
    root = ""
    versions: dict[str, str] = {}
    seen: set[pathlib.Path] = set()
    queue = [start]
    while queue:
        directory = queue.pop(0)
        if directory in seen or not (directory / "Cargo.toml").is_file():
            continue
        seen.add(directory)
        manifest = load(directory)
        name = manifest.get("package", {}).get("name")
        if isinstance(name, str):
            versions[name] = declared_version(directory, manifest)
            root = root or name
        for table in dep_tables(manifest):
            for spec in table.values():
                if isinstance(spec, dict) and isinstance(spec.get("path"), str):
                    queue.append((directory / spec["path"]).resolve())
    if not root:
        raise SystemExit(f"relock: {start}/Cargo.toml declares no [package] to lock")
    return root, versions


def block(name: str) -> re.Pattern[str]:
    return re.compile(rf'(\[\[package\]\]\nname = "{re.escape(name)}"\nversion = ")([^"]+)(")')


def repin(text: str, versions: dict[str, str]) -> tuple[str, list[tuple[str, str, str]], list[str]]:
    """Rewrite each local pin, returning the new text, what was found, what was missing."""
    found: list[tuple[str, str, str]] = []
    absent: list[str] = []
    for name, want in sorted(versions.items()):
        pattern = block(name)
        match = pattern.search(text)
        if not match:
            absent.append(name)
            continue
        found.append((name, match.group(2), want))
        if match.group(2) != want:
            text = pattern.sub(lambda m, w=want: m.group(1) + w + m.group(3), text, count=1)
    return text, found, absent


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "directory", nargs="?", default=".", help="dir holding Cargo.toml + Cargo.lock"
    )
    parser.add_argument("--check", action="store_true", help="report staleness, write nothing")
    args = parser.parse_args()

    directory = pathlib.Path(args.directory).resolve()
    lock = directory / "Cargo.lock"
    if not lock.is_file():
        raise SystemExit(f"relock: no Cargo.lock beside {directory}/Cargo.toml")

    root, versions = local_packages(directory)
    text = lock.read_text(encoding="utf-8")
    rewritten, found, absent = repin(text, versions)

    if root in absent:
        raise SystemExit(f"relock: {lock} has no [[package]] block for {root} — not its lock")
    for name in absent:
        print(f"relock: {name} is local but outside the resolved graph — skipped")

    stale = [row for row in found if row[1] != row[2]]
    if not stale:
        print(f"relock: {len(found)} local pin(s) already agree with their manifests")
        return 0
    if args.check:
        print(f"relock: {len(stale)} local pin(s) behind the manifest beside them", file=sys.stderr)
        for name, got, want in stale:
            print(f"  {name}: locked at {got}, manifest declares {want}", file=sys.stderr)
        print(f"\nRun: python3 tools/relock.py {args.directory}", file=sys.stderr)
        return 1

    lock.write_text(rewritten, encoding="utf-8")
    for name, got, want in stale:
        print(f"relock: re-pinned {name} {got} → {want}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
