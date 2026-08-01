#!/usr/bin/env python3
"""Layer H — the portability harness: how many targets gist reaches, and how far.

"ripgrep is more portable" is a claim about a *matrix*, so this measures one.
Per target it records the strongest tier gist actually reached, and refuses to
round up:

  unbuilt  nothing linked.
  builds   an artifact exists AND its own header says it is the promised
           format/arch/bits/endianness (`objfmt.py` reads the bytes, so a build
           that silently fell back to the host fails here instead of passing).
  runs     that artifact executed on a machine of that architecture — natively,
           under Rosetta, or in a foreign-arch container — and answered a real
           query, including a PCRE2 lookbehind that only the vendored C backend
           can serve.
  conforms-wine
           the full probe slate came back byte-identical to the native oracle,
           but through Wine's reimplementation of Win32 rather than a Windows
           kernel. Strictly above `runs`, strictly below `conforms`, and never
           folded into either — the lane's ceiling is declared in `matrix.py`,
           so the scorer cannot round it up.
  conforms every one of `bench/harness/probes.zig`'s twelve query classes came
           back byte-identical to the native oracle, on the same generated
           corpus, in BOTH the live-scan and the indexed pass. The indexed pass
           is what makes the big-endian row mean something: it proves the
           on-disk artifact format is endian-neutral, not just that the matcher
           runs.

The native oracle is itself pinned to ripgrep, so a `conforms` row is
transitively a claim about rg's own bytes, not merely about agreeing with
ourselves.

Everything is one machine: this host cross-compiles every row with no cross
toolchain installed, where ripgrep's release matrix spans four runner images
plus `cross`'s Docker containers.

    python3 portable.py run                     # the sweep → artifact/portable.json
    python3 portable.py run --only s390x-linux-gnu --only riscv64-linux-musl
    python3 portable.py run --no-exec           # build+identify only (no Docker)
    python3 portable.py status                  # read back the last sweep
    python3 portable.py selftest                # offline: corpus + matrix + objfmt

stdlib only. Docker is optional: a lane whose runtime is absent is recorded as
`builds` with the reason, never silently promoted.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import shutil
import sys
import tempfile
import time
from pathlib import Path

import corpus as corpus_mod
import crossbuild
import objfmt
import slate
from matrix import (
    FLAVOR_SUBSTITUTED,
    MATRIX,
    PROBES,
    RANK,
    TIERS,
    host_triple,
    lane_ceiling,
    no_lane_why,
)

HERE = Path(__file__).resolve().parent
PKG = HERE.parent.parent.parent  # this repo root
ARTIFACT = HERE / "artifact"
RG_MATRIX = HERE / "ripgrep-matrix.json"


def score(target: dict, orc: dict, control_errors: list[str]) -> None:
    """Fold a row's evidence into its tier. Only ever promotes on proof.

    `control_errors` are the host-target diagnostics from `crossbuild.control`;
    they are what lets a coworker's half-saved file be told apart from a real
    port gap.
    """
    t = target
    if not t["build"]["ok"]:
        # Shared blame: if every diagnostic this target produced also fires for
        # the host's own triple, the tree is broken and the row says nothing
        # about portability. Only diagnostics unique to this target are a gap.
        errs = t["build"].get("errors") or []
        shared = {crossbuild.site(e) for e in errs} & {crossbuild.site(e) for e in control_errors}
        unique = [e for e in errs if crossbuild.site(e) not in shared]
        if errs and not unique:
            t["tier"] = "tree-broken"
            t["notes"].append("the tree did not compile for the host either, so this row is not a "
                              "portability verdict — re-run on a tree that builds")
            return
        t["tier"] = "unbuilt"
        if shared:
            t["notes"].append(f"{len(shared)} of {len(errs)} diagnostics also fire for the host "
                              "triple (concurrent edit); the rest are target-specific")
        return
    if not t["identity"]["ok"]:
        t["tier"] = "unbuilt"
        t["notes"].append(f"artifact identity mismatch: {t['identity']['why']}")
        return
    t["tier"] = "builds"
    ex = t.get("exec") or {}
    if not ex.get("live", {}).get("ok"):
        t["notes"].append(ex.get("live", {}).get("reason") or "not executed")
        return
    pc = ex["live"].get("pcre2") or {}
    t["pcre2"] = bool(pc.get("rc") == 0 and pc.get("files", 0) > 0)
    t["tier"] = "runs"
    if not t["pcre2"]:
        t["notes"].append("executed, but the PCRE2 lookbehind probe did not answer")
        return
    # Conformance: every probe's (sha256, exit code) equal to the oracle's, in
    # both passes. An indexed pass that declined to index is not conformance.
    for pas in ("live", "indexed"):
        got, want = ex.get(pas, {}), orc[pas]
        if not got.get("ok"):
            t["notes"].append(f"{pas} pass did not complete: {got.get('reason')}")
            return
        if got.get("tree") != want.get("tree"):
            t["notes"].append(f"{pas} pass saw {got.get('tree')} corpus files, "
                              f"oracle saw {want.get('tree')}")
            return
        diffs = [PROBES[i][0] for i in range(len(PROBES)) if got["probes"].get(i) != want["probes"][i]]
        t["conform"] = {**t.get("conform", {}),
                        pas: {"identical": len(PROBES) - len(diffs), "of": len(PROBES), "differing": diffs}}
        if diffs:
            t["notes"].append(f"{pas} pass differs from the native oracle on: {', '.join(diffs)}")
            return
    if ex["indexed"].get("index") != "ok":
        t["notes"].append("indexed pass ran but `gist index` declined, so only the live path is proven")
        return
    # The lane, not the output, decides the top rung. A translation layer that
    # reproduced every byte still did not prove the real kernel does.
    t["tier"] = ceiling = lane_ceiling(t["lane"])
    if ceiling != "conforms":
        t["notes"].append(f"every probe class matched the native oracle, but through the "
                          f"{t['lane'].split(':', 1)[0]} lane — not a native kernel of this platform")


def summarize(rows: list[dict], rg: dict) -> dict:
    """The domination question, answered from the rows rather than asserted."""
    reached = {r["triple"]: r["tier"] for r in rows}
    covered = {}  # rg triple → the strongest tier any gist row reached for it
    for r in rows:
        for cov in r["rg"]:
            covered[cov["triple"]] = max(covered.get(cov["triple"], "unbuilt"), r["tier"],
                                         key=lambda t: RANK[t])
    declared = [t["triple"] for t in rg["targets"]]
    published = [t["triple"] for t in rg["targets"] if t["published"]]
    uncovered = [t for t in declared if RANK[covered.get(t, "unbuilt")] < RANK["builds"]]
    extra = sorted(r["triple"] for r in rows if not r["rg"] and RANK[r["tier"]] >= RANK["builds"])

    # The comparison stays partitioned by OS family because the *evidence* still
    # is. POSIX rows execute on a machine of their own architecture; Windows rows
    # execute through Wine's Win32 on the x86_64 row and not at all on the other
    # two arches, so the strongest Windows evidence is a rung below the strongest
    # POSIX evidence. One blended number would hide that; per family, the claim is
    # exact and each half can be read for what it actually proves.
    posix = [t["triple"] for t in rg["targets"] if t["os"] != "windows"]
    windows = [t["triple"] for t in rg["targets"] if t["os"] == "windows"]
    at = lambda ts, tier: sum(1 for t in ts if RANK[covered.get(t, "unbuilt")] >= RANK[tier])  # noqa: E731
    short = lambda ts: [t for t in ts if RANK[covered.get(t, "unbuilt")] < RANK["builds"]]  # noqa: E731

    return {
        "by_tier": {t: sorted(k for k, v in reached.items() if v == t) for t in TIERS},
        "rg_declared": len(declared),
        "rg_published": len(published),
        "rg_covered_at_builds": at(declared, "builds"),
        "rg_covered_at_runs": at(declared, "runs"),
        "rg_covered_at_conforms": at(declared, "conforms"),
        "rg_uncovered": uncovered,
        "beyond_rg": extra,
        "coverage_per_rg_triple": covered,
        "posix": {
            "rg_declared": len(posix),
            "covered_at_builds": at(posix, "builds"),
            "covered_at_runs": at(posix, "runs"),
            "covered_at_conforms": at(posix, "conforms"),
            "uncovered": short(posix),
        },
        "windows": {
            "rg_declared": len(windows),
            "covered_at_builds": at(windows, "builds"),
            "covered_at_runs": at(windows, "runs"),
            "covered_at_conforms_wine": at(windows, "conforms-wine"),
            "covered_at_conforms": at(windows, "conforms"),
            "uncovered": short(windows),
            "why": "the openat/dirfd descent, file map, stat, argv, realpath and stdin "
                   "classification now go through one comptime seam (src/portal.zig) with a "
                   "Win32 arm: NtCreateFile against a root handle, a batched NtQueryDirectoryFile "
                   "drain so the walk stands on the same batched-metadata floor getattrlistbulk "
                   "and getdents64 give macOS and Linux, demand-paged NT sections instead of a "
                   "whole-file read, NtQueryInformationFile(.Id) for the volume identity "
                   "--one-file-system needs, and walker paths normalized to '/' before any ignore "
                   "rule or depth count sees them. The resident daemon has no unix socket there "
                   "and declines, which the cold path never depends on. No Windows kernel is "
                   "reachable from this host, so the executed rung is Wine's Win32, recorded as "
                   "conforms-wine.",
        },
        # Scored against rg's *declared* set rather than the 13 it actually
        # published, so the bar is the harder one. `dominates_posix` is the claim
        # Layer H is allowed to make; `dominates` stays here, unqualified and
        # honest, so no reader has to infer that Windows is missing.
        "dominates_posix": not short(posix) and bool(extra),
        "dominates": not uncovered and bool(extra),
    }


def sweep(only: list[str], no_exec: bool, keep: bool) -> dict:
    rg = json.loads(RG_MATRIX.read_text())
    by_triple = {t["triple"]: t for t in rg["targets"]}
    work = [row for row in MATRIX if not only or row[0] in only]
    if not work:
        raise SystemExit(f"portable: --only matched no row; known: {', '.join(r[0] for r in MATRIX)}")

    corpus_root = Path("/tmp/gist-portable-corpus")
    cmeta = corpus_mod.generate(corpus_root)
    say(f"corpus: {cmeta['files']} files, {cmeta['bytes']} B, sha256 {cmeta['sha256'][:16]}…")

    native_exe = PKG / "zig-out" / "bin" / "gist"
    if not native_exe.exists():
        raise SystemExit(f"portable: no native gist at {native_exe} — "
                         "run `zig build -Doptimize=ReleaseFast` first")
    say("oracle: native slate (live + indexed)…")
    orc = slate.oracle(native_exe, corpus_root)
    vs_rg = slate.oracle_vs_rg(native_exe, corpus_root)
    if vs_rg["checked"]:
        say(f"oracle: {vs_rg['identical']}/{vs_rg['of']} probe classes byte-identical "
            f"to {vs_rg['rg_version']}")

    snap, control = crossbuild.frozen(Path("/tmp/gist-portable-src"), host_triple(), say=say)
    src = Path(snap["build_root"])
    if control["ok"]:
        say("snapshot: every target below builds from these exact bytes")
    else:
        say("control: the snapshot still does not compile, so failed rows will be recorded "
            "`tree-broken` and the certificate will refuse them")

    have_docker = shutil.which("docker") is not None and subprocess.run(
        ["docker", "info"], capture_output=True).returncode == 0
    root = Path("/tmp/gist-portable-out")
    rows = []
    for triple, cpu, rg_triples, lane in work:
        say(f"[{triple}] building…", end="")
        out = root / triple
        b = crossbuild.build(triple, cpu, out, src)
        ident, got = {"ok": False, "why": "no artifact"}, {}
        if b["ok"]:
            ok, got, why = objfmt.verify(Path(b["exe"]), triple)
            ident = {"ok": ok, "why": why}
        row = {
            "triple": triple, "cpu": cpu, "lane": lane, "build": b,
            "identity": ident, "artifact": got, "notes": [], "tier": "unbuilt",
            "pcre2": None, "conform": {},
            "rg": [{"triple": rt,
                    **{k: by_triple[rt][k] for k in ("published", "pcre2", "abi", "build_host")},
                    "abi_flavor": "substituted-gnu" if rt in FLAVOR_SUBSTITUTED else "same"}
                   for rt in rg_triples],
        }
        say(f" {b['seconds']}s {'ok' if b['ok'] else 'FAILED'}")
        # Both container lanes need Docker; only the local ones don't. Spelling the
        # dependency as a prefix set keeps a new lane from silently claiming it can
        # run on a host with no runtime.
        containerized = lane.startswith(("docker:", "wine:"))
        runnable = lane != "none" and (have_docker or not containerized)
        if b["ok"] and ident["ok"] and not no_exec and runnable:
            say(f"[{triple}] executing on {lane}…", end="")
            try:
                row["exec"] = {
                    "live": slate.run_slate(lane, Path(b["exe"]), corpus_root, False, triple),
                    "indexed": slate.run_slate(lane, Path(b["exe"]), corpus_root, True, triple),
                }
            except subprocess.TimeoutExpired:
                row["exec"] = {"live": {"ok": False, "reason": f"execution timed out after {slate.TIMEOUT} s"}}
            say(" done")
        elif lane == "none":
            row["exec"] = {"live": {"ok": False, "reason": no_lane_why(triple)}}
        elif containerized and not have_docker:
            row["exec"] = {"live": {"ok": False,
                                    "reason": "Docker is unavailable on this host, so this lane could not be executed"}}
        score(row, orc, control["errors"])
        say(f"[{triple}] → {row['tier']}" + (f"  ({'; '.join(row['notes'])})" if row["notes"] else ""))
        rows.append(row)
        if not keep and b["ok"]:
            shutil.rmtree(out, ignore_errors=True)  # ~25 MB × 22 targets otherwise

    return {
        "schema": 1,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": {"machine": platform.machine(), "system": platform.system(),
                 "release": platform.release(), "docker": have_docker,
                 "zig": subprocess.run(["zig", "version"], capture_output=True, text=True).stdout.strip(),
                 "cross_toolchains_installed": 0},
        "corpus": cmeta,
        "snapshot": snap,
        "control": control,
        "oracle": {"exe": str(native_exe), "vs_ripgrep": vs_rg,
                   "tree": orc["live"]["tree"], "probe_classes": len(PROBES)},
        "ripgrep": {"provenance": rg["provenance"], "verification_tier": rg["verification_tier"],
                    "declared": len(rg["targets"]), "published": sum(t["published"] for t in rg["targets"])},
        "targets": rows,
        "summary": summarize(rows, rg),
    }


# ── surface ──────────────────────────────────────────────────────────────────


def say(msg: str, end: str = "\n") -> None:
    """Progress goes to stderr, so stdout stays the machine-readable channel."""
    print(msg, end=end, flush=True, file=sys.stderr)


def selftest() -> int:
    """Offline checks: probe-slate parity with probes.zig, corpus, matrix, objfmt."""
    fails = []
    src = (PKG / "bench" / "harness" / "probes.zig").read_text()
    for cls, kind, pat in PROBES:
        # The Zig source escapes backslashes; compare against that spelling.
        want = f'.class = "{cls}", .kind = .{kind}, .pattern = "{pat.replace(chr(92), chr(92) * 2)}"'
        if want not in src:
            fails.append(f"probe drift vs probes.zig: {cls} ({want!r} absent)")
    # Count only LIVE rows: probes.zig also carries commented-out classes staged
    # for its next republish, and counting those would make this check demand
    # probes that do not exist yet.
    live = sum(1 for ln in src.splitlines() if ".class = " in ln and not ln.lstrip().startswith("//"))
    if live != len(PROBES):
        fails.append(f"probes.zig declares {live} live classes, harness carries {len(PROBES)}")

    with tempfile.TemporaryDirectory() as td:
        a, b = Path(td) / "a", Path(td) / "b"
        if corpus_mod.generate(a) != corpus_mod.generate(b):
            fails.append("corpus generation is not deterministic")

    rg = json.loads(RG_MATRIX.read_text())
    if len(rg["targets"]) != 14:
        fails.append(f"rg baseline holds {len(rg['targets'])} targets, expected the recorded 14")
    for t in rg["targets"]:
        if not t["pcre2"]:
            fails.append(f"rg baseline says {t['triple']} lacks PCRE2 — re-read the workflow first")
    mapped = {t for row in MATRIX for t in row[2]}
    if missing := {t["triple"] for t in rg["targets"]} - mapped:
        fails.append(f"rg triples with no gist row: {sorted(missing)}")

    # objfmt must reject a mislabeled artifact, or "builds" means nothing.
    native = PKG / "zig-out" / "bin" / "gist"
    if native.exists():
        if not objfmt.verify(native, host_triple())[0]:
            fails.append("objfmt rejects this host's own native artifact")
        if objfmt.verify(native, "s390x-linux-gnu")[0]:
            fails.append("objfmt accepted a macOS artifact as s390x — the identity check is inert")

    for f in fails:
        say(f"selftest: FAIL {f}")
    print(f"selftest: {'ok' if not fails else f'{len(fails)} failure(s)'} "
          f"({len(PROBES)} probe classes, {len(MATRIX)} matrix rows, {len(rg['targets'])} rg triples)")
    return 1 if fails else 0


def status(path: Path) -> int:
    if not path.exists():
        say(f"portable: no sweep at {path} — run `python3 portable.py run`")
        return 1
    d = json.loads(path.read_text())
    s = d["summary"]
    print(f"sweep {d['generated_at']}  host {d['host']['machine']}-{d['host']['system']}  "
          f"zig {d['host']['zig']}")
    print(f"corpus {d['corpus']['files']} files / {d['corpus']['bytes']} B  "
          f"sha256 {d['corpus']['sha256'][:16]}…")
    vr = d["oracle"]["vs_ripgrep"]
    if vr.get("checked"):
        print(f"oracle pinned to {vr['rg_version']}: {vr['identical']}/{vr['of']} classes byte-identical")
    for t in TIERS:
        names = s["by_tier"][t]
        print(f"  {t:<11} {len(names):>2}  {', '.join(names)}")
    print(f"rg declared {s['rg_declared']} (published {s['rg_published']}) — "
          f"gist builds {s['rg_covered_at_builds']}, runs {s['rg_covered_at_runs']}, "
          f"conforms {s['rg_covered_at_conforms']}")
    p, w = s["posix"], s["windows"]
    print(f"  posix   {p['rg_declared']:>2} rg triples — builds {p['covered_at_builds']}, "
          f"runs {p['covered_at_runs']}, conforms {p['covered_at_conforms']}"
          + (f"  UNCOVERED {p['uncovered']}" if p["uncovered"] else ""))
    print(f"  windows {w['rg_declared']:>2} rg triples — builds {w['covered_at_builds']}, "
          f"runs {w.get('covered_at_runs', 0)}, "
          f"conforms-wine {w.get('covered_at_conforms_wine', 0)}, "
          f"conforms {w.get('covered_at_conforms', 0)}"
          + (f"  UNCOVERED {w['uncovered']}" if w["uncovered"] else ""))
    print(f"beyond rg: {len(s['beyond_rg'])}  → {', '.join(s['beyond_rg'])}")
    print(f"dominates posix: {s['dominates_posix']}   dominates unqualified: {s['dominates']}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("verb", nargs="?", default="run", choices=("run", "status", "selftest"))
    ap.add_argument("--only", action="append", default=[], metavar="TRIPLE")
    ap.add_argument("--no-exec", action="store_true", help="build + identify only; skip every execution lane")
    ap.add_argument("--keep", action="store_true", help="keep the per-target prefixes (~25 MB each)")
    ap.add_argument("--out", type=Path, default=ARTIFACT / "portable.json")
    a = ap.parse_args()
    if a.verb == "selftest":
        return selftest()
    if a.verb == "status":
        return status(a.out)
    result = sweep(a.only, a.no_exec, a.keep)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(result, indent=2) + "\n")
    say(f"\nwrote {a.out}")
    return status(a.out)


if __name__ == "__main__":
    sys.exit(main())
