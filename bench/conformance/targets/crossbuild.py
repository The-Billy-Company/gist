#!/usr/bin/env python3
"""Hermetic cross-building: one frozen copy of the tree, twenty-two artifacts.

~10 agents edit this package concurrently, so a ten-minute sweep will sometimes
compile against a half-saved file belonging to somebody else — and that is
indistinguishable from a portability failure. Measured, twice:

  · the first full sweep scored six perfectly portable targets `unbuilt` on a
    neighbor's `use of undeclared identifier 'pathVerdictFused'`;
  · the second began with a *clean* control and still lost eleven rows to a
    mid-refactor `src/corpus/fresh/sweep.zig`, one of them reading
    literally `file contents changed during update`.

So this module never compiles the shared tree. `snapshot` freezes the package
plus its path dependencies once, and every target is built from those exact
bytes — which makes the sweep hermetic against concurrent edits *and*
reproducible, since all rows describe one recorded digest. `control` then
compile-checks that same snapshot for the host's own triple, so a failure whose
diagnostics also break the host can be scored `tree-broken` (inconclusive)
rather than `unbuilt` (a port gap).
"""

from __future__ import annotations

import hashlib
import re
import shutil
import subprocess
import time
from pathlib import Path

PKG = Path(__file__).resolve().parent.parent.parent.parent  # this repo root

# Reusing the live `.zig-cache` would reintroduce exactly the coupling the
# snapshot exists to remove; the *global* Zig cache is still shared, which is
# where the expensive libc/PCRE2 artifacts live, so this costs nothing.
# `.local` is the gitignored machine-local scratch — fuzz corpora, sweep output,
# and **live daemon sockets**, which `copytree` cannot copy at all. None of it is
# a build input, so excluding it is not a shortcut.
SKIP = shutil.ignore_patterns(
    ".zig-cache", "zig-cache", "zig-out", ".git", ".local", "artifact", "*.o", "*.a", "*.sock",
)


def _path_deps() -> list[str]:
    """The sibling directories `build.zig.zon` reaches for via a relative path.

    A package that reaches for `../something` does not compile from a snapshot
    of itself — the snapshot has to reproduce the *relative layout*, not just
    the directory. `gist` reaches for `../irregex`, so a sweep of this package
    alone would fail at configure time before compiling a byte. Read from the
    manifest rather than hardcoded, so a path dependency added tomorrow is
    carried automatically instead of failing the next sweep.
    """
    zon = (PKG / "build.zig.zon").read_text()
    return sorted({m for m in re.findall(r'\.path\s*=\s*"([^"]+)"', zon)})


def _mirror(srcdir: Path, dstdir: Path) -> None:
    # `copy_function=copy` (not `copy2`) because preserving mtimes would let
    # Zig's cache confuse a snapshot with the live tree; dangling symlinks and
    # non-regular files are skipped rather than fataling the sweep.
    shutil.copytree(srcdir, dstdir, ignore=SKIP, symlinks=True,
                    copy_function=shutil.copy, ignore_dangling_symlinks=True)


def snapshot(dest: Path) -> dict:
    """Freeze the package + its path deps under `dest`; report files · bytes · digest.

    `build_root` is the directory inside the snapshot that `zig build` runs in.
    """
    if dest.exists():
        shutil.rmtree(dest)
    build_root = dest / PKG.name
    _mirror(PKG, build_root)
    deps = []
    for rel in _path_deps():
        srcdir = (PKG / rel).resolve()
        if not srcdir.is_dir():
            continue
        # Land it at the same relative offset from the package copy, so the
        # manifest's own `../<name>` resolves inside the snapshot unchanged.
        dstdir = (build_root / rel).resolve()
        if not dstdir.exists():
            dstdir.parent.mkdir(parents=True, exist_ok=True)
            _mirror(srcdir, dstdir)
            deps.append(rel)

    files = sorted(p for p in dest.rglob("*") if p.is_file() and not p.is_symlink())
    d, total = hashlib.sha256(), 0
    for p in files:
        d.update(p.relative_to(dest).as_posix().encode())
        b = p.read_bytes()
        d.update(b)
        total += len(b)
    return {"root": str(dest), "build_root": str(build_root), "path_deps": deps,
            "files": len(files), "bytes": total, "sha256": d.hexdigest()}


# The `gist` step rather than the default `install`: this package ships three CLIs
# and the portability sweep only ever *executes* `gist`, so compiling `relate` and
# `irregex` for each of 22 targets would triple the sweep to prove nothing. It is
# the same artifact from the same module graph — measured, 52 s for `s390x-linux-gnu`.
STEP = "gist"


def _zig(triple: str, prefix: str, src: Path, cpu: str | None = None) -> subprocess.CompletedProcess:
    cmd = ["zig", "build", STEP, "-Doptimize=ReleaseFast", f"-Dtarget={triple}", "--prefix", prefix]
    if cpu:
        cmd.append(f"-Dcpu={cpu}")
    return subprocess.run(cmd, cwd=src, capture_output=True, text=True)


def control(triple: str, src: Path) -> dict:
    """Compile-check `src` for the host, to tell tree breakage from a port gap."""
    proc = _zig(triple, "/tmp/gist-portable-control", src)
    return {"ok": proc.returncode == 0, "triple": triple,
            "errors": [] if proc.returncode == 0 else diagnostics(proc.stderr, limit=40)}


def frozen(dest: Path, triple: str, attempts: int = 3, say=lambda _m, end="\n": None) -> tuple[dict, dict]:
    """A snapshot that has *proven* it compiles — the thing a sweep actually needs.

    A single freeze is a coin flip: copying 3,300 files takes long enough to catch
    a neighbor mid-save, and the third sweep died exactly that way (`control:
    BROKEN (2 diagnostics)` on a tree that compiled cleanly a minute later). The
    window is small, though, so re-freezing clears it — and re-freezing is honest
    where scoring twenty-two rows `tree-broken` is merely inconclusive.

    Retrying is not the same as hiding: the returned control result is the real
    one, `attempt` records how many freezes it took, and a run that never gets a
    clean tree still returns the failure for `score` to mark `tree-broken` and for
    the certificate to refuse.
    """
    for attempt in range(1, attempts + 1):
        snap = snapshot(dest)
        say(f"snapshot: {snap['files']} files, {snap['bytes']:,} B, "
            f"sha256 {snap['sha256'][:16]}… (+ path deps {', '.join(snap['path_deps']) or 'none'})"
            + (f" — freeze {attempt}/{attempts}" if attempt > 1 else ""))
        say(f"control: compile-checking the snapshot for {triple}…", end="")
        ctl = control(triple, Path(snap["build_root"]))
        say(" clean" if ctl["ok"] else f" BROKEN ({len(ctl['errors'])} diagnostics)")
        snap["attempt"], ctl["attempts"] = attempt, attempt
        if ctl["ok"] or attempt == attempts:
            return snap, ctl
        say("control: a concurrent edit was caught mid-save — re-freezing rather than "
            "publishing a sweep that cannot distinguish that from a port gap")
        for e in ctl["errors"][:3]:
            say(f"  · {e}")
    raise AssertionError("unreachable")  # the loop returns on its final attempt


def build(triple: str, cpu: str | None, out: Path, src: Path) -> dict:
    """Cross-compile `src` into `out`; report ok · seconds · the `bin/gist` path."""
    t0 = time.monotonic()
    proc = _zig(triple, str(out), src, cpu)
    secs = round(time.monotonic() - t0, 1)
    exe = next((p for p in (out / "bin" / "gist", out / "bin" / "gist.exe") if p.exists()), None)
    return {
        "ok": exe is not None,
        "seconds": secs,
        "step": STEP,
        "exe": str(exe) if exe else None,
        "errors": None if exe else diagnostics(proc.stderr),
    }


def diagnostics(stderr: str, limit: int = 12) -> list[str]:
    """The `file:line: error:` lines from a failed `zig build`, deduped.

    `zig build` closes with a dependency tree ("compile exe gist … 16 errors")
    that says a target failed but not why, and it is the *last* thing on stderr —
    so a plain tail records the least useful lines available.
    """
    seen, out = set(), []
    for ln in stderr.splitlines():
        s = ln.strip()
        if ": error: " in s and s not in seen:
            seen.add(s)
            out.append(s)
    return out[:limit] or ["\n".join(stderr.strip().splitlines()[-6:])]


def site(err: str) -> str:
    """`file:line` of a diagnostic — the identity two builds are compared on."""
    return ":".join(err.split(":")[:2])
