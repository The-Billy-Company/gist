# gist/bench

Everything that measures or judges the **`gist` binary**. No engine code lives
here and no engine microbenchmark does either — those stay with the kernel in
the sibling `irregex` package, because what they time is code this repo does not
own. The dividing line is the subject: if a lane needs a compiled `gist` to run,
it lives here.

Sorted by what a folder _proves_, not by the mechanism it proves it about:

| Bucket                                    | What it holds                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`conformance/`](conformance/README.md)   | Fail-closed correctness — **no timing claim lives here**: `gates/` (parity · contract · oracle), `rgsuite/` the `rg` drop-in replay, `diag/` the stderr goldens, `shapes/` the CLI-shape admission matrix, `targets/` the cross-compile matrix. The Layer G retrieval contract is the sibling `relate` repo's, under `relate/bench/conformance/relate/`. |
| [`dominance/`](dominance/README.md)       | Measured product performance in the world: `races/` the competitor field (`field.sh`) + the multi-tool head-to-heads, `session/` the warm resident-daemon tier, `evaluate/` the operational envelope (lifecycle cost, footprint, scaling, concurrency), `partition/` the `--docs`/`--code`/`--data` lane, minted and gated.                        |
| [`certificate/`](certificate/README.md)   | The published Dominance-and-Fit claim: `mint/` the mint + layer splicers, `report/` `stats.py` + the layer report writers, `guard/` roster/artifact/release/ratio checks, `ledger/` the mint history, `artifact/` the **frozen** published receipts.                                                                                              |
| `rungs/`                                  | Per-mechanism proofs about the product rather than the engine — currently `warden/`, which prices what the resident memory ceiling costs.                                                                                                                                                                                                         |
| [`apparatus/`](apparatus/README.md)       | Not a claim: the `gist-bench` binary the timed lanes drive (`harness/`), the corpus the races run over (`corpora/`), and the sibling resolver every gate sources (`roots.sh`).                                                                                                                                                                    |

## Running the measured lanes

```bash
zig build lab                                   # gist-bench + warden → zig-out/bin
zig build -Doptimize=ReleaseFast bench          # corpus build cost + the query slate
zig build -Doptimize=ReleaseFast verify         # match sets for the rg equality oracle
zig build -Doptimize=ReleaseFast session        # the warm persistent-client → daemon path
zig build certify                               # Layer A (add sudo for real cycles)
zig build flagbench                             # what -i / -n / -v each cost
zig build sessionprof                           # the warm-session seams, in-process
zig build warden                                # what the resident memory ceiling costs
```

## Running the correctness slate

```bash
cd bench/conformance/gates/parity
bash line_parity.sh          # line-output shape ≡ rg, both engines
bash unicode_parity.sh       # fold, classes, boundaries, the (?-u) opt-out
bash index_elision_parity.sh # the index changes speed, never results
bash phantom_walk_parity.sh  # the snapshot changes syscalls, never results
bash partition_parity.sh     # --docs/--code/--data are total and disjoint
bash type_union_parity.sh    # every -t on the line reaches the answer
bash patterns_corpus_parity.sh  # relate patterns ≡ the gist -l population
```

Each gate resolves its own binaries through `apparatus/roots.sh` and builds
what it needs, so none of them assume a prior `zig build`. `patterns_corpus_parity.sh`
builds the sibling `relate` too, since it oracles one product against the other.
It is also the one gate whose corpus is an input rather than a fixture it makes,
so a bare run fails by design; `bench/apparatus/corpora/fetch.sh torture`
generates a tree that satisfies it offline:

```bash
GIST_CORPUS_ROOT="$PWD/.local/gist-corpora/torture" GIST_PARITY_SLATE=torture \
  bench/conformance/gates/parity/patterns_corpus_parity.sh
```

## Where the engine's own numbers live

`irregex/bench/` keeps the three buckets whose subject is the kernel:
`rungs/` (per-mechanism production proofs — crest, sieve, shuffle, parabix,
multipattern, sliver, price, census, patternid, automata, sweep), `bounds/`
(distance from a stated limit — the µarch port bound, the memory roofline, the
information-theoretic candidate-byte floor), and `apparatus/harness/`, which
after the split holds only the three shared instruments: the 12-class probe
registry, the PMU counters, and the bootstrap/Mann-Whitney verdict math. This
repo's `gist-bench` imports all three as Zig modules through the `irregex`
dependency, so a competitor race here and an engine rung there map 1:1 by class
name and are judged by the same statistics.

The binary itself is on this side of the line for a reason that is structural
rather than editorial: its `session` mode spawns a live `gist serve` daemon, and
`gist` depends on `irregex` — never the reverse — so the harness cannot sit
beside the engine it also times.
