#!/usr/bin/env python3
"""gist certify — Layer H report (portability: the target matrix, executed).

Reads the `portable.json` emitted by `bench/targets/portable.py run` and splices
a self-contained **Layer H** section into CERTIFICATE.md between stable sentinel
markers, idempotent across re-mints.

Layer H answers the one claim the other layers cannot touch: *"ripgrep is more
portable."* That is a claim about a matrix, so the harness measures one — every
triple ripgrep declares in its own release workflow, plus targets it publishes
nothing for — and grades each by what was actually proven: `builds` (an artifact
whose own ELF/Mach-O/PE header matches the promised arch, bits, and endianness),
`runs` (that artifact executed on a machine of that architecture and answered a
real query, PCRE2 lookbehind included), `conforms-wine` (the full slate
byte-identical to the native oracle, but through Wine's Win32 rather than a
Windows kernel), `conforms` (all twelve of `bench/harness/probes.zig`'s query
classes byte-identical to the native oracle on a real machine of that
architecture, in both the live-scan and the indexed pass).

**Fail-closed.** This reporter refuses to splice a win it cannot support:

- if any triple ripgrep *declares* is not at least `builds` for gist — POSIX or
  Windows, since the floor is symmetric — there is no domination to claim;
- if gist reaches nothing beyond ripgrep's matrix, "strictly larger" is false;
- if the native oracle was not pinned byte-for-byte to a real `rg` on the same
  corpus, then `conforms` means only "agrees with ourselves" and the word is
  withdrawn;
- if no *cross* target conformed, the tier is unproven off the host arch;
- if a Windows triple is scored at the native `conforms` rung, since no Windows
  kernel is reachable from this host — a Wine row must stay at `conforms-wine`;
- if the Windows rows are present but none executed, so the section cannot
  describe an executed Windows matrix.

Each of those exits non-zero and writes nothing, so the presence of the section is
itself a claim that every gate above passed.

On success it also publishes a side-car receipt at `bench/certificate/artifact/portable.json`
— the same claim as data (per-target tier, ripgrep coverage, the pinned `rg` version,
the frozen-tree digest, and the sha256 of the sweep it was lifted from) so a re-mint
can re-verify the spliced table without re-running a two-hour sweep.

stdlib only.
"""

import argparse
import hashlib
import json
from pathlib import Path

START = "<!-- PORTABLE-LAYER-START -->"
END = "<!-- PORTABLE-LAYER-END -->"
HEADER = "## Layer H — portability (target matrix, executed)"

TIERS = ("tree-broken", "unbuilt", "builds", "runs", "conforms-wine", "conforms")
RANK = {t: i for i, t in enumerate(TIERS)}

# How a tier reads in the table: the glyph carries the claim, so a `builds` row
# can never be skimmed as if it had run — and `conforms-wine` is spelled with its
# lane in the cell, because the whole point of the rung is that a reader must not
# be able to skim it as `conforms`.
GLYPH = {
    "conforms": "**conforms**",
    "conforms-wine": "conforms *(wine)*",
    "runs": "runs",
    "builds": "builds",
    "unbuilt": "—",
    "tree-broken": "*(tree broken)*",
}


def rel_to_repo(p: Path) -> str | None:
    """`p` spelled from the repository root, so a receipt cites a path a re-mint can open.

    Falls back to the absolute path rather than a bare basename: this file's own name
    collides with the sweep's, and a receipt that appears to cite itself is worse than
    one that cites a path from another machine.
    """
    if not str(p):
        return None
    p = p.resolve()
    for parent in (p, *p.parents):
        if (parent / ".git").exists():
            return str(p.relative_to(parent))
    return str(p)


def gate(d: dict) -> list[str]:
    """Every reason this sweep does not support a portability win. Empty ⇒ splice."""
    s, why = d["summary"], []
    # Layer H is permitted two claims, each scored against its own evidence: strict
    # matrix domination (every triple rg declares is at least `builds`, plus targets
    # it publishes nothing for) and, separately, the tier that domination was proven
    # at — which is `conforms` on POSIX and `conforms-wine` on Windows. So the gate
    # holds the POSIX partition to strict domination, requires the Windows rows to be
    # present at all, and refuses to let the weaker Windows rung be laundered into the
    # stronger one. A sweep that quietly dropped the Windows rows fails here rather
    # than rendering a cleaner-looking win.
    if s["posix"]["uncovered"]:
        why.append(
            f"{len(s['posix']['uncovered'])} POSIX triple(s) ripgrep declares that gist does not even build: "
            + ", ".join(s["posix"]["uncovered"])
        )
    # A `tree-broken` row failed for a reason that also breaks the host build — a
    # coworker's half-saved file, not a port gap. It carries no portability
    # information in either direction, so the sweep is inconclusive rather than
    # negative, and the honest response is to re-run rather than to publish it.
    if broken := s["by_tier"].get("tree-broken"):
        why.append(
            f"{len(broken)} row(s) failed on diagnostics that also break the host build "
            f"({', '.join(broken)}) — the tree did not compile when the sweep ran; re-run it"
        )
    if s["windows"]["rg_declared"] == 0:
        why.append(
            "the sweep carries no Windows rows, so the section could not disclose the Windows gap"
        )
    # The `builds` floor is symmetric across the partition: a Windows triple rg
    # declares that gist cannot even produce an artifact for is a hole in the
    # unqualified claim, and dropping *some* of the Windows rows must fail as
    # loudly as dropping all of them.
    if unbuilt := s["windows"]["uncovered"]:
        why.append(
            f"{len(unbuilt)} Windows triple(s) ripgrep declares that gist does not even build: "
            + ", ".join(unbuilt)
        )
    # Windows evidence is a translation layer, so the one thing that must never
    # happen is a Windows triple appearing at the native `conforms` rung. Wine
    # reproducing every byte is not Windows reproducing every byte.
    if s["windows"].get("covered_at_conforms"):
        why.append(
            f"{s['windows']['covered_at_conforms']} Windows triple(s) are scored at the native "
            "`conforms` rung, but no Windows kernel was executed — a Wine row must stay at "
            "`conforms-wine`"
        )
    # And the disclosure runs the other way too: if Windows builds but nothing was
    # executed there, the section may not imply an executed Windows matrix.
    if s["windows"]["rg_declared"] and not s["windows"].get("covered_at_runs"):
        why.append(
            "no Windows triple was executed at all, so the section cannot describe an "
            "executed Windows matrix — re-run with the wine lane reachable, or report `builds`"
        )
    if not s["beyond_rg"]:
        why.append(
            "gist reached no target outside ripgrep's matrix, so 'strictly larger' is unsupported"
        )
    vs = d["oracle"].get("vs_ripgrep", {})
    if not vs.get("checked"):
        why.append(
            f"the native oracle was not pinned to ripgrep ({vs.get('reason', 'not checked')}), "
            "so conformance would only mean agreement with ourselves"
        )
    elif vs.get("identical") != vs.get("of"):
        why.append(
            f"the native oracle differs from {vs.get('rg_version')} on "
            f"{vs['of'] - vs['identical']}/{vs['of']} probe classes"
        )
    # A `conforms` row on the host's own native triple proves nothing about
    # cross-compilation — it is the oracle comparing itself. At least one row
    # built for a *different* machine must have conformed.
    native = "aarch64-macos" if d["host"]["machine"] == "arm64" else "x86_64-macos"
    if not [t for t in d["targets"] if t["tier"] == "conforms" and t["triple"] != native]:
        why.append(
            "no cross-compiled target conformed, so the tier is unproven off the host architecture"
        )
    if d["corpus"]["files"] < 1:
        why.append("the conformance corpus is empty")
    # A matrix is only a matrix if every row describes the same source. ~10 agents
    # edit this package concurrently, so a sweep that did not freeze the tree could
    # have compiled 22 different trees and called the result one comparison.
    if not d.get("snapshot", {}).get("sha256"):
        why.append(
            "the sweep records no frozen-tree digest, so its rows cannot be shown "
            "to describe one identical set of source bytes"
        )
    return why


def render(d: dict) -> str:
    """Render the Layer H markdown section from a portable.json sweep."""
    s, host, orc = d["summary"], d["host"], d["oracle"]
    vs = orc["vs_ripgrep"]
    rg = d["ripgrep"]
    rows = d["targets"]
    conforms = s["by_tier"]["conforms"]
    wine_conforms = s["by_tier"].get("conforms-wine", [])
    executed = [t for t in rows if RANK[t["tier"]] >= RANK["runs"]]

    # The Windows rows that still stop short, with the recorded reason. Once Windows
    # builds, the interesting residue is not a compiler diagnostic any more — it is
    # which rows had no lane on this host and why, which is a fact about the measuring
    # machine and is reported as one.
    win_short = [
        (t["triple"], "; ".join(t["notes"]) or "no reason recorded")
        for t in rows
        if "windows" in t["triple"] and RANK[t["tier"]] < RANK["conforms-wine"]
    ]

    lines = [
        START,
        HEADER,
        "",
        (
            "_The portability claim, measured rather than argued. `bench/targets/portable.py` "
            f"cross-compiles **{len(rows)} targets from this one machine** — a {host['machine']}-"
            f"{host['system']} host with **{host['cross_toolchains_installed']} cross toolchains "
            "installed** — and grades each by what it actually proved. `builds` means an artifact "
            "exists *and* its own ELF/Mach-O/PE header reports the promised architecture, width, and "
            "endianness (`bench/targets/objfmt.py` reads the bytes, so a build that silently fell "
            "back to the host fails instead of passing). `runs` means that artifact executed on a "
            "machine of that architecture and answered a real query — including a PCRE2 lookbehind, "
            "which the linear engine cannot represent, so serving it proves the **vendored C** "
            "cross-compiled too. `conforms` means all "
            f"{orc['probe_classes']} of `bench/harness/probes.zig`'s query classes came back "
            "**byte-identical** to the native oracle, in both the live-scan and the indexed pass, on a "
            "real machine of that architecture. `conforms *(wine)*` is the same byte-for-byte result "
            "reached through Wine's reimplementation of Win32 — a rung of its own, strictly below "
            "`conforms`, because a translation layer agreeing is not a kernel agreeing._"
        ),
        "",
        (
            f"- host: **{host['machine']}-{host['system']} {host['release']}** · zig `{host['zig']}` · "
            f"corpus {d['corpus']['files']} files / {d['corpus']['bytes']:,} B "
            f"(generated, sha256 `{d['corpus']['sha256'][:16]}…`)"
        ),
        (
            f"- oracle **pinned to ripgrep**: {vs['identical']}/{vs['of']} probe classes byte-identical "
            f"to `{vs['rg_version']}` on the same corpus, exit codes included — so a `conforms` row "
            "below is transitively a statement about rg's own bytes, not about agreeing with ourselves"
        ),
        (
            f"- one tree, {len(rows)} rows: the package and its path dependencies were frozen to "
            f"{d['snapshot']['files']:,} files / {d['snapshot']['bytes']:,} B "
            f"(sha256 `{d['snapshot']['sha256'][:16]}…`) and compile-checked for the host's own "
            "triple before the sweep began, so every row below describes the *same* source bytes "
            "rather than whatever the ~10 coworker agents on this branch had saved at the moment "
            "that target's turn came up"
        ),
        (
            f"- ripgrep's baseline: **{rg['declared']} triples declared** in its release workflow, "
            f"**{rg['published']} published** in 15.2.0, every one built `--features pcre2` "
            f"(`{rg['provenance']['release_workflow']['url'].split('/')[-1]}`, read "
            f"{rg['provenance']['release_workflow']['read_on']}) — across "
            f"**{len(rg['provenance']['release_workflow']['runner_images'])} runner images** plus "
            "`cross`'s Docker containers"
        ),
        "",
        "| gist target | tier | artifact | size | PCRE2 | executed on | ripgrep's triple | rg ships it |",
        "|---|:--|:--|--:|:--:|:--|:--|:--:|",
    ]

    for t in sorted(rows, key=lambda r: (-RANK[r["tier"]], r["triple"])):
        a = t["artifact"] or {}
        # An unbuilt row has no artifact to describe, and a partly-filled template
        # ("—  -bit") would read like a measurement rather than an absence.
        if a.get("format"):
            fmt = f"{a['format']} {a.get('arch', '')} {a.get('bits', '')}-bit".strip()
            if a.get("endian") == "big":
                fmt += " **BE**"
            if a.get("static"):
                fmt += " static"
        else:
            fmt = "*none linked*"
        size = f"{a['size'] / (1 << 20):.1f} MiB" if a.get("size") else "—"
        lane = t["lane"] if RANK[t["tier"]] >= RANK["runs"] else "—"
        rgs = t["rg"]
        rg_col = (
            "<br>".join(
                f"`{c['triple']}`" + (" *(gnu flavor)*" if c["abi_flavor"] != "same" else "")
                for c in rgs
            )
            or "*none — rg publishes no such asset*"
        )
        ships = "<br>".join("yes" if c["published"] else "**no**" for c in rgs) or "—"
        pc = "yes" if t["pcre2"] else ("—" if t["pcre2"] is None else "**no**")
        cpu = " `-Dcpu=" + t["cpu"] + "`" if t["cpu"] else ""
        lines.append(
            f"| `{t['triple']}`{cpu} | {GLYPH[t['tier']]} "
            f"| {fmt} | {size} | {pc} | {lane} | {rg_col} | {ships} |"
        )

    beyond, p, w = s["beyond_rg"], s["posix"], s["windows"]
    lines += [
        "",
        (
            f"**On POSIX the matrix is strictly larger: all {p['rg_declared']} POSIX triples ripgrep "
            f"declares are covered — {p['covered_at_builds']} at `builds`, {p['covered_at_runs']} at "
            f"`runs`, {p['covered_at_conforms']} at `conforms` — and gist additionally reaches "
            f"{len(beyond)} targets ripgrep publishes no asset for "
            f"({', '.join(f'`{b}`' for b in beyond)}). "
            f"{len(executed)} targets were executed; {len(conforms)} conform byte-for-byte on a "
            f"real kernel of their own architecture and {len(wine_conforms)} more do so under Wine "
            "— stdout and exit code, in both passes.**"
        ),
        "",
        (
            f"**Windows is now covered too, and covered honestly.** All "
            f"{w['covered_at_builds']} of ripgrep's {w['rg_declared']} declared Windows triples "
            f"build from this same macOS host, and {w['covered_at_conforms_wine']} of them executed "
            f"the full {orc['probe_classes']}-class slate **byte-identical to the native oracle**, in "
            "both the live-scan and the indexed pass — through **Wine's** reimplementation of Win32, "
            "not through a Windows kernel. That is why those rows read `conforms *(wine)*` and are "
            "scored on their own rung strictly below `conforms`: the lane's ceiling is declared in "
            "`bench/targets/matrix.py` and enforced by the scorer, so a translation-layer pass "
            "cannot be rounded up no matter how clean its bytes are. **The unqualified claim "
            "\"gist's target matrix strictly dominates ripgrep's\" is therefore true at the "
            f"`builds` tier — {s['rg_covered_at_builds']}/{s['rg_declared']} declared triples plus "
            f"{len(beyond)} rg publishes nothing for — while the *executed* tier remains "
            f"asymmetric: {p['covered_at_conforms']}/{p['rg_declared']} POSIX triples on real "
            "kernels of their own architecture, Windows on Wine.**"
        ),
        "",
        (
            "What changed to get there: the descent, the whole-file map, `stat`, `argv`, `realpath` "
            "and stdin classification were POSIX calls scattered through the walk, and are now one "
            "seam — `src/portal.zig` — whose Windows arm speaks `NtCreateFile` with a root handle (the "
            "Win32 shape of `openat`), reads a file whole where POSIX maps it, and classifies a handle "
            "by device type where POSIX reads mode bits. The resident daemon has no unix socket on "
            "Windows and declines through the same seam's `resident_sessions` constant; the warm tier "
            "is an optimization the cold path never depends on, so a Windows build simply answers "
            "cold. Nothing about the little-endian POSIX rows moved: the seam is a `comptime` fork, "
            "and the POSIX arm is the call it replaced."
        ),
        *(
            [
                "",
                "The Windows rows that stop short do so for a recorded reason about *this host*, not "
                "about the artifact:",
                "",
                *(f"- `{t}` — {why}" for t, why in win_short),
            ]
            if win_short
            else []
        ),
        "",
        (
            "Three asymmetries are worth naming, because they are the substance of the claim rather "
            "than its scoreboard:"
        ),
        "",
        (
            f"1. **One machine, no cross toolchains.** Every row above was produced by `zig build "
            f"-Dtarget=…` on a single {host['machine']}-{host['system']} host. ripgrep's own matrix "
            f"needs {len(rg['provenance']['release_workflow']['runner_images'])} distinct CI runner "
            "images (`" + "`, `".join(rg["provenance"]["release_workflow"]["runner_images"]) + "`) "
            "plus pinned `cross` containers to compile the Linux legs. That is not a criticism of "
            "ripgrep — it is what Rust's cross story costs, and what Zig's shipped libc headers make "
            "unnecessary. The vendored PCRE2 rides along: it is C, cross-compiled by the same "
            "invocation, and the lookbehind column is the receipt."
        ),
        (
            "2. **The evidence tier is higher than the baseline's.** ripgrep's release pipeline "
            f"verifies each cross target with `{rg['verification_tier']['executed_check']}` — it does "
            "not run a search on them. Layer H's `conforms` rows run the full twelve-class slate and "
            "compare bytes, so where the two matrices overlap gist is held to a strictly stronger "
            "standard than the artifacts it is being compared against."
        ),
        (
            "3. **A published matrix is not a fixed matrix.** ripgrep declares "
            f"{rg['declared']} triples and 15.2.0 shipped {rg['published']}: "
            "`i686-unknown-linux-gnu` was published through 15.1.0 and is absent from 15.2.0 "
            "(`fail-fast: false` lets a release go out without a row that failed). The comparison "
            "above is scored against the **declared 14** anyway — the harder bar — and that "
            "32-bit x86 row is one gist reaches at `"
            + next((t["tier"] for t in rows if t["triple"] == "x86-linux-gnu"), "unbuilt")
            + "`."
        ),
        "",
        (
            "> Reproduce: `python3 bench/targets/portable.py run` (writes "
            "`bench/targets/artifact/portable.json`; `status` reads it back, `selftest` checks the "
            "probe slate against `probes.zig` offline). A row at `builds` either has **no execution "
            "lane on this host** — FreeBSD and NetBSD run no Linux container, Docker publishes no "
            "big-endian `linux/ppc64`, and Wine emulates Win32 rather than the CPU so an ARM64 PE "
            "has no loader here — or did not build; the harness records which, and never emulates a "
            "pass. This reporter is fail-closed: it splices nothing and exits non-zero if "
            "a triple ripgrep declares is unbuilt on either side of the partition, if the Windows "
            "rows are absent so the gap "
            "would go undisclosed, if gist reaches nothing beyond rg's matrix, if the oracle was not "
            "pinned byte-for-byte to a real `rg`, if no *cross* target conformed, if a Windows row is "
            "scored at the native `conforms` rung it did not earn, or if the Windows rows are present "
            "but none of them executed."
        ),
        END,
    ]
    return "\n".join(lines) + "\n"


def receipt(d: dict) -> dict:
    """The evidence a re-mint needs to re-verify the spliced section, without re-running.

    The certificate is prose; this is the same claim as data, so a later verifier can
    check the table it reads against the sweep it came from. It is deliberately not a
    copy of `portable.json` — it carries the *gated* facts (which triples, at which
    tier, against which ripgrep, over which frozen tree) plus the digest of the sweep
    those facts were lifted from, so a receipt cannot silently drift from its source.
    """
    s, vs = d["summary"], d["oracle"]["vs_ripgrep"]
    src = Path(d.get("__source__", ""))
    return {
        "layer": "H",
        "header": HEADER,
        "markers": [START, END],
        "claim": {
            # The executed rung the section's own prose is allowed to claim. Windows
            # is reached through Wine, so `posix` stays the ceiling of the unqualified
            # sentence even while `dominates_all` is true on the build matrix.
            "scope": "posix" if s["windows"]["covered_at_conforms"] == 0 else "all",
            "dominates_posix": s["dominates_posix"],
            "dominates_all": s["dominates"],
            "windows": s["windows"],
        },
        "sweep": {
            # Repo-relative, because the receipt sits in a *different* artifact dir
            # under the same basename — a bare `portable.json` would read as itself.
            "path": rel_to_repo(src),
            "sha256": hashlib.sha256(src.read_bytes()).hexdigest() if src.is_file() else None,
            "generated_at": d.get("generated_at"),
            "frozen_tree_sha256": d.get("snapshot", {}).get("sha256"),
            "control_build_ok": d.get("control", {}).get("ok"),
        },
        "oracle": {
            "pinned_to_ripgrep": bool(vs.get("checked")),
            "rg_version": vs.get("rg_version"),
            "identical_probe_classes": vs.get("identical"),
            "of_probe_classes": vs.get("of"),
        },
        "corpus": d["corpus"],
        "ripgrep": {
            "declared": d["ripgrep"]["declared"],
            "published": d["ripgrep"]["published"],
            "verification_tier": d["ripgrep"]["verification_tier"].get("_comment"),
        },
        "tiers": list(TIERS),
        # Why a row stopped where it did is as load-bearing as the tier itself, so
        # the lane rides along: a verifier can re-derive that no Windows row was
        # allowed above `conforms-wine` without re-reading the harness.
        "lane_ceilings": {"wine": "conforms-wine", "*": "conforms"},
        "targets": [
            {
                "triple": t["triple"],
                "tier": t["tier"],
                "lane": t.get("lane"),
                "rg_triples": [r["triple"] for r in t.get("rg", [])],
                "rg_publishes": [r["triple"] for r in t.get("rg", []) if r.get("published")],
                "size": (t.get("artifact") or {}).get("size"),
                "identity_ok": (t.get("identity") or {}).get("ok"),
                "pcre2": t.get("pcre2"),
            }
            for t in d["targets"]
        ],
        "counts": {tier: len(s["by_tier"].get(tier, [])) for tier in TIERS},
        "beyond_rg": s["beyond_rg"],
        "posix": s["posix"],
    }


def splice(cert: Path, section: str) -> None:
    """Replace the one marked block and retire pre-marker duplicates.

    Read and write are adjacent on purpose. ~10 agents splice into this one file
    concurrently and a layer has already been lost tonight to a stale whole-file
    write, so this reads the certificate as late as it can, edits only the bytes
    between its own two markers, and never reconstructs a region it does not own.
    """
    text = cert.read_text() if cert.exists() else "# gist — Dominance-and-Fit Certificate\n\n"
    lo = text.find(START)
    if lo != -1:
        hi = text.find(END, lo + len(START))
        if hi == -1:
            raise ValueError("portable certificate has a start marker without an end marker")
        prefix = text[:lo]
        while (orphan_hi := prefix.rfind(END)) != -1 and (
            orphan_lo := prefix.rfind(HEADER, 0, orphan_hi)
        ) != -1:
            prefix = (
                prefix[:orphan_lo].rstrip() + "\n\n" + prefix[orphan_hi + len(END) :].lstrip("\n")
            )
        text = prefix + section + text[hi + len(END) :].lstrip("\n")
    else:
        text = text.rstrip() + "\n\n" + section
    if not text.endswith("\n"):
        text += "\n"
    cert.write_text(text)

    # Verify the write survived rather than trusting it. A concurrent whole-file
    # write between our read and our write would land last and erase the section
    # silently; reading it straight back turns that into a loud failure here.
    back = cert.read_text()
    if not (START in back and END in back and HEADER in back):
        raise SystemExit(
            f"certify_portable_report: Layer H is absent from {cert} immediately after writing it "
            "— another writer clobbered the file between this read and write; re-run"
        )


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer H (portability) certificate report")
    ap.add_argument("--certificate", type=Path, required=True)
    ap.add_argument("--json", type=Path, required=True, help="bench/targets/artifact/portable.json")
    ap.add_argument(
        "--receipt",
        type=Path,
        default=None,
        help="side-car evidence file (default: <certificate dir>/portable.json)",
    )
    args = ap.parse_args()

    if not args.json.exists():
        print(f"certify_portable_report: no sweep at {args.json} — run `portable.py run` first")
        return 1
    d = json.loads(args.json.read_text())
    d["__source__"] = str(args.json)
    if refusals := gate(d):
        print("certify_portable_report: REFUSING to splice a portability win —")
        for r in refusals:
            print(f"  · {r}")
        return 1

    splice(args.certificate, render(d))
    # The side-car is written only after the section is spliced *and* verified, so the
    # receipt can never claim evidence for a section that is not in the certificate.
    rec = args.receipt or args.certificate.parent / "portable.json"
    rec.write_text(json.dumps(receipt(d), indent=2) + "\n")
    s = d["summary"]
    print(
        f"wrote Layer H (portability) → {args.certificate} "
        f"[{len(s['by_tier']['conforms'])} conforms, {len(s['beyond_rg'])} beyond rg]"
    )
    print(f"wrote Layer H receipt → {rec}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
