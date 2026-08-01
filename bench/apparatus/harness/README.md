---
doc_radar:
  sentinels:
    - description: "PMU state is a first-class, fail-closed certificate fact with host provenance"
      file: bench/apparatus/harness/certify.zig
      contains: ["NOT measured on this machine", "cpuBrand", "requestPerformanceQos"]
    - description: "the session lane drives the real daemon, not a stand-in"
      file: bench/apparatus/harness/bench.zig
      contains: ["product.session.serve", "product.session.protocol"]
---

# bench/apparatus/harness

The native **`gist-bench`** binary — one executable, six modes. It is separate
from the production `gist` CLI (`src/surface/face/gist/main.zig`) and links two
things at once: the engine, exactly the way any consumer links it, and this
package's own chassis, because one of its modes drives a live daemon.

| File              | Mode(s)                     | Role                                                                                                           |
| ----------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `bench.zig`       | `bench` · `verify` · `session` · `scanbench` | the entry point: corpus load/build cost and the latency slate, the match sets the `rg` equality oracle eats, and the warm persistent-client → daemon path |
| `certify.zig`     | `certify`                   | Layer A of the optimality certificate — per-class single-thread cycles/byte with a bootstrap CI                 |
| `flagbench.zig`   | `flagbench`                 | the one hot function each of `-i` / `-n` / `-v` adds, timed in isolation and self-checked byte-identical         |
| `sessionprof.zig` | `sessionprof`               | per-function micro-profiles for the warm-session seams, timed in-process so a refactor's effect is not drowned by the socket walk |

The three instruments these read — `probes`, `pmu`, `stats` — are **not** here.
They belong to the engine package and arrive as named modules through the
`irregex` dependency, so the 12 class names and the verdict math mean the same
thing in this repo's races as in that repo's rungs.

## Why the harness lives with the product

Its `session` mode spawns a real `gist serve` daemon on a thread, dials it over
a real Unix socket, and replays a slate over that one connection — the honest
product analogue of the in-process number, and the resident daemon's whole
reason to exist. That needs `gist.session.serve` and `gist.session.protocol`,
which only this package has. `gist` depends on `irregex`, never the reverse, so
the harness cannot sit beside the engine it also times.

## The modes

```bash
zig build lab                                   # build + install gist-bench → zig-out/bin

zig build -Doptimize=ReleaseFast bench          # default host source roots
zig build -Doptimize=ReleaseFast bench -- src   # scope to specific dirs
zig build -Doptimize=ReleaseFast verify         # feed the rg equality oracle
zig build -Doptimize=ReleaseFast session        # warm daemon path (files + count lanes)
zig build certify                               # Layer A, wall-clock fallback
sudo zig-out/bin/gist-bench certify             # Layer A with real cycles
```

**`bench`** loads a real corpus, builds the trigram index, and times the slate:
20 adversarial literals (rare symbol, dotted ident, 2-byte punctuation,
guaranteed miss, repeated-char pathological, cross-language keywords) plus 30
regex shapes spanning every feature tier. `-- scanbench` isolates the SIMD scan
primitive against `std.mem.indexOf`.

**`verify`** writes gist's verified matching-file set per needle plus the exact
indexed file list, and [`../../conformance/gates/parity/equality.sh`](../../conformance/gates/README.md)
drives `rg` over that identical file set and diffs — which is what proves the
trigram filter has zero false negatives.

**`session`** emits `session.csv` and `session_count.csv`, which
[`../../dominance/session/certify_session.sh`](../../dominance/session/README.md)
pairs against cold `rg` to mint the warm tier's numbers.

**`certify`** times the real verify kernel single-threaded over the RAM-resident
corpus for each of the 12 probe classes and records retired cycles and
instructions per byte, IPC, and a 95% bootstrap-CI median (200 reps, seeded).

PMU state is a **fail-closed certificate fact**. The emitted `CERTIFICATE.md`
stamps a provenance line from the host — CPU brand, the P-core note
(USER_INTERACTIVE QoS request), and the meter source. With the PMU it reads
_"cycles/byte: measured on this machine"_; without root, _"NOT measured on this
machine — cross-checked against Layer B's reference-core static bounds only"_,
plus the exact `sudo` rerun command. A blank cycles/byte column can never be
mistaken for measured-but-small, and wall-clock is never dressed up as cycles.
