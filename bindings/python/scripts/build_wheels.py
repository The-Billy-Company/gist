#!/usr/bin/env python3
"""Build the platform wheel matrix from one machine.

Zig cross-compiles, which is the whole reason this is cheap: every target below
is produced by the same host, from the same sources, with no CI fan-out and no
emulation. Each wheel differs only in the `gist` executable inside it and the
platform tag on the outside — see `irregex/bindings/python/scripts/build_wheels.py`,
whose matrix this mirrors (same six targets, same floors), adapted for a single
CLI binary instead of a shared library.

    python3 scripts/build_wheels.py                 # every target
    python3 scripts/build_wheels.py --only native   # the one matching this host
    python3 scripts/build_wheels.py --list          # what the matrix covers
    python3 scripts/build_wheels.py --archives OUT  # …and the release archives

Wheels land in ``dist/``. A target that fails is reported and does not stop the
others, so one broken toolchain does not cost you the rest of the matrix.

``--archives`` additionally writes one downloadable archive per target, plus a
``SHA256SUMS`` over them. These are the GitHub Release assets, and they exist
because a wheel is only reachable by someone who has Python: a Homebrew formula,
a ``curl | sh`` installer, and ``cargo binstall`` all want a plain archive at a
URL. They are cut from the very binary each wheel was built from, in the same
pass — not a second build — so an asset and its wheel cannot disagree about what
this release's CLI is.

Every target names an explicit minimum platform version in its Zig triple, and
its wheel tag says the same number. Letting Zig inherit the host's macOS SDK
would produce a binary that refuses to load on an older machine than the one
that built it, under a tag promising it would.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import zipfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parent
ENGINE = PROJECT.parent.parent


@dataclass(frozen=True)
class Target:
    name: str
    #: The Zig triple, with an explicit minimum OS version.
    zig: str
    #: The wheel platform tag, which must agree with that minimum.
    tag: str
    #: Where Zig installs the CLI under --prefix.
    artifact: str
    #: The ``-Dcpu`` subtarget: the instruction floor this wheel may use, and
    #: therefore the oldest CPU it runs on. Named per target rather than left to
    #: Zig's default, because the default is a decision either way and an
    #: unwritten one cannot be reviewed.
    cpu: str
    #: ``(sys.platform, machine)`` this target is the native one for.
    host: tuple[str, str] | None = None


_BIN = "bin/gist"
_EXE = "bin/gist.exe"

# See `irregex/bindings/python/scripts/build_wheels.py` for the reasoning
# behind every floor named here — glibc 2.17, macOS 11, Windows 10 RS4, and the
# x86_64-v2 / aarch64-baseline CPU split. This table is deliberately identical
# to that one so the two packages' wheels describe one platform per name.
MATRIX = (
    Target(
        "macos-arm64",
        "aarch64-macos.11.0",
        "macosx_11_0_arm64",
        _BIN,
        "baseline",
        ("darwin", "arm64"),
    ),
    Target(
        "macos-x86_64",
        "x86_64-macos.11.0",
        "macosx_11_0_x86_64",
        _BIN,
        "x86_64_v2",
        ("darwin", "x86_64"),
    ),
    Target(
        "linux-x86_64",
        "x86_64-linux-gnu.2.17",
        "manylinux_2_17_x86_64",
        _BIN,
        "x86_64_v2",
        ("linux", "x86_64"),
    ),
    Target(
        "linux-aarch64",
        "aarch64-linux-gnu.2.17",
        "manylinux_2_17_aarch64",
        _BIN,
        "baseline",
        ("linux", "aarch64"),
    ),
    Target(
        "windows-x86_64",
        "x86_64-windows.win10_rs4-gnu",
        "win_amd64",
        _EXE,
        "x86_64_v2",
        ("win32", "AMD64"),
    ),
    Target(
        "windows-arm64",
        "aarch64-windows.win10_rs4-gnu",
        "win_arm64",
        _EXE,
        "baseline",
        ("win32", "ARM64"),
    ),
)


def native_target() -> Target | None:
    """The matrix entry this machine is the native host for, if any.

    Resolved by name rather than by building without ``-Dtarget``: a host build
    inherits the machine's SDK, and then the wheel's tag and the binary's real
    minimum version are two independent guesses at the same number.
    """
    here = (sys.platform, platform.machine())
    return next((t for t in MATRIX if t.host == here), None)


def build_binary(target: Target, prefix: Path) -> Path:
    # Stripped, because nobody `pip install`s a CLI to debug its internals. On
    # ELF the DWARF outweighs the code about four to one, so this is the
    # difference between a 22 MB wheel and a 4 MB one; Mach-O is already small
    # because its debug info lives in a separate `.dSYM` that never ships here.
    command = [
        "zig",
        "build",
        "-Doptimize=ReleaseFast",
        "-Dstrip=true",
        f"-Dtarget={target.zig}",
        f"-Dcpu={target.cpu}",
        "--prefix",
        str(prefix),
    ]
    subprocess.run(command, cwd=ENGINE, check=True)
    built = prefix / target.artifact
    if not built.is_file():
        raise RuntimeError(f"zig build produced no {target.artifact}")
    return built


def build_wheel(target: Target, binary: Path, outdir: Path) -> None:
    env = os.environ | {
        "GIST_PREBUILT_BIN": str(binary),
        "GIST_WHEEL_PLATFORM": target.tag,
        "GIST_ZIG_TARGET": target.zig,
        # Unused on this path, which hands over a binary already built above,
        # but it keeps this matrix the single table: a source build triggered
        # with the same environment resolves the same floor.
        "GIST_ZIG_CPU": target.cpu,
    }
    if shutil.which("uv"):
        command = ["uv", "build", "--wheel", "--out-dir", str(outdir)]
    else:
        command = [sys.executable, "-m", "build", "--wheel", "--outdir", str(outdir)]
    subprocess.run(command, cwd=PROJECT, check=True, env=env)


def version() -> str:
    """The release being cut, from the manifest release-please already bumps."""
    manifest = tomllib.loads((PROJECT / "pyproject.toml").read_text())
    return str(manifest["project"]["version"])


def build_archive(target: Target, binary: Path, release: str, outdir: Path) -> Path:
    """One downloadable archive holding just the CLI, named for its platform.

    Archived rather than published as a bare file for one reason that matters
    and one that follows from it: a raw binary downloaded over HTTP arrives
    without its executable bit, and every installer that would consume this
    (Homebrew, ``cargo binstall``, a shell one-liner) already knows how to
    unpack. ``.zip`` on Windows and ``.tar.gz`` elsewhere is what each platform's
    tooling opens with no extra dependency.

    The mode is set explicitly on both paths. `tarfile` copies it from the file
    on disk, which is correct here but only by inheritance from Zig; `zipfile`
    stores nothing of the sort unless told, and a `gist.exe` does not need the
    bit anyway — stating it in both keeps the two branches saying the same thing.
    """
    inner = Path(target.artifact).name
    stem = f"gist-{release}-{target.name}"
    if target.artifact == _EXE:
        path = outdir / f"{stem}.zip"
        with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
            entry = zipfile.ZipInfo(inner)
            entry.external_attr = 0o755 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, binary.read_bytes())
        return path
    path = outdir / f"{stem}.tar.gz"
    with tarfile.open(path, "w:gz") as archive:
        info = archive.gettarinfo(str(binary), arcname=inner)
        info.mode = 0o755
        # Zeroed so the same sources produce the same bytes: an archive whose
        # checksum moves because it was built on a different afternoon cannot be
        # used to prove two releases shipped the same CLI.
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        with binary.open("rb") as handle:
            archive.addfile(info, handle)
    return path


def write_checksums(archives: list[Path], outdir: Path) -> Path:
    """A `SHA256SUMS` in the format `shasum -c` reads, over every asset.

    Not decoration: this is the only thing a Homebrew formula or an installer
    script can check a download against, and it has to be produced here, beside
    the archives, rather than by whoever uploads them.
    """
    path = outdir / "SHA256SUMS"
    lines = [f"{hashlib.sha256(a.read_bytes()).hexdigest()}  {a.name}\n" for a in sorted(archives)]
    path.write_text("".join(lines))
    return path


def chosen_targets(only: list[str] | None) -> list[Target]:
    if not only:
        return list(MATRIX)
    picked: list[Target] = []
    for name in only:
        if name == "native":
            here = native_target()
            if here is None:
                raise SystemExit(
                    f"no matrix target for {sys.platform}/{platform.machine()}; "
                    f"name one of {', '.join(t.name for t in MATRIX)}"
                )
            picked.append(here)
            continue
        found = next((t for t in MATRIX if t.name == name), None)
        if found is None:
            raise SystemExit(f"no target named {name!r}")
        picked.append(found)
    return picked


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only", action="append", metavar="NAME", help="build just these targets, or 'native'"
    )
    parser.add_argument("--list", action="store_true", help="print the matrix and exit")
    parser.add_argument("--outdir", default=str(PROJECT / "dist"), help="where wheels land")
    parser.add_argument(
        "--archives",
        metavar="DIR",
        help="also write one release archive per target there, plus SHA256SUMS",
    )
    args = parser.parse_args()

    here = native_target()
    if args.list:
        for target in MATRIX:
            mark = " (native)" if target is here else ""
            print(
                f"{target.name:16} zig={target.zig:24} cpu={target.cpu:10} tag={target.tag}{mark}"
            )
        return 0

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    assets = Path(args.archives) if args.archives else None
    if assets is not None:
        assets.mkdir(parents=True, exist_ok=True)
    release = version()
    failures: list[tuple[str, str]] = []
    archived: list[Path] = []

    for target in chosen_targets(args.only):
        print(f"\n=== {target.name} ({target.zig}) -> {target.tag} ===", flush=True)
        try:
            with tempfile.TemporaryDirectory(prefix=f"gist-{target.name}-") as staging:
                binary = build_binary(target, Path(staging))
                build_wheel(target, binary, outdir)
                if assets is not None:
                    archived.append(build_archive(target, binary, release, assets))
        except (subprocess.CalledProcessError, RuntimeError, OSError) as exc:
            print(f"FAILED {target.name}: {exc}", file=sys.stderr)
            failures.append((target.name, str(exc)))

    print("\n=== wheels ===")
    for wheel in sorted(outdir.glob("*.whl")):
        print(f"  {wheel.name}")
    # Only over what this run actually produced: a stale archive left in the
    # directory from an earlier version must not be vouched for by this
    # release's checksums.
    if archived:
        print("\n=== archives ===")
        for asset in sorted(archived):
            print(f"  {asset.name}")
        print(f"  {write_checksums(archived, assets).name}")
    if failures:
        print("\n=== failed targets ===")
        for name, why in failures:
            print(f"  {name}: {why}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
