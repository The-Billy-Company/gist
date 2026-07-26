---
doc_radar:
  sentinels:
    - description: "the roofline reporter owns the generated Layer C section"
      file: pkg/kernels/irregex/bench/roofline/roofline_report.py
      contains:
        - 'LAYER_C_HEADER = "## Layer C — roofline (measured headroom)"'
        - "if frac >= 80.0:"
    - description: "adverse tests forbid sub-roof saturation claims"
      file: pkg/kernels/irregex/bench/roofline/test_roofline_report.py
      contains: ["test_sub_threshold_result_cannot_claim_saturation"]
---

# bench/roofline — Layer C (measured headroom)

Layer C of gist's [Dominance-and-Fit Certificate](../README.md#dominance-and-fit-certificate-layers-ag).
Where Layer A proves empirical dominance over ripgrep on the registered
workloads and Layer B bounds its hot loop against static instruction-level
pressure, Layer C tests the hardware claim: gist's cycles/byte sit against this machine's memory
bandwidth ceiling. It reports a near-roof result only at or above 80%;
anything below that is reported as optimization headroom, without inventing
a binding bottleneck.

## What it is

| File                      | Role                                                                                                                                                                                                           |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bandwidth.zig`           | a STREAM-style single-thread read-bandwidth microbenchmark at three working-set tiers (L1/L2/DRAM), a matched dual-window/contiguous-production ladder, and gist's real SIMD scan over the corpus              |
| `roofline_report.py`      | reads `roofline.json` + Layer A's `certify.csv` (optionally Layer B's `portcert.json` for the compute ceiling), renders the `## Layer C` markdown section, splices it into `.local/gist-verify/CERTIFICATE.md` |
| `test_roofline_report.py` | adverse tests that reject sub-roof saturation claims and keep legacy certificate refreshes honest                                                                                                              |

Low arithmetic intensity places a theoretical roof; it does not prove an
implementation has reached it. `roofline_report.py` therefore reports the
measured operating point, its distance from the roof, and the matched stages
that localize the gap.

## Method

`bandwidth.zig` sizes three buffers to land inside distinct levels of this
machine's cache hierarchy (16 KiB deep in L1, 3 MiB past L1 into L2, 512 MiB
past any cache into DRAM) and streams each with a vectorized, multi-
accumulator sum-reduction (independent accumulators hide load-use latency, so
the loop is bound by load-port/cache bandwidth, not the dependency chain) —
best-of-9 trials, since on this shared coworking box interference only ever
_slows_ a trial, never inflates it, so the max is the cleanest ceiling
estimate. It then times gist's real `scan/simd.zig` `contains` over the full
corpus with an absent needle (a full scan, no early exit, no verification) —
the clean corpus operating point — plus two present needles for context
(early-exit + verify, not a clean bandwidth number).

Between STREAM and the corpus point, the harness runs two controls over the
same 512 MiB DRAM buffer:

1. a dual-window load/compare/mask loop matching the production hot-loop shape
   without verification or document dispatch;
2. production `simd.contains` over one contiguous buffer.

The first gap prices the search instruction/load shape; the second prices
production control flow; the corpus gap prices document fragmentation and
dispatch. This ladder makes Layer C diagnostic even when the scan is nowhere
near the hardware roof.

Frequency (only needed for the _derived_ cycles/byte ceiling) is measured via
the same `kperf` PMU [`../harness/pmu.zig`](../harness/pmu.zig) uses when run
under `sudo`; without it the run falls back to a clearly-labeled assumed
clock — the primary **GB/s measurement itself is frequency-free**.

## How to run

```bash
cd pkg/kernels/irregex
zig build roofline                      # → .local/gist-verify/roofline.json
bench/roofline/roofline_report.py       # splices Layer C into CERTIFICATE.md
sudo zig build roofline && bench/roofline/roofline_report.py   # measured clock
```

Run `zig build certify` (Layer A) first — `roofline_report.py` reads its
`certify.csv` for the per-class end-to-end operating points shown alongside
the ceiling. Never fails the run (mirrors `pmu.zig`'s discipline): no PMU ⇒
assumed clock + a loud note, not an error.

## Prior art

- **John D. McCalpin, "Memory Bandwidth and Machine Balance in Current High
  Performance Computers" (1995), _IEEE TCCA Newsletter_.** The STREAM
  benchmark methodology this layer's read-bandwidth sweep follows.
- **Samuel Williams, Andrew Waterman, David Patterson, "Roofline: An
  Insightful Visual Performance Model for Multicore Architectures" (2009),
  _Communications of the ACM_ 52(4):65-76.** The roofline model itself — a
  kernel's throughput is capped by `min(peak compute, peak bandwidth ×
arithmetic intensity)`; gist's low arithmetic intensity puts it on the
  memory ridge this layer measures.
- gist's own [`../harness/certify.zig`](../harness/certify.zig) (Layer A) —
  the per-class cycles/byte this layer's ceiling is checked against, and
  [`../portcert/`](../portcert/README.md) (Layer B) — the optional compute
  ceiling this layer's report reads for the two-ceiling picture.
