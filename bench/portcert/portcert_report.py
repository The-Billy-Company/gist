#!/usr/bin/env python3
"""gist portcert — Layer B certificate splicer (static port-optimality bound).

Reads the `portcert.json` emitted by `portcert.sh` (per probe x reference
microarchitecture: Block RThroughput, bytes/iter, cycles/byte) and renders a
`## Layer B — port-optimality (static µarch bound)` markdown section, then
splices it into `.local/gist-verify/CERTIFICATE.md`.

The section also carries **Layer B′ — the port bound measured on this
machine**: if a sibling `portbound.json` exists (written by
`zig build portbound` / `sudo zig-out/bin/gist-portbound`, which times the
same drift-guarded probes natively under the PMU), its measured cycles/byte +
cycles/step are rendered with full provenance (CPU brand, QoS, meter). This is
fail-closed: without that file — or when it says `"pmu": false` — the
certificate states plainly that cycles are cross-checked against reference
cores only, NOT measured here, and names the sudo rung that mints the measured
figure. Wall-clock is never converted to cycles via an assumed frequency.

Splice discipline (mirrors bench/certify/certify_stats.py): replace any existing
`## Layer B` section (from that heading to the next `## Layer` heading or EOF),
and insert a fresh one *before* the macroscopic Layer-A header so re-running
`certify.sh` (which rewrites from that header to EOF) never clobbers Layer B. If
CERTIFICATE.md doesn't exist yet, write a standalone section file and tell the
operator to run `zig build certify` first.

stdlib only. Idempotent.
"""

import argparse
import json
from pathlib import Path
import re


LAYER_B_HEADER = "## Layer B — port-optimality (static µarch bound)"
MACRO_HEADER = "## Layer A — macroscopic dominance over ripgrep"
LEGACY_MACRO_HEADER = "## Layer A — macroscopic dominance vs the field"
NEXT_LAYER = re.compile(r"^## Layer ", re.MULTILINE)

# The permanent, cited caveat: Apple Silicon has no real llvm-mca model.
APPLE_NOTE = (
    "> **Why not this machine (Apple Silicon).** LLVM ships **no real scheduling "
    "model for any Apple CPU** — every core from the A7 to the M4 is modeled as "
    "the 2013 *Cyclone* ([LLVM issue #63698]"
    "(https://github.com/llvm/llvm-project/issues/63698)). So `llvm-mca "
    "-mcpu=apple-m4` would be fabricated precision. Layer B is therefore a static "
    "bound over two cores LLVM **does** model precisely — AMD Zen 4 (`znver4`) and "
    "Arm Neoverse V2 (`neoverse-v2`, the core behind AWS Graviton4 / Google Axion) "
    "— cross-compiled by Zig, not a pretend M-series number."
)

BOUND_NOTE = (
    "> **Throughput-bound vs latency-bound.** `simd_contains` has independent "
    "iterations (only the cursor carries), so its `Block RThroughput` **is** the "
    "floor — no scheduling of those vector ops on that core runs faster. "
    "`dfa_step` is a **latency-bound pointer chase**: the transition "
    "`s = trans_in[s + class[b]]` is a loop-carried dependency, so its real floor "
    "is the recurrence latency (the dependent-load chain), which is *higher* than "
    "the port `Block RThroughput` shown here. For the DFA, `Block RThroughput` is "
    "the port-pressure ceiling; the binding constraint is the dependent-load "
    "latency llvm-mca reports per instruction. See `bench/portcert/README.md`."
)


MEASURED_HEADER = "### Layer B′ — port bound, measured on this machine"

# The rung an operator climbs to mint the measured-on-this-machine bound.
MEASURED_RUNG = (
    "`cd pkg/kernels/irregex && zig build -Doptimize=ReleaseFast portbound` "
    "(wall-clock), then from the repo root "
    "`sudo pkg/kernels/irregex/zig-out/bin/gist-portbound` for cycles (xnu gates "
    "the PMU to root), then re-run `bench/portcert/portcert.sh` to splice."
)


def render_measured(measured: dict | None) -> list[str]:
    """Render the Layer B′ subsection.

    Fail-closed when cycles were not measured on this machine (no
    portbound.json, or PMU unavailable).
    """
    lines = [MEASURED_HEADER, ""]
    if measured is None:
        lines.append(
            "**cycles/byte: cross-checked (reference cores), NOT measured on this "
            "machine.** The empirical runner has not been run here. Rung: " + MEASURED_RUNG
        )
        lines.append("")
        return lines

    brand = measured.get("cpu_brand", "?")
    qos = measured.get("qos", "?")
    meter = measured.get("meter", "?")
    results = measured.get("results", [])
    prov = (
        f"_Provenance: **{brand}** (`{measured.get('arch', '?')}`) · {qos} · "
        f"meter: {meter} · best-of-{measured.get('trials', '?')} trials · same "
        "drift-guarded probes as the static bound above (`probes_test.zig`)._"
    )

    if not measured.get("pmu", False):
        lines.append(
            "**cycles/byte: cross-checked (reference cores), NOT measured on this "
            "machine.** The runner executed here but the PMU was unavailable "
            "(kperf needs root), so only wall-clock ns are recorded below — never "
            "converted to cycles via an assumed frequency. Rerun under `sudo` for "
            "measured: " + MEASURED_RUNG
        )
        lines.append("")
        lines.append(prov)
        lines.append("")
        lines.append("| probe | bound | working set | wall ns/unit (aux only) |")
        lines.append("|---|---|--:|--:|")
        lines.extend(
            f"| `{r['probe']}` | {r['bound']} | {r['working_set_bytes'] >> 10} KiB "
            f"| {r['ns_per_unit']:.4f} ns/{r['unit']} |"
            for r in results
        )
        lines.append("")
        return lines

    lines.append(
        "**cycles: measured on this machine.** The same drift-guarded probes, "
        "run natively as timed kernels under the PMU on cache-resident working "
        "sets (ports bind, memory never does) — the on-machine empirical "
        "counterpart to the static reference-core bound above."
    )
    lines.append("")
    lines.append(prov)
    lines.append("")
    lines.append(
        "| probe | bound | working set | measured cyc/unit | IPC | eff GHz | wall ns/unit |"
    )
    lines.append("|---|---|--:|--:|--:|--:|--:|")
    lines.extend(
        f"| `{r['probe']}` | {r['bound']} | {r['working_set_bytes'] >> 10} KiB "
        f"| **{r['cyc_per_unit']:.4f} cyc/{r['unit']}** | {r['ipc']:.2f} "
        f"| {r['eff_ghz']:.2f} | {r['ns_per_unit']:.4f} |"
        for r in results
    )
    lines.append("")
    by_name = {r["probe"]: r for r in results}
    probe, prod = by_name.get("simd_contains"), by_name.get("simd_contains_production")
    if probe and prod and prod.get("cyc_per_unit", 0) > 0:
        ratio = probe["cyc_per_unit"] / prod["cyc_per_unit"]
        lines.append(
            "> **Marker-overhead cross-check.** The probe carries the `LLVM-MCA` "
            "region markers (assembly comments, zero instructions, but their "
            "operand constraints pin instruction scheduling); the unmarked "
            f"production `simd.contains` timed alongside runs {ratio:.2f}× "
            "cheaper per byte. The probe figure is therefore a **conservative "
            "(upper) bound** on the production loop's on-machine cost — the "
            "production row is the loop as shipped."
        )
        lines.append("")
    return lines


def render(doc: dict, measured: dict | None = None) -> str:
    """Render generated source artifacts."""
    ver = doc.get("llvm_mca_version", "?")
    results = doc.get("results", [])
    lines = [LAYER_B_HEADER, ""]
    lines.append(
        f"_Static reciprocal-throughput bound from `llvm-mca {ver}`, computed by "
        "`bench/portcert/portcert.sh`. gist's two hot loops are byte-faithful "
        "copies (drift-guarded by `probes_test.zig`), cross-compiled by Zig to each "
        "reference core; llvm-mca scores the marked hot-loop region for port "
        "pressure. Lower cycles/byte is better._"
    )
    lines.append("")
    if not results:
        lines.append(
            "_No results — `llvm-mca` was unavailable or every probe skipped. "
            "Install it with `brew install llvm` and re-run "
            "`bench/portcert/portcert.sh`._"
        )
        lines.append("")
        lines.append(APPLE_NOTE)
        lines.append("")
        lines.extend(render_measured(measured))
        return "\n".join(lines)

    lines.append(
        "| probe | source | target µarch | bound | Block RThroughput (cyc/iter) "
        "| bytes/iter | cyc/byte (port bound) |"
    )
    lines.append("|---|---|---|---|--:|--:|--:|")
    lines.extend(
        "| `{probe}` | `{source}` | `{uarch}` | {bound} | {rt} | {bpi} | {cpb} |".format(
            probe=r["probe"],
            source=r["source"],
            uarch=r["target_uarch"],
            bound=r["bound"],
            rt=r["block_rthroughput_cyc_iter"],
            bpi=r["bytes_per_iter"],
            cpb=r["cyc_per_byte"],
        )
        for r in results
    )
    lines.append("")
    lines.append(BOUND_NOTE)
    lines.append("")
    lines.append(APPLE_NOTE)
    lines.append("")
    lines.extend(render_measured(measured))
    return "\n".join(lines)


def splice(cert: Path, section: str) -> None:
    """Perform splice."""
    text = cert.read_text()

    # Drop any existing Layer B section (heading → next `## Layer` or EOF).
    start = text.find(LAYER_B_HEADER)
    if start != -1:
        after = text[start + len(LAYER_B_HEADER) :]
        m = NEXT_LAYER.search(after)
        end = start + len(LAYER_B_HEADER) + (m.start() if m else len(after))
        text = (text[:start].rstrip() + "\n\n" + text[end:].lstrip()).rstrip() + "\n"

    block = section.rstrip() + "\n"
    macro = next(
        (i for header in (MACRO_HEADER, LEGACY_MACRO_HEADER) if (i := text.find(header)) >= 0),
        -1,
    )
    if macro != -1:  # insert BEFORE the macroscopic header (survives its rewrite)
        new = text[:macro].rstrip() + "\n\n" + block + "\n" + text[macro:].lstrip()
    else:  # macroscopic half not run yet — append at EOF
        new = text.rstrip() + "\n\n" + block
    cert.write_text(new)


def main() -> int:
    """CLI entry point."""
    ap = argparse.ArgumentParser(description="gist Layer B port-optimality certificate splicer")
    ap.add_argument("--json", type=Path, required=True, help="portcert.json from portcert.sh")
    ap.add_argument("--certificate", type=Path, required=True, help="CERTIFICATE.md to splice into")
    args = ap.parse_args()

    if not args.json.exists():
        print(f"portcert_report: {args.json} not found — did portcert.sh run?")
        return 1
    doc = json.loads(args.json.read_text())

    # Layer B′ auto-discovery: a sibling portbound.json (from `gist-portbound`)
    # carries the measured-on-this-machine bound. Absent or unreadable ⇒ the
    # section fail-closed labels cycles as cross-checked-only.
    measured: dict | None = None
    portbound = args.json.parent / "portbound.json"
    if portbound.exists():
        try:
            measured = json.loads(portbound.read_text())
        except json.JSONDecodeError, OSError:
            measured = None
    section = render(doc, measured)

    if not args.certificate.exists():
        sidecar = args.certificate.parent / "portcert.section.md"
        sidecar.parent.mkdir(parents=True, exist_ok=True)
        sidecar.write_text(section.rstrip() + "\n")
        print(
            f"portcert_report: {args.certificate} not found — wrote standalone "
            f"section to {sidecar}.\n"
            "  Run `zig build certify` first to create CERTIFICATE.md, then re-run "
            "portcert.sh to splice Layer B in place."
        )
        return 0

    splice(args.certificate, section)
    print(f"portcert_report: spliced Layer B into {args.certificate}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
