---
doc_radar:
  sentinels:
    - description: "the Layer B′ measured runner is wired as a build step + installed exe"
      file: pkg/kernels/irregex/build.zig
      contains: ['b.step("portbound"', '.name = "gist-portbound"']
    - description: "portcert.sh splices the measured subsection and names the sudo rung"
      file: pkg/kernels/irregex/bench/portcert/portcert.sh
      contains: ["portbound.json", "sudo pkg/kernels/irregex/zig-out/bin/gist-portbound"]
    - description: "the splicer fail-closed labels cycles when not measured here"
      file: pkg/kernels/irregex/bench/portcert/portcert_report.py
      contains: "NOT measured on this "
---

# bench/portcert — Layer B (port-optimality: static bound + measured on this machine)

Layer B of gist's [Dominance-and-Fit Certificate](../README.md#dominance-and-fit-certificate-layers-ag).
Where Layer A proves empirical dominance over ripgrep on the registered
workloads, Layer B proves _why the hot loop can't be beaten on this instruction sequence_ — in
two legs: a **static** `llvm-mca` microarchitectural bound (port pressure /
reciprocal throughput) over reference cores, and **Layer B′**, the same two
hot-loop probes run natively on _this_ machine under the PMU, so the
certificate can carry a measured-here cycles/byte instead of only a
cross-machine cross-check.

## What it is

| File                       | Role                                                                                                                                                                                                     |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `portcert.sh`              | cross-compiles the two probes to two reference microarchitectures, runs `llvm-mca`, writes `portcert.csv`/`portcert.json`, splices the certificate                                                       |
| `portcert_report.py`       | renders the `## Layer B` markdown section (static + the Layer B′ measured subsection) from `portcert.json` + `portbound.json` and splices it into `.local/gist-verify/CERTIFICATE.md`                    |
| `portbound.zig`            | **Layer B′** — `gist-portbound`: times the same drift-guarded probes natively under the PMU (`bench/harness/pmu.zig`), writing `portbound.json` (measured cyc/byte + cyc/step; fail-closed without root) |
| `probes/simd_contains.zig` | byte-faithful copy of the hot loop in [`../../src/kernel/scan/simd.zig`](../../src/kernel/scan/simd.zig)'s `contains` — throughput-bound                                                     |
| `probes/dfa_step.zig`      | byte-faithful copy of the hot loop in [`../../src/kernel/regex/linear/dfa/dfa.zig`](../../src/kernel/regex/linear/dfa/dfa.zig)'s `docMatch` — latency-bound                                  |
| `probes_test.zig`          | the drift guard — asserts each probe is bit-identical to the real production function it copies, over adversarial random inputs (`zig build test`)                                                       |

**Why cross-compiled reference cores, not this machine.** This dev box is
Apple Silicon, and LLVM ships **no real scheduling model for any Apple CPU** —
every core from the A7 to the M4 is modeled as the 2013 "Cyclone"
([LLVM issue #63698](https://github.com/llvm/llvm-project/issues/63698)). So
`llvm-mca -mcpu=apple-m4` would be fabricated precision. Layer B instead
bounds against two cores LLVM **does** model precisely, cross-compiled by Zig
with zero fuss: `znver4` (AMD Zen 4) and `neoverse-v2` (Arm Neoverse V2 — the
core behind AWS Graviton4 / Google Axion).

**Throughput-bound vs latency-bound.** `simd_contains`'s iterations are
independent (only the loop counter carries), so its `Block RThroughput` **is**
the real floor — no scheduling of those vector ops on that core runs faster.
`dfa_step` is a **latency-bound pointer chase**: the transition
`s = trans_in[s + class[b]]` is a loop-carried dependency, so its true floor is
the recurrence latency (the dependent-load chain), which `llvm-mca` reports as
higher than the port-pressure `Block RThroughput` shown in the table — the
certificate names this explicitly rather than quoting the more flattering
throughput number as if it were the DFA's real ceiling.

## Drift guard, not a duplicate

The probes are **byte-faithful copies**, not the production functions
themselves — `llvm-mca` needs a standalone, zero-Billy-dependency object to
disassemble, and the markers that bracket the measured region (`# LLVM-MCA-
BEGIN/END`) have to live inside the loop body so LLVM's loop rotation/cloning
can't strand them, which the production code has no reason to carry.
`probes_test.zig` is what keeps a copy honest: it feeds identical inputs to
**both** the probe and the real `gist.simd.contains` / `Dfa.docMatch` and
asserts bit-identical verdicts over thousands of adversarial random cases —
deliberately not an oracle test (the reference is the real production path,
not a re-derivation), so a silent divergence between the probe and the
production loop fails `zig build test` loudly instead of shipping a stale
certificate.

## Layer B′ — port bound, measured on this machine (the sudo rung)

The static leg is honest about its gap: it bounds _reference_ cores because
LLVM models no Apple core (below). `portbound.zig` closes the gap empirically —
it runs the **same drift-guarded probe functions** as timed kernels on this
machine, over cache-resident, guaranteed-miss inputs (the steady-state hot
loop; ports bind, memory never does), and reports:

- `simd_contains` — measured **cycles/byte** (throughput probe), with the
  unmarked production `simd.contains` timed alongside as a marker-overhead
  cross-check (the probe figure is a conservative upper bound);
- `dfa_step` — measured **cycles/step** of the transition recurrence
  `s = trans_in[s + class[b]]` (latency probe, 1 byte per step).

Provenance is stamped in `portbound.json` and the spliced section: CPU brand
(`machdep.cpu.brand_string`), the P-core note (USER_INTERACTIVE QoS request
plus the _measured_ effective GHz, which itself tells a P-core from an
E-core), and the PMU source. **Fail-closed:** without root the PMU is
unavailable (xnu gates `kpc`), so the run records wall-clock ns only and the
certificate says _"cycles/byte: cross-checked (reference cores), NOT measured
on this machine"_ — it never converts wall-clock to cycles via an assumed
frequency.

## How to run

```bash
cd pkg/kernels/irregex
bench/portcert/portcert.sh              # static leg: portcert.csv/.json + splice Layer B (+B′ if present)
ITERS=200 bench/portcert/portcert.sh    # more llvm-mca simulation iterations

# Layer B′ — measured on this machine:
zig build -Doptimize=ReleaseFast portbound         # wall-clock only (labels cycles NOT measured)
cd ../../..                                        # the binary resolves .local/ at the CWD — run from repo root
sudo pkg/kernels/irregex/zig-out/bin/gist-portbound  # measured cycles (kpc is root-gated)
pkg/kernels/irregex/bench/portcert/portcert.sh       # re-splice: the measured subsection lands in the cert
```

`CERT_OUT=/path/to/bundle` targets an isolated certificate directory; otherwise
the script uses the repo's `.local/gist-verify/`.

Install `llvm-mca` opt-in with `brew install llvm` (lands at
`$(brew --prefix llvm)/bin/llvm-mca`). Missing `llvm-mca` or `zig` degrades to
a documented skip (exit 0), never a failure — mirroring `bench/harness/pmu.zig`'s
"never fail the run" discipline; `gist-portbound` degrades the same way
(wall-clock + a loud NOT-measured label instead of a crash).

## Prior art

- **LLVM `llvm-mca`** — the static machine-code analyzer this layer drives;
  see the [LLVM `llvm-mca` documentation](https://llvm.org/docs/CommandGuide/llvm-mca.html)
  for the reciprocal-throughput / port-pressure model it implements.
- **[LLVM issue #63698](https://github.com/llvm/llvm-project/issues/63698)**
  — the reason this layer targets `znver4`/`neoverse-v2` instead of an
  Apple-Silicon `-mcpu`: no real scheduling model exists for any Apple core.
- gist's own [`../harness/certify.zig`](../harness/certify.zig) (Layer A) —
  the measured cycles/byte this layer's static bound is checked against.
