# bench/gates

Permanent, fail-closed correctness and contract gates — each exits non-zero on
any violation, so a regression can't ship silently. `scan_regress.sh` and
`streams.sh` source the shared field registry at
[`../races/_compete.sh`](../races/_compete.sh); `equality.sh` is a pure
two-way oracle (gist vs `rg`) and needs no field registry.

| File                | Gate                                                                                                                                                                                                |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `equality.sh`       | **correctness (INDEX path)**: gist ≡ `rg` over a byte-exact corpus snapshot — the soundness oracle                                                                                                 |
| `scan_regress.sh`   | **correctness (SCAN path) + race**: the no-prefilter live-tree scan ≡ `rg` (exits 1 on FN/FP) + min-of-N vs `rg` + the straggler-balance canary                                                    |
| `streams.sh`        | **output contract**: results→stdout, diagnostics (`—` summary / `[pipeline]` / guidance)→stderr across the literal, rank, and scan paths — the `rg`-conventional split that makes gist composable |

## `equality.sh` — the INDEX-path soundness oracle

Builds the gist index, has it emit (per needle) its verified matching-file set
**plus a byte-exact snapshot of the files it indexed** (the corpus is
regenerated live by coworker agents — the snapshot freezes the bytes so the
diff can't race), then runs `rg` over that identical snapshot and diffs:

- a file in `rg`'s set but not gist's ⇒ a trigram-filter **false negative**
  (the one unforgivable bug — a candidate filter may never drop a true match);
- a file in gist's set but not `rg`'s ⇒ an **unsound verify** (a false
  positive leaking past the exact-substring check).

Both must be zero.

```bash
cd pkg/kernels/gist
bench/gates/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus snapshot, per needle
```

## `scan_regress.sh` — the SCAN-path companion oracle

`equality.sh` proves the **INDEX** path. A regex the trigram index can't
prefilter at all (`\w{3,8}`, `[a-f0-9]{2,}`, `panic|0x`, …) skips the index and
scans the live tree directly ([`src/scan/sweep.zig`](../../src/scan/sweep.zig)),
so `equality.sh`'s proof doesn't cover it — this script is the **SCAN**-path
oracle:

1. **soundness** — asserts each pattern still **routes** to the scan path
   (`ROUTING FAIL` ⇒ exit 1 — the test's premise is void if dispatch silently
   changed), then diffs gist's scan match-set against `rg (?-u)` over the
   identical corpus and **exits 1 on any FN/FP** (a file `rg` matches past the
   4 MiB `per_file_cap` is a documented cap-skip, not a failure);
2. **race** — min-of-N vs `rg` while printing `sweep.zig`'s worker-span Δ, the
   **straggler canary** that catches any regression of the fused
   work-stealing pipeline back toward an unbalanced scan.

Built ReleaseFast (release-vs-release with `rg`).

```bash
cd pkg/kernels/gist
bench/gates/scan_regress.sh         # gate + race, default runs=12
bench/gates/scan_regress.sh 20      # tighter timing
```

## `streams.sh` — the stdout/stderr output contract

gist brands itself an *agent-friendly* code locator: an agent in a shell does
`gist search foo --show files > files` and `gist search foo | head`. This
script reproduces the pre-fix bug (results leaking onto stderr, or diagnostics
mixed into stdout) as a falsifiable assertion so it can never regress — each
path is checked for (a) results present on stdout and (b) no diagnostic
leaking onto stdout.

```bash
cd pkg/kernels/gist
bench/gates/streams.sh
```
