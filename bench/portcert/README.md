# bench/portcert — Layer B (port-optimality, static)

Layer B of gist's [Certificate of Optimality](../README.md#certificate-of-optimality-layer-a).
Where Layer A proves gist is *empirically fastest in its class*, Layer B
proves *why the hot loop can't be beaten on this instruction sequence*: it
asks `llvm-mca` for the static microarchitectural bound (port pressure /
reciprocal throughput) of gist's two hot loops and checks Layer A's measured
cycles/byte against it.

## What it is

| File                          | Role                                                                                          |
| ------------------------------ | ----------------------------------------------------------------------------------------------- |
| `portcert.sh`                 | cross-compiles the two probes to two reference microarchitectures, runs `llvm-mca`, writes `portcert.csv`/`portcert.json`, splices the certificate |
| `portcert_report.py`          | renders the `## Layer B` markdown section from `portcert.json` and splices it into `.local/gist-verify/CERTIFICATE.md` |
| `probes/simd_contains.zig`    | byte-faithful copy of the hot loop in [`../../src/scan/simd.zig`](../../src/scan/simd.zig)'s `contains` — throughput-bound |
| `probes/dfa_step.zig`         | byte-faithful copy of the hot loop in [`../../src/regex/dfa.zig`](../../src/regex/dfa.zig)'s `docMatch` — latency-bound |
| `probes_test.zig`             | the drift guard — asserts each probe is bit-identical to the real production function it copies, over adversarial random inputs (`zig build test`) |

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

## How to run

```bash
cd pkg/kernels/gist
bench/portcert/portcert.sh              # writes portcert.csv/.json, splices Layer B
ITERS=200 bench/portcert/portcert.sh    # more llvm-mca simulation iterations
```

Install `llvm-mca` opt-in with `brew install llvm` (lands at
`$(brew --prefix llvm)/bin/llvm-mca`). Missing `llvm-mca` or `zig` degrades to
a documented skip (exit 0), never a failure — mirroring `bench/harness/pmu.zig`'s
"never fail the run" discipline.

## Prior art

- **LLVM `llvm-mca`** — the static machine-code analyzer this layer drives;
  see the [LLVM `llvm-mca` documentation](https://llvm.org/docs/CommandGuide/llvm-mca.html)
  for the reciprocal-throughput / port-pressure model it implements.
- **[LLVM issue #63698](https://github.com/llvm/llvm-project/issues/63698)**
  — the reason this layer targets `znver4`/`neoverse-v2` instead of an
  Apple-Silicon `-mcpu`: no real scheduling model exists for any Apple core.
- gist's own [`../harness/certify.zig`](../harness/certify.zig) (Layer A) —
  the measured cycles/byte this layer's static bound is checked against.
