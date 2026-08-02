"""Pin which `libirgx` this process maps, before anything imports `irgx`.

`libgist` links the engine dynamically and carries a loader-relative rpath, so
it binds the copy sitting *beside itself*. `irgx`'s loader resolves the
engine independently, out of the `irregex` checkout — and in a side-by-side dev
tree those two files are two different builds of the same source (a product
build configures its dependency itself, so the sibling's own `zig-out` copy can
be a different optimize mode entirely). Map both and the process holds two
engine implementations: a handle minted by one is then read by the other's
code, which is undefined behavior rather than a clean decline, since macOS
binds two-level and never even reaches the accidental first-wins rescue ELF
gives.

So gist names the copy its own library binds, and the substrate loader — which
has no way to know a product is in the room — follows it. An installed prefix
keeps both libraries in one directory, where this resolves to the file that
loader would have picked anyway and the pin is a no-op. An explicit
`$IRGX_LIB` always wins: a caller who names an engine meant that engine.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _dylib(stem: str) -> str:
    if sys.platform == "darwin":
        return f"lib{stem}.dylib"
    if sys.platform == "win32":
        return f"{stem}.dll"
    return f"lib{stem}.so"


def _product() -> Path | None:
    """The `libgist` this process will load — `$GIST_LIB`, else this tree's build."""
    if override := os.environ.get("GIST_LIB"):
        return candidate if (candidate := Path(override)).is_file() else None
    name = _dylib("gist")
    for parent in Path(__file__).resolve().parents:
        if (candidate := parent / "zig-out" / "lib" / name).is_file():
            return candidate
    return None


def _engine_beside_it() -> str | None:
    """The engine copy that `libgist` itself binds, if one is staged beside it."""
    product = _product()
    if product is None:
        return None
    engine = product.resolve().parent / _dylib("irgx")
    return str(engine) if engine.is_file() else None


if "IRGX_LIB" not in os.environ and (_engine := _engine_beside_it()) is not None:
    os.environ["IRGX_LIB"] = _engine
