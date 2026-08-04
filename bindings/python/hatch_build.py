"""Hatchling build hook: put the `gist` CLI in the wheel, and tag it honestly.

A wheel that contains a native executable is not `py3-none-any`. Claiming
otherwise produces a file pip will happily install on any platform and that
will fail the moment a verb shells out, which is the worst possible place to
discover the mistake — so this hook does three things: build (or accept) the
CLI, force it into the wheel under ``gist/bin/``, and set the platform tag to
match.

Unlike `irregex`'s C-ABI library, the CLI links nothing external at runtime —
`otool -L`/`ldd` on the product binary show only the platform's own libc, since
`irregex` is a Zig module import (statically compiled in), not a dynamic
link. One file per platform is the whole artifact.

The Python side is pure - it is a subprocess client, not a C extension - so the
tag is ``py3-none-<platform>``: any Python 3, no CPython ABI, this platform
only.

Two environment variables drive a cross-build, mirroring `irregex`'s hook:

``GIST_PREBUILT_BIN``
    A binary that is already built. The hook copies it instead of invoking
    Zig. This is what ``scripts/build_wheels.py`` uses, so the matrix script
    owns the Zig invocation and this hook stays a packaging step.

``GIST_WHEEL_PLATFORM``
    The platform tag to stamp, e.g. ``manylinux_2_17_x86_64``. Required when
    cross-building, since the host's own tag would be a lie.
"""

from __future__ import annotations

import os
import platform
import shutil
import subprocess
import sys
import sysconfig
import tempfile
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

# Zig's install layout per OS: where the CLI lands under --prefix, and what it
# must be called inside the package for a subprocess spawn to find it.
_LAYOUT = {
    "windows": ("bin/gist.exe", "gist.exe"),
    "macos": ("bin/gist", "gist"),
    "linux": ("bin/gist", "gist"),
}


def _os_of(zig_target: str | None) -> str:
    if zig_target:
        for name in _LAYOUT:
            if name in zig_target:
                return name
        raise RuntimeError(f"cannot tell which OS {zig_target!r} is; expected macos/linux/windows")
    return {"darwin": "macos", "win32": "windows"}.get(sys.platform, "linux")


def _zig_cpu(zig_target: str) -> str:
    """The instruction floor to build `zig_target` at.

    ``GIST_ZIG_CPU`` overrides, which is how ``scripts/build_wheels.py`` keeps
    one table for the whole matrix. The fallback is the same rule that table
    encodes: aarch64's baseline already carries NEON and needs no raising,
    while x86_64's baseline is SSE2 and the scan kernels want SSSE3.
    """
    override = os.environ.get("GIST_ZIG_CPU")
    if override:
        return override
    return "baseline" if zig_target.startswith("aarch64") else "x86_64_v2"


def _engine_root(start: Path) -> Path:
    """The Zig package root, found by walking up for ``build.zig``."""
    for parent in (start, *start.parents):
        if (parent / "build.zig").is_file():
            return parent
    raise RuntimeError(
        "cannot find the gist Zig sources (no build.zig above "
        f"{start}). Building this wheel from an sdist needs either the product "
        "sources or GIST_PREBUILT_BIN pointing at a built binary."
    )


class GistBuildHook(BuildHookInterface):
    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "wheel":
            return

        zig_target = os.environ.get("GIST_ZIG_TARGET")
        which_os = _os_of(zig_target)
        _, installed_name = _LAYOUT[which_os]

        prebuilt = os.environ.get("GIST_PREBUILT_BIN")
        if prebuilt:
            source = Path(prebuilt).resolve()
            if not source.is_file():
                raise RuntimeError(f"GIST_PREBUILT_BIN={prebuilt!r} is not a file")
        else:
            source = self._build_with_zig(zig_target, which_os)

        build_data["pure_python"] = False
        build_data["infer_tag"] = False
        build_data["tag"] = f"py3-none-{self._platform_tag()}"
        # Hatchling derives the archived permission bits from THIS source
        # file's own mode (644/755, never copied verbatim — see
        # `normalize_file_permissions`), so the wheel's `gist` inherits the
        # executable bit `zig build` already set without this hook asking for
        # it a second time. A `GIST_PREBUILT_BIN` that lost `+x` in transit
        # (e.g. re-uploaded through a step that resets perms) fails the same
        # way any non-executable `gist` would: loudly, at the caller's first
        # search, never silently.
        build_data.setdefault("force_include", {})[str(source)] = f"gist/bin/{installed_name}"

    def _build_with_zig(self, zig_target: str | None, which_os: str) -> Path:
        if shutil.which("zig") is None:
            raise RuntimeError(
                "zig is not on PATH. Install Zig to build this wheel from source, "
                "or set GIST_PREBUILT_BIN to a binary you already have."
            )
        root = _engine_root(Path(self.root).resolve())
        # Held on the instance so the directory outlives `initialize` and is
        # still there when hatchling reads the file it force-included.
        self._staging = tempfile.TemporaryDirectory(prefix="gist-wheel-")
        prefix = Path(self._staging.name)
        command = [
            "zig",
            "build",
            "-Doptimize=ReleaseFast",
            "-Dstrip=true",
            "--prefix",
            str(prefix),
        ]
        if zig_target:
            # Naming a target also opts out of native CPU detection — Zig falls
            # back to that target's baseline, and x86_64's baseline is SSE2,
            # below the SSSE3 the scan kernels want. So a target implies a
            # floor. `scripts/build_wheels.py` sets both; a bare source build
            # names neither and keeps Zig's native detection, which is right.
            command += [f"-Dtarget={zig_target}", f"-Dcpu={_zig_cpu(zig_target)}"]
        subprocess.run(command, cwd=root, check=True)

        relative, _ = _LAYOUT[which_os]
        built = prefix / relative
        if not built.is_file():
            raise RuntimeError(f"zig build finished but produced no {relative} under {prefix}")
        return built

    @staticmethod
    def _platform_tag() -> str:
        """The tag to stamp: the caller's, or this machine's corrected for macOS.

        ``sysconfig`` describes the *interpreter*, and on macOS it describes it
        twice over. A universal2 CPython reports ``macosx-10-9-universal2``
        whatever it runs on, because the interpreter genuinely holds both
        slices; the binary beside it holds one, since Zig builds one
        architecture. And ``10_9`` is not a tag pip accepts for arm64 at all -
        arm64 macOS starts at 11.0 - so a straight substitution would produce a
        wheel that installs nowhere. This path is the local-development
        fallback; ``scripts/build_wheels.py`` always passes the tag explicitly.
        """
        override = os.environ.get("GIST_WHEEL_PLATFORM")
        if override:
            return override
        tag = sysconfig.get_platform().replace("-", "_").replace(".", "_")
        if not tag.startswith("macosx_"):
            return tag
        _, major, minor, arch = tag.split("_", 3)
        if arch == "universal2":
            arch = platform.machine()
        if arch == "arm64" and int(major) < 11:
            major, minor = "11", "0"
        return f"macosx_{major}_{minor}_{arch}"

    def finalize(self, version: str, build_data: dict[str, Any], artifact_path: str) -> None:
        staging = getattr(self, "_staging", None)
        if staging is not None:
            staging.cleanup()
            self._staging = None
