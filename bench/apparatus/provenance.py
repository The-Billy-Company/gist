#!/usr/bin/env python3
"""The provenance a certificate needs to be reproducible, minted the same way everywhere.

VENDORED, BYTE-IDENTICAL across irregex/gist/relate/blast
(`bench/apparatus/SHARED.sha256`, checked by `shared_drift.py`).

Three files decide whether a published number can be re-derived by a stranger:
**which machine** ran it, **which exact binaries** ran, and **which exact bytes**
they ran over. `guard/artifacts.py` refuses a bundle that lacks any of them —
and since that gate is vendored, four packages must agree on their shape down to
the field order, or a bundle blessed in one repo would be rejected in the next.

So this emitter is vendored too. It knows nothing about what any package
certifies: it is handed a corpus, a tool list, and the run parameters, and it
writes the same three artifacts every time.

    machine.json         cpu / ram / os / filesystem / corpus identity / run knobs
    tool-versions.txt    one `<id> [version] sha256:<hex>` line per tool
    corpus-manifest.tsv  path · size · sha256, one row per corpus file

Two hazards it exists to close, both of which look like success:

  * **A shim is not a pin.** `command -v csearch` can resolve to a version
    manager's multiplexer, so every shimmed tool hashes to the *same* launcher —
    a record that pins nothing while reading exactly like a pin. Defended twice:
    the real binary is found by name through the exec path, and the version is
    asked OF the tool so it travels correctly even through a shim. (The gate
    fail-closes separately when two ids share one digest.)
  * **A moving corpus is not a corpus.** A manifest row promises that these
    exact bytes produced the timings beside them. A file that changes under the
    hash breaks that promise, and hashing it loosely would hide the break.

Usage:
    provenance.py --out DIR --root CORPUS --corpus-id ID [--source-root PKG]
                  [--roots "a b"] [--runs N] [--warmup N] [--paths-list FILE]
                  [--tool id=/abs/path]... [--allow-dirty]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
from pathlib import Path

#: Two components is a real release shape, not a truncation — GNU grep is `3.12`.
SEMVER = re.compile(r"v?\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?")

#: Past this fraction of the corpus moving mid-hash, the tree is too busy to
#: certify at all. Below it, a churned file is dropped and *counted*, so the
#: certificate states exactly which bytes it can and cannot vouch for.
CHURN_CEILING = 0.01


def _run(argv: list[str], limit: int) -> str:
    try:
        done = subprocess.run(
            argv, capture_output=True, text=True, timeout=limit, stdin=subprocess.DEVNULL
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return done.stdout or done.stderr


def real_binary(first: str) -> str:
    """The tool itself rather than a version-manager multiplexer.

    A shim resolves to the manager (`mise`, `asdf`); a real install still carries
    the tool's own name after symlinks. That name is the whole signal needed to
    tell them apart, so no manager is special-cased here.

    """
    tool = os.path.basename(first)
    for directory in os.get_exec_path():
        real = os.path.realpath(os.path.join(directory, tool))
        if os.access(real, os.X_OK) and os.path.basename(real) == tool:
            return real
    return os.path.realpath(first)


def version(path: str) -> str:
    """The tool's own name for itself, asked in the order that is safe to ask.

    Embedded Go module metadata comes first because it is authoritative and
    cannot have side effects. Neither csearch nor zoekt carries a version flag,
    and asking a SEARCH tool for one is actively unsafe: `csearch version` treats
    `version` as the regexp and prints a matching corpus line, which scraped a
    bogus release number out of a package's own source before this order existed.
    The bare `version` form stays reachable for `zig`, but only when the whole
    reply IS a version — content can never fullmatch.

    """
    if go := shutil.which("go"):
        for line in _run([go, "version", "-m", path], 20).splitlines():
            field = line.split()
            if len(field) >= 3 and field[0] == "mod":
                return field[2]
    if (head := _run([path, "--version"], 10).strip().splitlines()) and (
        found := SEMVER.search(head[0])
    ):
        return found.group(0)
    lone = _run([path, "version"], 10).strip().splitlines()
    return lone[0] if len(lone) == 1 and SEMVER.fullmatch(lone[0]) else ""


def sha256(path: str | os.PathLike[str] | bytes) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tool_identity(name: str, executable: str) -> str:
    """One `tool-versions.txt` line, or raise when the tool cannot be pinned."""
    if not os.access(executable, os.X_OK):
        raise SystemExit(f"provenance: no executable identity for {name} ({executable})")
    real = real_binary(executable)
    found = version(real)
    return " ".join([name, *([found] if found else []), f"sha256:{sha256(real)}"])


def write_tools(out: Path, tools: list[tuple[str, str]]) -> None:
    """Pin every tool to an exact identity, atomically."""
    body = "".join(tool_identity(name, path) + "\n" for name, path in tools)
    tmp = out / "tool-versions.txt.tmp"
    tmp.write_text(body)
    tmp.replace(out / "tool-versions.txt")


class Corpus:
    """What a mint vouches for: how much it hashed, and the one digest naming it."""

    def __init__(self, files: int, total: int, sha256: str, unstable: list[str]) -> None:
        self.files, self.total, self.sha256, self.unstable = files, total, sha256, unstable


def write_manifest(manifest: Path, root: Path, paths_list: Path, *, allow_dirty: bool) -> Corpus:
    """Hash the corpus into `corpus-manifest.tsv`; return what was vouched for.

    On a clean tree a file that vanishes or moves under us is fatal — the row it
    would have written is a promise nobody can keep. On a coworking tree
    (`--allow-dirty`) ~10 agents edit continuously, so a churned file is expected
    and losing a half-hour of valid measurement to someone else's `rm` is not
    integrity, it is brittleness. Such a file is DROPPED rather than hashed
    loosely, and reported, so the bundle says which bytes it vouches for.

    Rows are emitted in sorted path order, not walk order, for two reasons: the
    manifest becomes byte-identical across runs over an unchanged tree, and the
    whole-corpus digest below needs a canonical order to be a *value* rather than
    an artifact of how the walker happened to enumerate.

    The digest is `sha256(path‖bytes …)` over that order — deliberately the same
    definition the corpus recipes emit (`corpus.py`'s `digest_of`,
    `corpora/ecosystem.sh`), because `publish.py` compares this number against
    the one `corpus.toml` pins. It reads `machine.json`'s `corpus_sha256`, and
    until this function produced one, any charter that pinned a digest failed its
    own mint with `(absent)` — a fail-closed gate reading a key nobody wrote.
    A churned file is excluded here exactly as it is from the manifest, so a
    dirty-tree mint cannot match a pinned digest. That is the intended verdict,
    not a false alarm: it did not measure the declared corpus.
    """
    unstable: list[str] = []
    files = total = 0
    corpus = hashlib.sha256()
    tmp = manifest.with_suffix(manifest.suffix + ".tmp")
    with tmp.open("wb") as sink:
        sink.write(b"path\tsize_bytes\tsha256\n")
        for rel in sorted(r for r in paths_list.read_bytes().split(b"\0") if r):
            if any(c in rel for c in (b"\t", b"\n", b"\r")):
                raise SystemExit(f"provenance: path holds a control character: {rel!r}")
            path = os.path.join(os.fsencode(root), rel)
            try:
                with open(path, "rb") as source:
                    before = os.fstat(source.fileno())
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: source.read(1 << 20), b""):
                        digest.update(chunk)
                    after = os.fstat(source.fileno())
            except (FileNotFoundError, NotADirectoryError):
                before = after = None
            if before is None or (before.st_size, before.st_mtime_ns) != (
                after.st_size,
                after.st_mtime_ns,
            ):
                why = "vanished" if before is None else "changed"
                if not allow_dirty:
                    raise SystemExit(f"provenance: corpus file {why} while hashing: {rel!r}")
                unstable.append(os.fsdecode(rel))
                continue
            # A second read rather than buffering the first: the file just proved
            # stable, and holding an arbitrarily large corpus file in memory to
            # save a warm-cache pass is the wrong trade.
            corpus.update(rel)
            with open(path, "rb") as source:
                for chunk in iter(lambda: source.read(1 << 20), b""):
                    corpus.update(chunk)
            sink.write(rel + f"\t{before.st_size}\t{digest.hexdigest()}\n".encode())
            files += 1
            total += before.st_size
    seen = files + len(unstable)
    if unstable and len(unstable) > CHURN_CEILING * seen:
        tmp.unlink(missing_ok=True)
        raise SystemExit(
            f"provenance: corpus churned past the ceiling while hashing: {len(unstable)} of "
            f"{seen} files (> {CHURN_CEILING:.0%}) — re-mint on a quieter tree"
        )
    tmp.replace(manifest)
    return Corpus(files, total, corpus.hexdigest(), unstable)


def _ask(argv: list[str]) -> str:
    """A probe whose failure is an answer, not an incident.

    Every caller here is asking a question the platform may simply not have —
    `sysctl hw.memsize` on Linux, `git rev-parse` in an exported tarball. Their
    stderr is discarded because a mint printing `fatal: not a git repository`
    reads as a broken certificate rather than a machine without that fact.
    """
    try:
        return subprocess.check_output(argv, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def _sysctl(key: str) -> str:
    return _ask(["sysctl", "-n", key])


def _filesystem() -> str:
    if platform.system() != "Darwin":
        return _ask(["stat", "-f", "-c", "%T", "/"]) or "unknown"
    for line in _ask(["diskutil", "info", "/"]).splitlines():
        if "File System Personality" in line:
            return line.split(":", 1)[1].strip()
    return "unknown"


def _ram_bytes() -> int:
    if by_sysctl := _sysctl("hw.memsize"):
        return int(by_sysctl)
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (OSError, ValueError):
        return 0


def _head(root: Path) -> str:
    return _ask(["git", "-C", str(root), "rev-parse", "HEAD"]) or "unknown"


def machine(
    source_root: Path,
    *,
    corpus_id: str,
    roots: str,
    corpus: Corpus,
    runs: int,
    warmup: int,
) -> dict[str, object]:
    """The machine and corpus identity a re-run has to match to be comparable."""
    record: dict[str, object] = {
        "cpu_model": _sysctl("machdep.cpu.brand_string") or platform.processor() or "unknown",
        "cpu_count": int(_sysctl("hw.ncpu") or os.cpu_count() or 0),
        "ram_bytes": _ram_bytes(),
        "os": f"{platform.system()} {platform.release()}",
        "kernel": platform.release(),
        "filesystem": _filesystem(),
        # Provenance only — never gated on. It helps a human trace a number back
        # to a tree and says nothing about whether the bundle reproduces.
        "git_commit": _head(source_root),
        # The corpus this bundle may be published over, named in the package's
        # `bench/certificate/corpus.toml`. The publish gate refuses an id it
        # does not know, which is what keeps a private tree out of a release.
        "corpus_id": corpus_id,
        "corpus_file_count": corpus.files,
        "corpus_total_bytes": corpus.total,
        # The value `publish.py` compares against the digest `corpus.toml` pins.
        "corpus_sha256": corpus.sha256,
        # Count is exact; the path list is capped so one pathological run cannot
        # bloat the artifact. Both are absent on a clean-tree mint.
        "corpus_unstable_files": len(corpus.unstable),
        "corpus_unstable": sorted(corpus.unstable)[:64],
        "runs": runs,
        "warmup": warmup,
        "roots": roots,
    }
    if not corpus.unstable:
        del record["corpus_unstable_files"], record["corpus_unstable"]
    return record


def main(argv: list[str] | None = None) -> int:
    """Emit the three reproducibility artifacts into a mint's output directory."""
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", type=Path, required=True, help="the mint's output bundle dir")
    ap.add_argument("--root", type=Path, required=True, help="corpus root the paths are under")
    ap.add_argument(
        "--source-root",
        type=Path,
        help="checkout whose HEAD built the tools (default: --root). Distinct because a "
        "mint may measure a corpus that is not the package, and the commit worth "
        "recording is the one that produced the binaries",
    )
    ap.add_argument("--corpus-id", required=True, help="an id declared in corpus.toml")
    ap.add_argument("--roots", default="", help="corpus roots as searched, space-separated")
    ap.add_argument("--paths-list", type=Path, help="NUL-separated corpus paths, relative to root")
    ap.add_argument("--tool", action="append", default=[], metavar="ID=PATH")
    ap.add_argument("--runs", type=int, default=0)
    ap.add_argument("--warmup", type=int, default=0)
    ap.add_argument("--allow-dirty", action="store_true", help="tolerate a coworked tree")
    args = ap.parse_args(argv)

    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    tools = []
    for spec in args.tool:
        name, sep, path = spec.partition("=")
        if not sep or not name or not path:
            raise SystemExit(f"provenance: --tool wants ID=PATH, got {spec!r}")
        tools.append((name, path))
    if tools:
        write_tools(out, tools)

    corpus = Corpus(0, 0, "", [])
    if args.paths_list:
        corpus = write_manifest(
            out / "corpus-manifest.tsv",
            args.root,
            args.paths_list,
            allow_dirty=args.allow_dirty,
        )

    record = machine(
        args.source_root or args.root,
        corpus_id=args.corpus_id,
        roots=args.roots,
        corpus=corpus,
        runs=args.runs,
        warmup=args.warmup,
    )
    (out / "machine.json").write_text(json.dumps(record, indent=2) + "\n")
    print(
        f"  machine.json: {record['cpu_model']} · {record['cpu_count']} cores · "
        f"corpus {corpus.files} files / {corpus.total} B · sha256:{corpus.sha256[:12]}"
    )
    if corpus.unstable:
        print(f"  corpus churn: {len(corpus.unstable)} file(s) changed under the mint, excluded")
        for path in sorted(corpus.unstable)[:5]:
            print(f"    - {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
