# bench/roofline — Layer C (hardware ceiling)

Layer C of gist's [Certificate of Optimality](../README.md#certificate-of-optimality-layer-a).
Where Layer A proves gist is _empirically fastest in its class_ and Layer B
that its hot loop matches the static instruction-level bound, Layer C proves
the last hardware claim: gist's cycles/byte sit on _this machine's_ memory
bandwidth ceiling, so **no implementation on this chip can go materially
faster** — the bottleneck is memory, not gist's instruction stream.

## What it is

| File                 | Role                                                                                                                                                                                                           |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bandwidth.zig`      | a STREAM-style single-thread read-bandwidth microbenchmark at three working-set tiers (L1/L2/DRAM), plus gist's real SIMD scan over the corpus on the same roofline                                            |
| `roofline_report.py` | reads `roofline.json` + Layer A's `certify.csv` (optionally Layer B's `portcert.json` for the compute ceiling), renders the `## Layer C` markdown section, splices it into `.local/gist-verify/CERTIFICATE.md` |

gist's verify path is a byte classifier / streaming scan with tiny arithmetic
intensity (a handful of ops per byte), so the roofline model pins it to the
**memory-bandwidth ceiling**, not the compute ceiling — `roofline_report.py`
shows the measured operating point sitting on it.

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
the clean, directly-comparable streaming operating point — plus two present
needles for context (early-exit + verify, not a clean bandwidth number).

Frequency (only needed for the _derived_ cycles/byte ceiling) is measured via
the same `kperf` PMU [`../harness/pmu.zig`](../harness/pmu.zig) uses when run
under `sudo`; without it the run falls back to a clearly-labeled assumed
clock — the primary **GB/s ceiling itself is frequency-free** and always
exact.

## How to run

```bash
cd pkg/kernels/gist
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
