#!/usr/bin/env python3
"""One version, many manifests — prove they still agree.

`build.zig.zon`'s `.version` is this package's single authority. Zig reads it
directly (`build.zig` lifts it into `build_options`), Rust reads its own
`CARGO_PKG_VERSION`, and Python reads its installed distribution metadata — so
none of those restate it. What is left is the handful of packaging manifests
that cannot import anything, and the odd mirror in a language with no way to
ask: `Cargo.toml`, `pyproject.toml`, a contract TOML, a Go constant. Each
carries an `x-release-please-version` marker, and the release bot rewrites every
marked line in one commit.

This gate is what makes that trustworthy. It is a discovery, not a list: it
walks the tree for the marker, so a mirror added next year is covered the day it
is written rather than the day someone remembers this file. Two ways to fail:

  * a marked line disagrees with `build.zig.zon` (someone hand-edited one copy);
  * a marked file is missing from `release-please-config.json`'s `extra-files`,
    which would leave the bot silently skipping it at the next release.

A mirror is a line carrying the marker *and* a version, which is exactly what
release-please's generic updater rewrites. Prose that merely names the marker —
this docstring, the comment in `build.zig` — is not a mirror and is not counted.

Run it with no arguments from anywhere; `--json` for a machine.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

MARKER = "x-release-please-version"
SEMVER = re.compile(r"\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\b")
ZON_VERSION = re.compile(r"\.version\s*=\s*\"([^\"]+)\"")

# Build output, vendored third-party trees, and package caches. These hold stale
# copies of our own files (and other projects' versions), so walking them turns
# a parity gate into a scavenger hunt.
SKIP = {
    ".git",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "zig-pkg",
    ".local",
    "target",
    "vendor",
    "node_modules",
    "__pycache__",
    ".venv",
    ".pytest_cache",
    ".ruff_cache",
    "testdata",
    "changelog.d",
}
# Text files only, and only the kinds a manifest is written in.
SUFFIXES = {".zon", ".toml", ".py", ".rs", ".go", ".zig", ".h", ".json", ".md", ".yml", ".yaml"}


def repo_root(start: pathlib.Path) -> pathlib.Path:
    """The nearest ancestor holding a `build.zig.zon` — the package boundary."""
    for candidate in (start, *start.parents):
        if (candidate / "build.zig.zon").is_file():
            return candidate
    raise SystemExit("version_parity: no build.zig.zon in any parent — not a package tree")


def authority(root: pathlib.Path) -> str:
    text = (root / "build.zig.zon").read_text(encoding="utf-8")
    found = ZON_VERSION.search(text)
    if not found:
        raise SystemExit("version_parity: build.zig.zon declares no .version")
    return found.group(1)


def marked_lines(root: pathlib.Path) -> list[tuple[pathlib.Path, int, str]]:
    """Every mirror line in the tree — marker plus a version — in walk order."""
    out: list[tuple[pathlib.Path, int, str]] = []
    here = pathlib.Path(__file__).resolve()
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix not in SUFFIXES:
            continue
        if SKIP & set(path.relative_to(root).parts) or path.resolve() == here:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if MARKER not in text:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if MARKER in line and SEMVER.search(line):
                out.append((path.relative_to(root), number, line.strip()))
    return out


def declared_extra_files(root: pathlib.Path) -> set[str] | None:
    """Paths release-please was told to rewrite, or None if it isn't wired yet."""
    config = root / "release-please-config.json"
    if not config.is_file():
        return None
    packages = json.loads(config.read_text(encoding="utf-8")).get("packages", {})
    return {
        entry["path"]
        for package in packages.values()
        for entry in package.get("extra-files", [])
        if isinstance(entry, dict) and "path" in entry
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    args = parser.parse_args()

    root = repo_root(pathlib.Path.cwd().resolve())
    want = authority(root)
    lines = marked_lines(root)
    declared = declared_extra_files(root)

    faults: list[str] = []
    rows = []
    for path, number, line in lines:
        got = SEMVER.search(line).group(0)
        rows.append({"path": str(path), "line": number, "version": got})
        if got != want:
            faults.append(f"{path}:{number}: {got} != {want} (build.zig.zon) — {line}")

    # The zon itself must be marked, or the bot never moves the authority.
    if not any(row["path"] == "build.zig.zon" for row in rows):
        faults.append("build.zig.zon: .version carries no x-release-please-version marker")

    if declared is not None:
        for path in sorted({row["path"] for row in rows}):
            if path not in declared:
                faults.append(
                    f"{path}: marked, but absent from release-please-config.json extra-files — "
                    "the bot would skip it at the next release"
                )

    if args.json:
        print(json.dumps({"version": want, "mirrors": rows, "faults": faults}, indent=2))
    elif faults:
        print(
            f"version_parity: {len(faults)} fault(s) against build.zig.zon {want}\n",
            file=sys.stderr,
        )
        for fault in faults:
            print(f"  {fault}", file=sys.stderr)
        print(
            "\nEdit build.zig.zon and let the release bot move the rest, or run the "
            "same bump across every marked line.",
            file=sys.stderr,
        )
    else:
        print(f"version_parity: {len(rows)} mirrors agree at {want}")
    return 1 if faults else 0


if __name__ == "__main__":
    raise SystemExit(main())
