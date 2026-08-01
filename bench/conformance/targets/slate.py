#!/usr/bin/env python3
"""Interrogating one binary: run the probe slate, get a comparable value back.

Every execution lane — this machine, Rosetta, a foreign-architecture container —
answers in exactly one currency: per probe class, `(sha256 of stdout, exit
code)`. That is what makes `conforms` a real claim rather than a vibe, because
two rows are comparable only if nothing about *how* they were measured differs.

Two implementations sit behind one `run_slate`. A container hashes in-image with
busybox `sha256sum`, so a QEMU-emulated target costs one process start instead
of twenty-six; the local lanes hash in Python, because macOS ships `shasum` and
not `sha256sum` and a lane must never differ from another by its hashing tool.

`oracle` is the native reference every cross row is diffed against, and
`oracle_vs_rg` pins that reference to ripgrep's own bytes — without it the sweep
would only prove the cross builds agree with us.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from matrix import (
    PCRE2_PROBE,
    PROBES,
    SLATE_FLAGS,
    WINE_DOCKERFILE,
    WINE_IMAGE,
    image_for,
    no_lane_why,
)

TIMEOUT = 1800  # a QEMU-emulated dense scan is slow, but never half an hour slow


def _script(exe: str, root: str, indexed: bool, wine: bool = False) -> str:
    """The probe slate as one POSIX-sh program, so a container costs one start."""
    # A PE reads `GIST_DIR` as a Windows path. `Z:` is Wine's standard mapping of
    # the Linux root, so the same directory is named twice — once for the shell's
    # `rm -rf`, once for the binary being interrogated.
    gist_dir = "Z:\\tmp\\gistdir" if wine else "/tmp/gistdir"
    run = f"wine {exe}" if wine else exe
    lines = [
        "set -e",
        f"cd {root}",
        f"export GIST_DIR='{gist_dir}'",
        "rm -rf /tmp/gistdir && mkdir -p /tmp/gistdir",
        f'echo "TREE $(find . -name \'*.go\' | wc -l | tr -d " ")"',
    ]
    if indexed:
        # Fail-loud: if indexing itself declines, the indexed pass must not be
        # mistaken for a live-scan pass that happened to agree.
        lines += [f"{run} index >/dev/null 2>&1 && echo 'INDEX ok' || echo 'INDEX fail'"]
    flag = "" if indexed else "--no-index"
    for i, (_cls, kind, pat) in enumerate(PROBES):
        f = "-F " if kind == "literal" else ""
        q = "'" + pat.replace("'", "'\\''") + "'"
        lines += [
            f"{run} {f}{q} {' '.join(SLATE_FLAGS)} {flag} . >/tmp/o 2>/dev/null; rc=$?",
            f'echo "PROBE {i} $(sha256sum < /tmp/o | cut -d" " -f1) $rc"',
        ]
    p = "'" + PCRE2_PROBE.replace("'", "'\\''") + "'"
    lines += [
        f"{run} -P {p} -c --sort path {flag} . >/tmp/p 2>/dev/null; rc=$?",
        'echo "PCRE2 $(wc -l < /tmp/p | tr -d \' \') $rc"',
    ]
    return "\n".join(lines)


def _parse(text: str) -> dict:
    """`(tree, index, probes[(sha, rc)], pcre2)` out of the slate's stdout."""
    out = {"tree": None, "index": None, "probes": {}, "pcre2": None}
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "TREE" and len(parts) == 2:
            out["tree"] = int(parts[1])
        elif parts[0] == "INDEX":
            out["index"] = parts[1]
        elif parts[0] == "PROBE" and len(parts) == 4:
            out["probes"][int(parts[1])] = (parts[2], int(parts[3]))
        elif parts[0] == "PCRE2" and len(parts) == 3:
            out["pcre2"] = {"files": int(parts[1]), "rc": int(parts[2])}
    return out


def run_slate(lane: str, exe: Path, corpus_root: Path, indexed: bool, triple: str = "") -> dict:
    """Execute the slate through `lane`; `{ok, reason, tree, index, probes, pcre2}`."""
    if lane.startswith("docker:"):
        return _in_container(lane.split(":", 1)[1], exe, corpus_root, indexed, image_for(triple))
    if lane.startswith("wine:"):
        return _in_wine(lane.split(":", 1)[1], exe, corpus_root, indexed)
    if lane in ("native", "rosetta"):
        return _on_this_machine(lane, exe, corpus_root, indexed)
    return {"ok": False, "reason": no_lane_why(triple)}


def wine_image_ready() -> tuple[bool, str]:
    """Ensure the Wine lane's image exists, building it once if it does not."""
    have = subprocess.run(["docker", "image", "inspect", WINE_IMAGE],
                          capture_output=True).returncode == 0
    if have:
        return True, WINE_IMAGE
    proc = subprocess.run(["docker", "build", "--platform", "linux/amd64",
                           "-t", WINE_IMAGE, "-"],
                          input=WINE_DOCKERFILE, text=True,
                          capture_output=True, timeout=TIMEOUT)
    if proc.returncode != 0:
        return False, (proc.stderr.strip()[-400:] or "docker build declined")
    return True, WINE_IMAGE


def _in_wine(plat: str, exe: Path, corpus_root: Path, indexed: bool) -> dict:
    """The Windows lane: a PE, loaded by Wine, inside a Linux container.

    Weaker evidence than a real kernel and labeled as such by `LANE_CEILING` —
    but the probe slate, the corpus, the flags, and the hashing tool are the same
    as every other container lane, so a `conforms-wine` row is comparable to a
    `conforms` one on everything except whose Win32 answered.
    """
    ok, image = wine_image_ready()
    if not ok:
        return {"ok": False, "reason": f"Wine lane image unavailable: {image}"}
    cmd = [
        "docker", "run", "--rm", "--platform", plat,
        "-v", f"{exe.parent}:/b:ro", "-v", f"{corpus_root}:/corpus:ro",
        image, "sh", "-c", _script("/b/" + exe.name, "/corpus", indexed, wine=True),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    parsed = _parse(proc.stdout)
    ok = len(parsed["probes"]) == len(PROBES)
    return {"ok": ok, "image": image, "wine": True,
            "reason": None if ok else (proc.stderr.strip()[-400:] or "slate produced no probe rows"),
            **parsed}


def _in_container(plat: str, exe: Path, corpus_root: Path, indexed: bool, image: str) -> dict:
    cmd = [
        "docker", "run", "--rm", "--platform", plat,
        "-v", f"{exe.parent}:/b:ro", "-v", f"{corpus_root}:/corpus:ro",
        image, "sh", "-c", _script("/b/" + exe.name, "/corpus", indexed),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    parsed = _parse(proc.stdout)
    ok = len(parsed["probes"]) == len(PROBES)
    return {"ok": ok, "image": image,
            "reason": None if ok else (proc.stderr.strip()[-400:] or "slate produced no probe rows"),
            **parsed}


def _on_this_machine(lane: str, exe: Path, corpus_root: Path, indexed: bool) -> dict:
    pre = ["arch", "-x86_64"] if lane == "rosetta" else []
    with tempfile.TemporaryDirectory() as gd:
        env = {**os.environ, "GIST_DIR": gd}
        out = {"tree": len(list(corpus_root.rglob("*.go"))), "index": None, "probes": {}, "pcre2": None}
        flag = [] if indexed else ["--no-index"]
        if indexed:
            rc = subprocess.run([*pre, str(exe), "index"], cwd=corpus_root,
                                capture_output=True, env=env).returncode
            out["index"] = "ok" if rc == 0 else "fail"
        for i, (_cls, kind, pat) in enumerate(PROBES):
            f = ["-F"] if kind == "literal" else []
            p = subprocess.run([*pre, str(exe), *f, pat, *SLATE_FLAGS, *flag, "."],
                               cwd=corpus_root, capture_output=True, env=env, timeout=TIMEOUT)
            out["probes"][i] = (hashlib.sha256(p.stdout).hexdigest(), p.returncode)
        p = subprocess.run([*pre, str(exe), "-P", PCRE2_PROBE, "-c", "--sort", "path", *flag, "."],
                           cwd=corpus_root, capture_output=True, env=env, timeout=TIMEOUT)
        out["pcre2"] = {"files": len(p.stdout.splitlines()), "rc": p.returncode}
        return {"ok": True, "reason": None, **out}


def oracle(exe: Path, corpus_root: Path) -> dict:
    """The native reference slate — every cross target is diffed against this."""
    live = run_slate("native", exe, corpus_root, indexed=False)
    idx = run_slate("native", exe, corpus_root, indexed=True)
    if not live["ok"] or not idx["ok"]:
        raise SystemExit(f"portable: the native oracle itself failed: {live.get('reason') or idx.get('reason')}")
    return {"live": live, "indexed": idx}


def oracle_vs_rg(exe: Path, corpus_root: Path) -> dict:
    """Pin the oracle to ripgrep: same flags, same corpus, byte-for-byte.

    Without this the sweep only proves the cross builds agree with *us*. With it,
    every `conforms` row is transitively a statement about rg's own output.
    """
    if not shutil.which("rg"):
        return {"checked": False, "reason": "rg not on PATH"}
    ver = subprocess.run(["rg", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    rows = []
    for cls, kind, pat in PROBES:
        f = ["-F"] if kind == "literal" else []
        with tempfile.TemporaryDirectory() as gd:
            g = subprocess.run([str(exe), *f, pat, *SLATE_FLAGS, "--no-index", "."],
                               cwd=corpus_root, capture_output=True, env={**os.environ, "GIST_DIR": gd})
        r = subprocess.run(["rg", *f, pat, "-n", "--sort", "path", "."],
                           cwd=corpus_root, capture_output=True)
        rows.append({"class": cls, "identical": g.stdout == r.stdout and g.returncode == r.returncode,
                     "lines": len(r.stdout.splitlines())})
    return {"checked": True, "rg_version": ver, "identical": sum(r["identical"] for r in rows),
            "of": len(rows), "rows": rows}
