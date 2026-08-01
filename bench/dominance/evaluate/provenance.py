#!/usr/bin/env python3
"""Reproducibility provenance for a gist evaluation bundle.

A performance number is only evidence if a third party can say *on what*. This
module captures the machine, the corpus, and the tool identities that produced a
bundle — the superset of the certify `machine.json` keys required by
`irregex/contract/performance_evidence.toml` `[provenance]`.

It is deliberately importable + stdlib-only: the evaluator (`evaluate.py`), the
verifier (`report.py`), and the Anvil remote runner all read the SAME capture,
so a Mac-arm64 bundle and an Anvil-linux-x86_64 bundle are described in one
vocabulary and can be compared field-for-field.

Capability degrades LOUDLY, never silently: a field the host cannot measure is
recorded as ``null`` with a sibling ``*_note``, not fabricated.
"""

# ruff: noqa: S603 — provenance capture shells fixed, trusted host commands
# (git / sysctl / diskutil / stat) with literal argv only.

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess


KERNEL = Path(__file__).resolve().parents[3]  # evaluate → dominance → bench → package root
REPO = KERNEL


def _climb_file(*rel_parts: str) -> Path | None:
    """Probe every ancestor for *rel_parts; also try irregex/<rel> for a sibling checkout."""
    override = os.environ.get("IRREGEX_CONTRACT", "").strip()
    if override and rel_parts[-1] == "engine.toml":
        p = Path(override)
        return p if p.is_file() else None
    here = Path(__file__).resolve().parent
    for ancestor in (here, *here.parents):
        for prefix in (Path(), Path("irregex")):
            cand = ancestor / prefix.joinpath(*rel_parts)
            if cand.is_file():
                return cand
    return None

# Machine-key contract (mirrors irregex/contract/performance_evidence.toml [provenance].machine_keys).
MACHINE_KEYS = (
    "machine_id",
    "cpu_model",
    "cpu_count",
    "ram_bytes",
    "os",
    "kernel",
    "arch",
    "filesystem",
    "git_commit",
    "git_dirty",
    "gist_engine_version",
    "gist_abi_version",
)
CORPUS_KEYS = ("corpus_id", "file_count", "total_bytes", "manifest_sha256")
TOOL_KEYS = ("tool", "identity")

_SEMVER = re.compile(r"v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?")
_SLUG = re.compile(r"[^a-z0-9]+")


def _cmd(*args: str) -> str:
    """Return stripped stdout of a command, or '' on any failure."""
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def _sysctl(key: str) -> str:
    return _cmd("sysctl", "-n", key)


def _cpu_model() -> str:
    return (
        _sysctl("machdep.cpu.brand_string")
        or _linux_cpu_model()
        or platform.processor()
        or "unknown"
    )


def _linux_cpu_model() -> str:
    """`model name` from /proc/cpuinfo (Linux); '' elsewhere."""
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return ""


def _ram_bytes() -> int:
    darwin = _sysctl("hw.memsize")
    if darwin.isdigit():
        return int(darwin)
    try:
        return os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    except (OSError, ValueError):
        return 0


def _filesystem() -> str:
    if platform.system() == "Darwin":
        for line in _cmd("diskutil", "info", "/").splitlines():
            if "File System Personality" in line:
                return line.split(":", 1)[1].strip()
        return "unknown"
    fs = _cmd("stat", "-f", "-c", "%T", "/")  # GNU stat: filesystem type
    return fs or "unknown"


def slugify(*parts: str) -> str:
    """Stable lowercase machine slug from arbitrary identity parts."""
    joined = "-".join(p for p in parts if p)
    return _SLUG.sub("-", joined.lower()).strip("-")


def gist_versions(gist_bin: Path | None) -> tuple[str, str]:
    """(engine_version, abi_version) from the live binary, falling back to the contract.

    The binary is authoritative; the contract mirror is the offline fallback so
    provenance capture never hard-depends on a built binary.
    """
    engine = abi = ""
    if gist_bin and gist_bin.exists():
        out = _cmd(str(gist_bin), "--version")
        if m := _SEMVER.search(out):
            engine = m.group(0)
        if m := re.search(r"abi[ =:]+v?(\d+)", out, re.IGNORECASE):
            abi = m.group(1)
    if not engine or not abi:
        contract = _climb_file("contract", "engine.toml")
        if contract is not None:
            try:
                text = contract.read_text()
                if not engine and (m := re.search(r'engine_version\s*=\s*"([^"]+)"', text)):
                    engine = m.group(1)
                if not abi and (m := re.search(r"abi_version\s*=\s*(\d+)", text)):
                    abi = m.group(1)
            except OSError:
                pass
    return engine or "unknown", abi or "unknown"


def machine(repo: Path = REPO, gist_bin: Path | None = None) -> dict[str, object]:
    """Capture the full machine provenance block (all MACHINE_KEYS)."""
    system = platform.system()
    arch = platform.machine()
    engine, abi = gist_versions(gist_bin)
    # A remote runner (the Anvil path) syncs a clean working tree at a pinned SHA
    # WITHOUT the multi-GB `.git`, so `git rev-parse` can't speak there. When the
    # caller asserts the pinned commit via BILLY_EVAL_GIT_COMMIT, honor it (the
    # sync is clean-tree-gated locally, so the tree provably equals that SHA);
    # otherwise fall back to the live repo.
    pinned = os.environ.get("BILLY_EVAL_GIT_COMMIT", "").strip()
    if pinned:
        commit = pinned
        dirty = os.environ.get("BILLY_EVAL_GIT_DIRTY", "").strip() in ("1", "true", "yes")
    else:
        commit = _cmd("git", "-C", str(repo), "rev-parse", "HEAD") or "unknown"
        dirty = bool(_cmd("git", "-C", str(repo), "status", "--porcelain"))
    cpu = _cpu_model()
    return {
        "machine_id": slugify(cpu, system, arch),
        "cpu_model": cpu,
        "cpu_count": int(_sysctl("hw.ncpu") or os.cpu_count() or 0),
        "ram_bytes": _ram_bytes(),
        "os": f"{system} {platform.release()}",
        "kernel": platform.release(),
        "arch": arch,
        "filesystem": _filesystem(),
        "git_commit": commit,
        "git_dirty": dirty,
        "gist_engine_version": engine,
        "gist_abi_version": abi,
    }


def tool_identity(name: str, executable: Path | str) -> str:
    """Exact identity of a benchmarked tool: sha256 of its bytes.

    A content hash is stronger than a self-reported ``--version`` (it pins the
    actual executable, including local patches), and matches the certify
    ``tool-versions.txt`` format ``<tool> sha256:<hex>``.
    """
    path = Path(executable)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return f"sha256:{digest.hexdigest()}"


def corpus_manifest(paths_list: Path, repo: Path, out_tsv: Path) -> dict[str, object]:
    """Hash a doc→path list into a byte-pinned manifest; return corpus provenance.

    Mirrors certify.sh's manifest emitter: a NUL-separated ``paths.list`` (gist's
    persisted doc table) is hashed file-by-file, guarding against a file mutating
    mid-hash (a live coworking tree is not a benchmark corpus). Returns the
    ``CORPUS_KEYS`` block plus the manifest's own sha256.
    """
    raw = paths_list.read_bytes()
    manifest = hashlib.sha256()
    tmp = out_tsv.with_suffix(out_tsv.suffix + ".tmp")
    count = total = 0
    with tmp.open("wb") as sink:
        header = b"path\tsize_bytes\tsha256\n"
        sink.write(header)
        manifest.update(header)
        for rel in raw.split(b"\0"):
            if not rel:
                continue
            if any(c in rel for c in (b"\t", b"\n", b"\r")):
                msg = f"manifest cannot encode control chars in path: {rel!r}"
                raise ValueError(msg)
            # Paths are raw bytes (gist's persisted doc table), so odd / invalid-UTF-8
            # corpus filenames hash byte-exactly — Path can't carry bytes, so os.* is
            # the correct tool here, not a lint smell.
            path = os.path.join(os.fsencode(repo), rel)  # noqa: PTH118 — bytes path
            digest = hashlib.sha256()
            with open(path, "rb") as source:  # noqa: PTH123 — bytes path
                before = os.fstat(source.fileno())
                for chunk in iter(lambda: source.read(1 << 20), b""):
                    digest.update(chunk)
                after = os.fstat(source.fileno())
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                msg = f"corpus file changed while hashing: {os.fsdecode(rel)}"
                raise ValueError(msg)
            row = rel + f"\t{before.st_size}\t{digest.hexdigest()}\n".encode()
            sink.write(row)
            manifest.update(row)
            count += 1
            total += before.st_size
    tmp.replace(out_tsv)
    return {
        "corpus_id": "billy",
        "file_count": count,
        "total_bytes": total,
        "manifest_sha256": manifest.hexdigest(),
    }
