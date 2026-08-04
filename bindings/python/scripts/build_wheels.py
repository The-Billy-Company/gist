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

Wheels land in ``dist/``. A target that fails is reported and does not stop the
others, so one broken toolchain does not cost you the rest of the matrix.

Every target names an explicit minimum platform version in its Zig triple, and
its wheel tag says the same number. Letting Zig inherit the host's macOS SDK
would produce a binary that refuses to load on an older machine than the one
that built it, under a tag promising it would.
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
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
    Target("macos-arm64", "aarch64-macos.11.0", "macosx_11_0_arm64", _BIN, "baseline", ("darwin", "arm64")),
    Target("macos-x86_64", "x86_64-macos.11.0", "macosx_11_0_x86_64", _BIN, "x86_64_v2", ("darwin", "x86_64")),
    Target("linux-x86_64", "x86_64-linux-gnu.2.17", "manylinux_2_17_x86_64", _BIN, "x86_64_v2", ("linux", "x86_64")),
    Target("linux-aarch64", "aarch64-linux-gnu.2.17", "manylinux_2_17_aarch64", _BIN, "baseline", ("linux", "aarch64")),
    Target("windows-x86_64", "x86_64-windows.win10_rs4-gnu", "win_amd64", _EXE, "x86_64_v2", ("win32", "AMD64")),
    Target("windows-arm64", "aarch64-windows.win10_rs4-gnu", "win_arm64", _EXE, "baseline", ("win32", "ARM64")),
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
    failures: list[tuple[str, str]] = []

    for target in chosen_targets(args.only):
        print(f"\n=== {target.name} ({target.zig}) -> {target.tag} ===", flush=True)
        try:
            with tempfile.TemporaryDirectory(prefix=f"gist-{target.name}-") as staging:
                binary = build_binary(target, Path(staging))
                build_wheel(target, binary, outdir)
        except (subprocess.CalledProcessError, RuntimeError, OSError) as exc:
            print(f"FAILED {target.name}: {exc}", file=sys.stderr)
            failures.append((target.name, str(exc)))

    print("\n=== wheels ===")
    for wheel in sorted(outdir.glob("*.whl")):
        print(f"  {wheel.name}")
    if failures:
        print("\n=== failed targets ===")
        for name, why in failures:
            print(f"  {name}: {why}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
