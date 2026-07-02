#!/usr/bin/env python3
"""gist portcert — Layer B certificate splicer (static port-optimality bound).

Reads the `portcert.json` emitted by `portcert.sh` (per probe x reference
microarchitecture: Block RThroughput, bytes/iter, cycles/byte) and renders a
`## Layer B — port-optimality (static µarch bound)` markdown section, then
splices it into `.local/gist-verify/CERTIFICATE.md`.

Splice discipline (mirrors bench/certify/certify_stats.py): replace any existing
`## Layer B` section (from that heading to the next `## Layer` heading or EOF),
and insert a fresh one *before* the macroscopic Layer-A header so re-running
`certify.sh` (which rewrites from that header to EOF) never clobbers Layer B. If
CERTIFICATE.md doesn't exist yet, write a standalone section file and tell the
operator to run `zig build certify` first.

stdlib only. Idempotent.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


LAYER_B_HEADER = "## Layer B — port-optimality (static µarch bound)"
MACRO_HEADER = "## Layer A — macroscopic dominance vs the field"
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


def render(doc: dict) -> str:
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
        return "\n".join(lines)

    lines.append(
        "| probe | source | target µarch | bound | Block RThroughput (cyc/iter) "
        "| bytes/iter | cyc/byte (port bound) |"
    )
    lines.append("|---|---|---|---|--:|--:|--:|")
    for r in results:
        lines.append(
            "| `{probe}` | `{source}` | `{uarch}` | {bound} | {rt} | {bpi} | {cpb} |".format(
                probe=r["probe"],
                source=r["source"],
                uarch=r["target_uarch"],
                bound=r["bound"],
                rt=r["block_rthroughput_cyc_iter"],
                bpi=r["bytes_per_iter"],
                cpb=r["cyc_per_byte"],
            )
        )
    lines.append("")
    lines.append(BOUND_NOTE)
    lines.append("")
    lines.append(APPLE_NOTE)
    lines.append("")
    return "\n".join(lines)


def splice(cert: Path, section: str) -> None:
    text = cert.read_text()

    # Drop any existing Layer B section (heading → next `## Layer` or EOF).
    start = text.find(LAYER_B_HEADER)
    if start != -1:
        after = text[start + len(LAYER_B_HEADER) :]
        m = NEXT_LAYER.search(after)
        end = start + len(LAYER_B_HEADER) + (m.start() if m else len(after))
        text = (text[:start].rstrip() + "\n\n" + text[end:].lstrip()).rstrip() + "\n"

    block = section.rstrip() + "\n"
    macro = text.find(MACRO_HEADER)
    if macro != -1:  # insert BEFORE the macroscopic header (survives its rewrite)
        new = text[:macro].rstrip() + "\n\n" + block + "\n" + text[macro:].lstrip()
    else:  # macroscopic half not run yet — append at EOF
        new = text.rstrip() + "\n\n" + block
    cert.write_text(new)


def main() -> int:
    ap = argparse.ArgumentParser(description="gist Layer B port-optimality certificate splicer")
    ap.add_argument("--json", type=Path, required=True, help="portcert.json from portcert.sh")
    ap.add_argument("--certificate", type=Path, required=True, help="CERTIFICATE.md to splice into")
    args = ap.parse_args()

    if not args.json.exists():
        print(f"portcert_report: {args.json} not found — did portcert.sh run?")
        return 1
    doc = json.loads(args.json.read_text())
    section = render(doc)

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
