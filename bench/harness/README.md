---
doc_radar:
  sentinels:
    - description: "PMU state is a first-class, fail-closed certificate fact with host provenance"
      file: pkg/kernels/irregex/bench/harness/certify.zig
      contains: ["NOT measured on this machine", "cpuBrand", "requestPerformanceQos"]
    - description: "pmu.zig carries the provenance primitives the layers stamp"
      file: pkg/kernels/irregex/bench/harness/pmu.zig
      contains: ["pub fn cpuBrand", "pub fn requestPerformanceQos"]
---

# bench/harness

The native `gist-bench` Zig binary (`build.zig`'s `bench_exe`) — a separate
executable from the production `gist` CLI (`src/surface/face/gist/main.zig`),
dispatching three subcommands: `bench`, `verify`, and `certify`.

| File          | Role                                                                                                                                                                                |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bench.zig`   | the harness entry point — `bench` (corpus load/build cost/latency slate) and `verify` (emit match sets + corpus snapshot for `../gates/equality.sh`) subcommands                    |
| `certify.zig` | the `certify` subcommand — the microscopic half of the Layer-A optimality certificate                                                                                               |
| `pmu.zig`     | hardware performance counters via Apple's private `kperf` framework (`dlopen`/`std.DynLib`) — cycles + instructions retired                                                         |
| `stats.zig`   | bootstrap-CI + Tukey outlier rejection + Mann-Whitney significance — the statistics engine `certify.zig` (and `../certify/certify_stats.py`, its Python mirror) both report through |

`bench.zig` imports `certify.zig`, which imports `pmu.zig` + `stats.zig` — one
compilation unit, one executable (`zig-out/bin/gist-bench`).

## `bench` — corpus build + latency slate

Loads a real corpus (every code file under the given dirs), builds the T0
trigram `Index`, and times the query slate — reporting corpus size, one-time
build cost, index footprint, and per-query candidate count + median latency:
20 adversarial literals (rare symbol, dotted ident, 2-byte punctuation,
guaranteed miss, repeated-char pathological, cross-language keywords) + 30
regex shapes spanning every feature tier.

```bash
cd pkg/kernels/irregex
zig build -Doptimize=ReleaseFast bench                  # default Billy source roots
zig build -Doptimize=ReleaseFast bench -- services libs  # scope to specific dirs
```

## `verify` — the equality-oracle feeder

Builds the index, then for a fixed slate + `battery_n` random literals sampled
from the corpus, writes gist's verified matching-file set per needle into
`.local/gist-verify/` plus the exact indexed file list. The sibling
[`../gates/equality.sh`](../gates/README.md) drives `rg` over that identical
file set and diffs — proving the trigram filter has zero false negatives vs
`rg`.

## `certify` — the microscopic optimality certificate

For each of 12 regex classes (byte-identical to `../certify/certify.sh`'s
probes), times gist's real verify kernel **single-threaded** over the
RAM-resident corpus and records retired **cycles + instructions per byte**
(the bridge number Layers B–C of the certificate roadmap bound), `IPC`, and a
95% bootstrap-CI median (200 reps, seeded). Hardware counters come from
`pmu.zig`'s `kperf` binding — **run under `sudo` for cycles**; without root it
degrades to wall-clock and says so, never failing.

**PMU state is a first-class, fail-closed certificate fact.** The emitted
`CERTIFICATE.md` carries a provenance line stamped from the host — CPU brand
(`machdep.cpu.brand_string`), the P-core note (USER_INTERACTIVE QoS request),
and the meter source. With the PMU it reads _"cycles/byte: measured on this
machine"_; without it, _"NOT measured on this machine — cross-checked against
Layer B's reference-core static bounds only"_, plus the exact `sudo` rerun
command. Blank cyc/byte columns can never be mistaken for measured-but-small,
and wall-clock is never dressed up as cycles.

```bash
sudo pkg/kernels/irregex/zig-out/bin/gist-bench certify   # cycles/byte (run from repo root)
zig build certify                                        # wall-clock fallback (no sudo)
```

`stats.zig`'s bootstrap-CI + Mann-Whitney implementation is unit-tested under
`zig build test` (pulled in via `bench.zig`'s own `test` block, since the
engine tests under `src/` ride `src/root.zig` instead).
