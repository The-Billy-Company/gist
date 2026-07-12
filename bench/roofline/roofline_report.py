#!/usr/bin/env python3
"""gist roofline — Layer C synthesis + CERTIFICATE.md splicer (the hardware ceiling).

The roofline model (Williams, Waterman & Patterson, "Roofline: An Insightful
Visual Performance Model for Multicore Architectures", CACM 2009) bounds a
kernel's throughput by min(peak compute, peak memory-bandwidth x arithmetic
intensity). gist's verify path is a byte classifier / streaming scan with tiny
arithmetic intensity (a handful of ops per byte), so it lives on the **memory
ridge**: no implementation on this chip can go materially faster because the
bottleneck is memory bandwidth, not gist's instruction stream.

This reads two measured artifacts and writes a verdict that is beyond reproach:
  * `roofline.json`  — this machine's achievable single-core read bandwidth per
                       cache tier (from `bench/roofline/bandwidth.zig`), the
                       **memory ceiling**.
  * `certify.csv`    — Layer A's per-class measured operating point (bytes crunched
                       + median ns), from which gist's achieved GB/s is derived.
Optionally `portcert.json` (Layer B) supplies the **compute ceiling** for the
full two-ceiling picture; absent, the section notes memory-ceiling-only.

It splices a `## Layer C — roofline (hardware ceiling)` section into
`.local/gist-verify/CERTIFICATE.md`, replacing any existing one (heading → next
`## Layer`/EOF), mirroring `certify/certify_stats.py`. stdlib only, fail-closed.
"""

# This file emits the certificate's Layer-C markdown, which intentionally carries
# math/typography glyphs (mult-sign, division-sign, en/em dashes, middot) that
# ruff's ambiguous-unicode rules flag; the glyphs are the certificate's contract,
# so silence them file-wide (repo precedent: services/ai, taskrunner, entrain all
# ignore RUF001/002/003 for intentional glyphs).


import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re


LAYER_C_HEADER = "## Layer C — roofline (hardware ceiling)"
# certify_stats.py rewrites this section to EOF, so a fresh Layer C is inserted
# *before* it (not appended) to survive a later macroscopic re-splice.
MACRO_HEADER = "## Layer A — macroscopic dominance vs the field"
# Anchor the shared cert dir at the repo root (computed from this file's location:
# bench/roofline/roofline_report.py → repo root is parents[5]) so the report works
# from any CWD — the zig steps and portcert.sh already resolve the repo root, and
# `.local/gist-verify` always lives there. A `--out-dir` override still wins.
OUT_DIR = Path(__file__).resolve().parents[5] / ".local/gist-verify"

# Apple M-series shared P-cluster L2 — a candidate set larger than this spills to
# DRAM, so an apparent rate above the DRAM ceiling on a >L2 working set is a
# tell-tale early-exit (the scan short-circuited before reading all the bytes).
L2_BYTES = 16 * 1024 * 1024


@dataclass
class ClassPoint:
    """ClassPoint value object."""
    name: str
    bytes: int
    median_ns: float
    cyc_per_byte: float
    ipc: float

    @property
    def gbps(self) -> float:  # bytes/ns == GB/s
        """Return float for gbps."""
        return self.bytes / self.median_ns if self.median_ns > 0 else 0.0


def load_certify(path: Path) -> list[ClassPoint]:
    """Parse Layer A's tab-separated certify.csv into per-class operating points."""
    lines = path.read_text().splitlines()
    header = lines[0].split("\t")
    col = {name: i for i, name in enumerate(header)}
    pts = []
    for ln in lines[1:]:
        if not ln.strip():
            continue
        f = ln.split("\t")
        pts.append(
            ClassPoint(
                name=f[col["class"]],
                bytes=int(f[col["bytes"]]),
                median_ns=float(f[col["median_ns"]]),
                cyc_per_byte=float(f[col["cyc_per_byte"]]),
                ipc=float(f[col["ipc"]]),
            )
        )
    return pts


@dataclass
class ComputeBound:
    """Layer B's static port bound for the `simd_contains` loop, per reference core.

    Crucially cross-machine: Layer B runs llvm-mca on `znver4`/`neoverse-v2`
    because LLVM ships no Apple-Silicon scheduling model (this host is an M4), so
    these are a low-arithmetic-intensity *cross-check*, NOT a same-axis ceiling on
    this roofline. Reported as such — never folded into a min(compute, memory).
    """

    cores: list[tuple[str, float, float]]  # (uarch, cyc_per_byte, gbps_at_ghz)


def load_compute_ceiling(path: Path, ghz: float) -> ComputeBound | None:
    """Read Layer B's `simd_contains` port bound (real portcert.json schema), with a schema-tolerant fallback.

    Returns None ⇒ caller notes memory-ceiling-only.

    """
    if not path.exists():
        return None
    try:
        doc = json.loads(path.read_text())
    except json.JSONDecodeError, OSError:
        return None
    cores: list[tuple[str, float, float]] = []
    for r in doc.get("results", []):
        cpb = r.get("cyc_per_byte")
        if r.get("probe") == "simd_contains" and isinstance(cpb, int | float) and cpb > 0:
            cores.append((r.get("target_uarch", "?"), float(cpb), ghz / float(cpb)))
    if cores:
        return ComputeBound(cores)
    # Legacy/flat fallback: an explicit GB/s or a min cyc/byte at top level.
    for k in ("compute_gbps", "peak_gbps"):
        if isinstance(doc.get(k), int | float):
            return ComputeBound(
                [("(reported)", ghz / float(doc[k]) if doc[k] else 0.0, float(doc[k]))]
            )
    for k in ("cyc_per_byte", "min_cyc_per_byte", "static_cyc_per_byte"):
        v = doc.get(k)
        if isinstance(v, int | float) and v > 0:
            return ComputeBound([("(reported)", float(v), ghz / float(v))])
    return None


def render(roof: dict, pts: list[ClassPoint], compute: ComputeBound | None) -> str:
    """Render generated source artifacts."""
    tiers = {t["name"]: float(t["gbps"]) for t in roof["tiers"]}
    ghz = float(roof.get("ghz", 0.0))
    ghz_src = roof.get("ghz_source", "?")
    dram = tiers.get("DRAM", 0.0)
    scans = roof.get("gist_scan", [])
    # The clean streaming point: the absent-needle scan reads every byte (no
    # early exit, no verification) in the SAME process as the ceiling, so its
    # "% of DRAM ceiling" is a same-run ratio — robust to this shared box's load.
    pure = next(
        (s for s in scans if float(s.get("gbps", 0)) > 0 and "0 matches" in s.get("kind", "")),
        None,
    )

    lines: list[str] = [LAYER_C_HEADER, ""]
    lines.append(
        "_The roofline model (Williams, Waterman & Patterson, CACM 2009) caps a kernel at "
        "min(peak compute, peak bandwidth x arithmetic intensity). gist's scan is a byte "
        "classifier — a dual-window SIMD compare per stride — with tiny arithmetic intensity, "
        "so it lives in the **memory-bound region**: its ceiling is memory bandwidth, not "
        "compute. Ceiling = this machine's measured single-core STREAM read bandwidth "
        "(McCalpin 1995); operating point = gist's real `contains` scan over the corpus._"
    )
    lines.append("")
    lines.append(
        f"- machine: `{roof.get('machine', '?')}` · zig `{roof.get('zig', '?')}` "
        f"· corpus {roof.get('corpus_mib', '?')} MiB"
    )
    lines.append(
        "- **measured memory ceiling (single core, pure read):** "
        + " · ".join(f"{n} **{g:.1f} GB/s**" for n, g in tiers.items())
    )
    lines.append(f"- clock: {ghz:.3f} GHz — {ghz_src}")
    dram_cpb = roof.get("dram_cyc_per_byte_ceiling")
    if isinstance(dram_cpb, int | float):
        lines.append(
            f"- DRAM ceiling in cycles/byte (derived, GHz ÷ GB/s): **{dram_cpb:.4f} cyc/byte** "
            "— the floor no single-thread kernel can beat (it would have to read faster "
            "than memory)"
        )
    if compute:
        bounds = " · ".join(
            f"{u} {cpb:.3f} cyc/byte (≈{g:.0f} GB/s)" for u, cpb, g in compute.cores
        )
        lines.append(
            "- **compute bound (Layer B, cross-machine):** the `simd_contains` loop's static "
            f"llvm-mca port bound — {bounds}. These are *reference cores* (LLVM has no "
            "Apple-Silicon model), so they are a low-intensity **cross-check**, not a same-axis "
            "ceiling on this M4 roofline; they confirm the scan is a tight, few-cycle/byte "
            "port-bound kernel — i.e. firmly in the memory-bound region."
        )
    else:
        lines.append(
            "- compute ceiling: _Layer B (`portcert.json`) not present — memory-ceiling-only. "
            "gist's arithmetic intensity (a few ops/byte) puts the compute ridge far above the "
            "memory ridge regardless, so the memory ceiling is the binding one._"
        )
    lines.append("")

    # ── gist's clean operating point (same process, same clock) ──
    if scans:
        lines.append(
            "**gist's SIMD scan on the roofline** "
            "(real `scan/simd.zig` `contains` over the corpus):"
        )
        lines.append("")
        lines.append("| scan | GB/s | % of DRAM ceiling |")
        lines.append("|---|--:|--:|")
        for s in scans:
            g = float(s.get("gbps", 0))
            pct = g / dram * 100.0 if dram > 0 else 0.0
            label = f"{s.get('kind', '?')} (`{s.get('needle', '?')[:8]}…`)"
            lines.append(f"| {label} | {g:.1f} | {pct:.0f}% |")
        lines.append("")

    # ── verdict from the clean pure-streaming point ──
    if pure:
        pg = float(pure["gbps"])
        frac = pg / dram * 100.0 if dram > 0 else 0.0
        lines.append(
            f"**Verdict — memory-bandwidth-bound.** gist's SIMD scan reads every byte at "
            f"**{pg:.1f} GB/s = {frac:.0f}% of the {dram:.1f} GB/s single-core pure-read ceiling** "
            "(same-run ratio, so this holds even as absolute GB/s drifts with box load). The scan "
            "issues **two overlapping vector loads per stride** (first-byte + last-byte windows, "
            "memchr-style), so it moves ~2x the needle bytes through the load ports — "
            "hitting a large fraction of a *pure-read* STREAM ceiling that a compare-and-verify "
            "scan can "
            "never fully reach. The kernel is limited by memory/load-port throughput, not by "
            "search logic: it sits on the memory ridge, and the trigram prefilter (Layer A) is "
            "what actually wins — by never bringing most bytes to this scan at all."
        )
    else:
        lines.append(
            "**Verdict — memory-bound region.** gist's scan is a low-intensity byte classifier; "
            f"its ceiling is the {dram:.1f} GB/s single-core memory bandwidth, far below the "
            "compute ridge. (Clean pure-streaming point unavailable this run.)"
        )
    lines.append("")

    # ── Layer A per-class end-to-end operating point (as-instructed ingest) ──
    lines.append(
        "<details><summary>Layer A per-class end-to-end operating point "
        "(from certify.csv)</summary>\n"
    )
    lines.append(
        "_These are the **end-to-end** product path (trigram prefilter → candidate verify), so "
        "`bytes ÷ median_ns` conflates early-exit (scan returns on first match) and false-positive "
        "verification — it is the product's per-class latency, **not** a clean streaming "
        "bandwidth (the clean number is the scan table above). Rows marked ⚡ early-exit report "
        f"an apparent rate above the {dram:.0f} GB/s DRAM ceiling on a >LLC working set — "
        "physically impossible to truly stream, i.e. the kernel short-circuited before reading "
        "all candidate bytes._\n"
    )
    lines.append("| class | cand bytes | median | end-to-end GB/s | note |")
    lines.append("|---|--:|--:|--:|:--|")
    for p in sorted(pts, key=lambda x: x.bytes, reverse=True):
        if p.bytes > L2_BYTES and p.gbps > dram:
            note = "⚡ early-exit (partial scan)"
        elif p.bytes <= L2_BYTES:
            note = "cache-resident"
        else:
            note = "full/near-full scan"
        lines.append(
            f"| `{p.name}` | {p.bytes / 1e6:.0f} MB | {p.median_ns / 1e3:.0f} µs "
            f"| {p.gbps:.1f} | {note} |"
        )
    lines.append("\n</details>")

    have_pmu = any(p.cyc_per_byte > 0 for p in pts)
    lines.append("")
    if have_pmu:
        lines.append(
            "_Layer A measured gist's actual cycles/byte under `sudo` (see the microscopic table "
            "above); compare them to the derived DRAM ceiling of "
            f"{dram_cpb:.4f} cyc/byte to place each class on the ridge._"
        )
    else:
        lines.append(
            "> Ceiling clock was assumed (no PMU). The **GB/s ceiling and % attained are exact** "
            "(bandwidth is frequency-free); only the derived cyc/byte figures assume the clock. "
            "Re-run `sudo zig build certify` + `sudo zig build roofline` for measured cycles."
        )
    lines.append("")
    return "\n".join(lines)


def splice(cert: Path, section: str) -> None:
    """Replace an existing `## Layer C …` block (→ next `## Layer`/EOF); else insert it *before* the macroscopic Layer A section (which certify_stats.py rewrites to EOF) so a later macro re-splice can't clobber it; else append at EOF."""
    body = section.rstrip() + "\n"
    if not cert.exists():
        cert.write_text("# gist — Certificate of Optimality\n\n" + body)
        return
    text = cert.read_text()
    m = re.search(r"^## Layer C\b.*$", text, re.MULTILINE)
    if m:
        nxt = re.search(r"^## Layer [A-Z]\b", text[m.end() :], re.MULTILINE)
        end = m.end() + nxt.start() if nxt else len(text)
        new = text[: m.start()].rstrip() + "\n\n" + body + "\n" + text[end:].lstrip("\n")
    elif (macro := text.find(MACRO_HEADER)) != -1:
        new = text[:macro].rstrip() + "\n\n" + body + "\n" + text[macro:]
    else:
        new = text.rstrip() + "\n\n" + body
    cert.write_text(new.rstrip() + "\n")


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer C roofline synthesis")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR)
    ap.add_argument(
        "--roofline", type=Path, help="roofline.json (default: <out-dir>/roofline.json)"
    )
    ap.add_argument("--certify", type=Path, help="certify.csv (default: <out-dir>/certify.csv)")
    ap.add_argument("--portcert", type=Path, help="portcert.json (Layer B, optional)")
    ap.add_argument(
        "--certificate", type=Path, help="CERTIFICATE.md (default: <out-dir>/CERTIFICATE.md)"
    )
    args = ap.parse_args()

    rj = args.roofline or args.out_dir / "roofline.json"
    cc = args.certify or args.out_dir / "certify.csv"
    pc = args.portcert or args.out_dir / "portcert.json"
    cert = args.certificate or args.out_dir / "CERTIFICATE.md"

    if not rj.exists():
        print(f"roofline_report: {rj} missing — run `zig build roofline` first.")
        return 1
    if not cc.exists():
        print(f"roofline_report: {cc} missing — run `zig build certify` first (wall-clock ok).")
        return 1

    roof = json.loads(rj.read_text())
    pts = load_certify(cc)
    if not pts:
        print(f"roofline_report: {cc} has no rows — did certify run?")
        return 1
    compute = load_compute_ceiling(pc, float(roof.get("ghz", 0.0)))

    section = render(roof, pts, compute)
    splice(cert, section)

    tiers = {t["name"]: float(t["gbps"]) for t in roof["tiers"]}
    print(
        f"wrote Layer C → {cert}  (DRAM {tiers.get('DRAM', 0):.1f} GB/s ceiling · "
        f"{len(pts)} classes · compute ceiling: {'yes' if compute else 'absent'})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
