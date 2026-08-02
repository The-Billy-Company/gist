"""The shipped library must load from an install directory, not only from the tree that built it.

`linkLibrary` records the dependency's own build output directory as an rpath, and
in this build that is a *relative* `.zig-cache/o/<hash>` path — true on the machine
that produced it and meaningless everywhere else. A product dylib carrying only
that rpath cannot resolve `@rpath/libirgx.dylib` when a consumer opens it, so it
fails at load with no call ever reaching the engine. `build.zig` adds a
loader-relative rpath so the shape we actually ship — every library in one lib
directory — is the loadable one; this is the gate on that.

The load must happen in a CHILD process with a clean environment. Once this
interpreter has opened the substrate, the loader satisfies a later `@rpath`
reference from the already-loaded image by install name, which is precisely how
the bindings kept working while a bare `dlopen` from anywhere else did not. A
same-process check would inherit that rescue and assert nothing.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

PRODUCT = "gist"
SUBSTRATE = "irgx"
SUFFIX = ".dylib" if sys.platform == "darwin" else ".so"


def _checkout(name: str) -> Path | None:
    """This package's checkout, or a sibling one — the polyrepo layout's own rule."""
    for parent in Path(__file__).resolve().parents:
        if not (parent / "build.zig").is_file():
            continue
        return parent if parent.name == name else parent.parent / name
    return None


def _recorded_dependencies(library: Path) -> str:
    """The libraries `library` records that it needs, as the platform states them.

    A load-time verdict alone cannot distinguish "imports the substrate" from
    "absorbed a copy of it", which is the whole question here — so a failure
    quotes the dependency table instead of leaving the reader to go find it.
    """
    probe = ["otool", "-L"] if sys.platform == "darwin" else ["objdump", "-p"]
    try:
        out = subprocess.run([*probe, str(library)], capture_output=True, text=True, check=False)
    except OSError as exc:  # the probe itself is absent — say so rather than vanish
        return f"<{probe[0]} unavailable: {exc}>"
    keep = ("NEEDED", "RUNPATH", "RPATH") if sys.platform != "darwin" else (".dylib",)
    lines = [ln.strip() for ln in out.stdout.splitlines() if any(k in ln for k in keep)]
    return "\n".join(lines) or f"<no dependency records; {probe[0]} said: {out.stderr.strip()}>"


def _library(checkout: str, stem: str) -> Path | None:
    """The built dylib. The checkout and the library are named separately: the
    engine's repository is `irregex` while its artifact is `libirgx`."""
    root = _checkout(checkout)
    if root is None:
        return None
    built = root / "zig-out" / "lib" / f"lib{stem}{SUFFIX}"
    return built if built.is_file() else None


def _open_in_a_child(library: Path, cwd: Path) -> subprocess.CompletedProcess[str]:
    """Open `library` the way a consumer would: one path, nothing preloaded, no
    search-path rescue from a developer's shell."""
    hidden = ("DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "LD_LIBRARY_PATH", "LD_PRELOAD")
    return subprocess.run(
        [sys.executable, "-c", f"import ctypes; ctypes.CDLL({str(library)!r})"],
        cwd=cwd,
        env={k: v for k, v in os.environ.items() if k not in hidden},
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.fixture
def installed(tmp_path: Path) -> Path:
    """Both libraries in one directory, the way a consumer receives them."""
    product, substrate = _library(PRODUCT, PRODUCT), _library("irregex", SUBSTRATE)
    if product is None or substrate is None:
        pytest.skip(f"lib{PRODUCT} or lib{SUBSTRATE} is not built; run `zig build` in both checkouts")
    lib = tmp_path / "lib"
    lib.mkdir()
    for artifact in (product, substrate):
        shutil.copy2(artifact, lib / artifact.name)
    return lib


def test_a_consumer_can_open_it_from_an_unrelated_directory(installed: Path, tmp_path: Path):
    """The regression: with a build-tree-only rpath this fails to resolve the substrate."""
    product = installed / f"lib{PRODUCT}{SUFFIX}"
    done = _open_in_a_child(product, tmp_path)
    assert done.returncode == 0, (
        f"a staged lib{PRODUCT} would not load:\n{done.stderr}"
        f"What it records that it needs:\n{_recorded_dependencies(product)}"
    )


def test_it_still_imports_the_substrate_rather_than_carrying_one(installed: Path, tmp_path: Path):
    """The other half. If the product quietly compiled its own copy of the engine it
    would load happily with no substrate beside it — and then hand back handles no
    other library can interpret."""
    product = installed / f"lib{PRODUCT}{SUFFIX}"
    records = _recorded_dependencies(product)
    (installed / f"lib{SUBSTRATE}{SUFFIX}").unlink()
    done = _open_in_a_child(product, tmp_path)
    assert done.returncode != 0, (
        f"lib{PRODUCT} loaded with no substrate present — it is not importing the shared "
        f"engine. What it records that it needs:\n{records}"
    )
