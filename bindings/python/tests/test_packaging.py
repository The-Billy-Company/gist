"""The shipped library must load from an install directory, and must not fork the engine's vocabulary.

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

The second invariant is about symbols rather than files, and it is the one
`build.zig` states: libgist links the substrate so that it **does not redefine**
`irgx_*`, and a host that also loads librelate therefore sees one engine
vocabulary rather than three. What libgist does carry is the engine's Zig code,
statically, because that is what linking a Zig module means — so "one copy of the
engine" is not the property to gate and never was. The gate is that exactly one
library in the process answers to an `irgx_*` name. That holds by construction
across the two copies because the FFI layer allocates through
`std.heap.c_allocator`: a row minted inside libgist's copy and freed inside
libirgx's crosses one process-wide malloc heap, not two allocators.

This used to be gated by deleting the substrate beside a staged libgist and
requiring the load to fail. That is a proxy for the symbol question, and an
environment-sensitive one: Zig records the dependency's cache directory as a
search path, `ZIG_LOCAL_CACHE_DIR` makes it absolute on CI while it is relative
on a dev machine, and an absolute one resolves the deleted library right back out
of the build cache. So the proxy asserted the invariant on one machine and
nothing at all on another. It reads the export table now.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tomllib
import zipfile
from pathlib import Path

import pytest

PRODUCT = "gist"
SUBSTRATE = "irgx"
SUFFIX = ".dylib" if sys.platform == "darwin" else ".so"


def _installed_name() -> str:
    """What the CLI is called inside the wheel — `hatch_build.py`'s `_LAYOUT`."""
    return f"{PRODUCT}.exe" if sys.platform == "win32" else PRODUCT


def _version() -> str:
    """Read from the manifest rather than the installed distribution: the wheel
    under test is built from this tree, and an editable install can be older."""
    manifest = Path(__file__).resolve().parents[1] / "pyproject.toml"
    return str(tomllib.loads(manifest.read_text())["project"]["version"])


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


def _search_paths(library: Path) -> tuple[str, ...]:
    """The runtime search paths `library` carries, as recorded load commands.

    A separate probe from the dependency table because the two live apart on Mach-O:
    `otool -L` lists what is needed and never where to look, and the where is a
    string inside an `LC_RPATH` command. ELF keeps both in the program header, so
    `objdump -p` answers once.
    """
    if sys.platform == "darwin":
        out = subprocess.run(
            ["otool", "-l", str(library)], capture_output=True, text=True, check=False
        )
        lines, paths, pending = out.stdout.splitlines(), [], False
        for line in lines:
            words = line.split()
            if "LC_RPATH" in words:
                pending = True
            elif pending and words[:1] == ["path"]:
                paths.append(words[1])
                pending = False
        return tuple(paths)
    out = subprocess.run(
        ["objdump", "-p", str(library)], capture_output=True, text=True, check=False
    )
    entries: list[str] = []
    for line in out.stdout.splitlines():
        words = line.split()
        if words[:1] in (["RUNPATH"], ["RPATH"]) and len(words) > 1:
            entries.extend(words[1].split(":"))
    return tuple(entries)


def _exported_symbols(library: Path) -> frozenset[str]:
    """The names `library` itself defines and offers to a linker.

    Deliberately not `dlsym`: a handle resolves its dependencies too, so asking a
    loaded libgist for `irgx_engine_open` succeeds by finding libirgx's — which is
    the very thing under test here. Only the export table distinguishes "answers to
    this name" from "knows someone who does".
    """
    probe = ["nm", "-gU"] if sys.platform == "darwin" else ["nm", "-D", "--defined-only"]
    try:
        out = subprocess.run([*probe, str(library)], capture_output=True, text=True, check=False)
    except OSError as exc:  # pragma: no cover - the probe is present on both CI images
        pytest.fail(f"cannot read {library.name}'s export table: {probe[0]} unavailable ({exc})")
    names = (line.split()[-1] for line in out.stdout.splitlines() if len(line.split()) >= 2)
    # Mach-O prefixes every C symbol with an underscore; ELF does not.
    return frozenset(n.removeprefix("_") if sys.platform == "darwin" else n for n in names)


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
        pytest.skip(
            f"lib{PRODUCT} or lib{SUBSTRATE} is not built; run `zig build` in both checkouts"
        )
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


def test_it_looks_beside_itself_for_the_substrate(installed: Path):
    """What makes the staged shape loadable, asserted directly.

    The load above can succeed for a reason we do not ship: Zig also records the
    dependency's build-cache directory, and where `ZIG_LOCAL_CACHE_DIR` is absolute
    that path resolves on the build machine forever. So the load proves "resolvable
    here", and only the recorded search path proves "resolvable beside itself".
    """
    paths = _search_paths(installed / f"lib{PRODUCT}{SUFFIX}")
    relative = "@loader_path" if sys.platform == "darwin" else "$ORIGIN"
    assert relative in paths, (
        f"lib{PRODUCT} records no loader-relative search path, so it can only find the "
        f"substrate at paths this build machine happens to have: {paths}"
    )


def test_it_does_not_redefine_the_substrates_vocabulary(installed: Path):
    """One library in a process answers to `irgx_*`, and it is the substrate.

    `build.zig` links libirgx precisely so this product does not restate the engine's
    C names; that is what lets a host load libgist and librelate together and still
    see one engine ABI. If the link were dropped — or the engine's own `export fn`
    surface pulled into this module — both libraries would define the same names and
    which one a call reached would depend on load order.

    Only the export table is asserted, and deliberately not "it records libirgx as a
    dependency". Whether that record survives is the linker's decision, not this
    repository's: ELF drops an `--as-needed` library that no undefined symbol needs, so
    a product whose statically linked Zig already satisfies everything records nothing
    while Mach-O keeps the entry regardless. The sibling products differ from each
    other on exactly that line today with identical `build.zig` link calls, which is
    the proof it is not a contract. Absent redefinition is what makes the vocabulary
    single; the dependency table only ever explained it.
    """
    product = installed / f"lib{PRODUCT}{SUFFIX}"
    exported = _exported_symbols(product)
    restated = sorted(n for n in exported if n.startswith(f"{SUBSTRATE}_"))
    assert not restated, (
        f"lib{PRODUCT} defines {len(restated)} of the substrate's own names, so a process "
        f"holding both has two answers for each: {restated[:8]}"
        f"\nWhat it records that it needs:\n{_recorded_dependencies(product)}"
    )


def test_the_export_table_can_tell_a_product_from_the_substrate(installed: Path):
    """The adverse half: the probe above must be able to fail.

    `restated` being empty is only evidence if a library that *does* export the
    engine's vocabulary would be caught — so run the same probe over the substrate,
    which carries all of it, and over this product, which carries its own verbs.
    A probe that reported "nothing exported" for both would pass the gate above
    while asserting nothing whatsoever.
    """
    substrate = _exported_symbols(installed / f"lib{SUBSTRATE}{SUFFIX}")
    product = _exported_symbols(installed / f"lib{PRODUCT}{SUFFIX}")
    assert f"{SUBSTRATE}_engine_open" in substrate, (
        f"lib{SUBSTRATE} does not export the engine vocabulary the gate looks for; the "
        f"probe is reading nothing, not reading an empty answer"
    )
    assert f"{PRODUCT}_run" in product, (
        f"lib{PRODUCT} does not export its own producer; the probe cannot see this "
        f"library's exports either"
    )
    assert not any(n.startswith(f"{PRODUCT}_") for n in substrate), (
        f"lib{SUBSTRATE} exports this product's verbs — the two vocabularies are not "
        f"separable, and the gate above cannot mean what it says"
    )


def _built_wheel(tmp_path: Path) -> zipfile.ZipFile:
    """A real wheel, built from the binary this checkout already has.

    `GIST_PREBUILT_BIN` is the same door `scripts/build_wheels.py` uses, so the
    hook copies rather than invoking Zig and this costs a file copy. Nothing is
    asserted about a wheel built some other way, because no other way ships.
    """
    binary = _checkout(PRODUCT)
    built = None if binary is None else binary / "zig-out" / "bin" / PRODUCT
    if built is None or not built.is_file():
        pytest.skip(f"no built {PRODUCT} to package; run `zig build`")
    root = Path(__file__).resolve().parents[1]
    done = subprocess.run(
        [sys.executable, "-m", "hatchling", "build", "-t", "wheel", "-d", str(tmp_path)],
        cwd=root,
        env={**os.environ, "GIST_PREBUILT_BIN": str(built)},
        capture_output=True,
        text=True,
        check=False,
    )
    wheels = sorted(tmp_path.glob("*.whl"))
    assert done.returncode == 0 and wheels, f"the wheel would not build:\n{done.stderr}"
    return zipfile.ZipFile(wheels[0])


def test_the_wheel_puts_the_cli_on_path(tmp_path: Path):
    """`pip install gist-search` must yield a runnable `gist`, not only an import.

    The CLI is the product and this wheel is the only channel that ships it
    prebuilt, so a wheel that carries the binary where only Python can reach it
    leaves every non-Python user building from source. `.data/scripts/` is what
    an installer copies into `bin`/`Scripts`.

    The mode is asserted with it, because the failure it guards is silent at
    install time and total at run time: a file that lands without its exec bit
    is on PATH and still cannot be run.
    """
    with _built_wheel(tmp_path) as wheel:
        scripts = [n for n in wheel.namelist() if ".data/scripts/" in n]
        assert scripts == [f"gist_search-{_version()}.data/scripts/{_installed_name()}"], (
            f"the wheel ships no CLI a shell can reach: {scripts}"
        )
        mode = wheel.getinfo(scripts[0]).external_attr >> 16
        assert mode & 0o111, f"the shipped `{PRODUCT}` is not executable (mode {oct(mode)})"


def test_the_wheels_two_copies_are_the_same_binary(tmp_path: Path):
    """Both rungs must land, and land identically.

    `gist/bin/` is where the shared `irgx` resolver looks and is the only rung
    that answers for an unactivated environment; `.data/scripts/` is the one a
    shell sees. Shipping both is deliberate — but two copies that could drift
    would be a bug rather than a design, so this pins them to one file. It is
    also the adverse half of the test above: it fails if a future change ships
    a Python shim under `scripts/` while the real binary stays inside the
    package.
    """
    with _built_wheel(tmp_path) as wheel:
        packaged = wheel.read(f"{PRODUCT}/bin/{_installed_name()}")
        shipped = wheel.read(f"gist_search-{_version()}.data/scripts/{_installed_name()}")
        assert shipped == packaged, (
            f"the CLI on PATH is not the binary the package resolves: "
            f"{len(shipped):,} bytes vs {len(packaged):,}"
        )
        assert not shipped.startswith(b"#!"), (
            "the shipped CLI is a script, not the native binary — an interpreter in "
            "front of gist costs more startup than a warm query costs in total"
        )


def test_the_package_declares_its_annotations_to_consumers():
    """Every function in this package is annotated, and PEP 561 says a consumer's
    type checker must ignore all of it unless the package ships this marker. So the
    failure mode is silent in both directions: nothing here breaks, and everyone
    downstream quietly gets `Any` for the whole API."""
    package = Path(__file__).resolve().parents[1] / PRODUCT
    assert (package / "py.typed").is_file(), (
        f"{PRODUCT} annotates its public API and then hides it: no py.typed marker"
    )
