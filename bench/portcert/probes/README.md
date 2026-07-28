---
doc_radar:
  sentinels:
    - description: "the drift guard exercises both probes against production kernels"
      file: pkg/kernels/irregex/bench/portcert/probes_test.zig
      contains: ['@import("probes/simd_contains.zig")', '@import("probes/dfa_step.zig")', "gist.simd.contains", "gist.regex.Regex"]
---

# bench/portcert/probes

Byte-faithful, standalone copies of gist's two hot loops — the objects
[`../portcert.sh`](../portcert.sh) cross-compiles and hands to `llvm-mca`.
Each copy takes raw pointers (not a `Dfa`/corpus type) so it links with zero
Billy dependencies, and brackets its measured region with `# LLVM-MCA-
BEGIN/END` marker comments **inside** the loop body (a marker straddling the
loop header gets stranded by LLVM's loop rotation/versioning).

| File                | Copies                                                                                                                                      | Bound kind                                 |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| `simd_contains.zig` | [`../../../src/kernel/scan/simd.zig`](../../../src/kernel/scan/simd.zig)'s `contains` vector filter                             | throughput-bound (independent iterations)  |
| `dfa_step.zig`      | [`../../../src/kernel/regex/linear/dfa/dfa.zig`](../../../src/kernel/regex/linear/dfa/dfa.zig)'s `Dfa.docMatch` transition loop | latency-bound (loop-carried pointer chase) |

Neither file is a source of truth — [`../probes_test.zig`](../probes_test.zig)
is what makes a copy trustworthy: it asserts each probe is bit-identical to
the real production function over adversarial random inputs, so a divergence
between a copy and its original fails `zig build test` instead of shipping a
silently stale port-optimality certificate.
