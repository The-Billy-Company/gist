<!--
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/bench/session/session_baseline.json
      contains: ["armed_geomean_floor"]
    - file: pkg/kernels/irregex/bench/session/gate_session.py
      contains: ["--committed", "--live", "report-only"]
-->

# bench/session

The **resident-session** certificate — the honest warm-product half of gist's
performance story (ADR-352 rung 2.5). It is the third leg of a triangle:

| Harness                                            | Path measured                                                  | The number it earns                                        |
| -------------------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------- |
| [`../certify/`](../certify/README.md)              | cold fresh-process query vs the field                          | gist is at parity-or-faster than `rg` on every regex class |
| [`../races/headtohead.sh`](../races/headtohead.sh) | gist's **in-process** engine                                   | the microsecond ceiling (no transport, no spawn)           |
| **`bench/session/`**                               | **persistent client → `gist serve` daemon over a Unix socket** | the number a long-lived client actually sees               |

The cold certificate re-pays process + index-mmap + candidate-read startup on
**every** query; that startup is exactly what made the old "thousands× faster"
claim unreproducible from a fresh-process race. The resident daemon amortizes it:
dial once, replay the slate over one warm connection. This harness measures that
path — the only honest basis for a warm-speedup claim — and gates it fail-closed.

## What it proves (and what it refuses to overstate)

- **Latency.** `session.csv` (emitted by `zig build bench -- session`) holds the
  warm p50 per needle over the persistent connection; `certify_session.sh` pairs
  each with a ripgrep-cold timing and reports the geomean speedup.
- **Two emit lanes.** The harness replays the same slate in both `-l`
  files-with-matches (the gated headline) and `-c` count mode (`session_count.csv`).
  `-l` short-circuits at the first hit per candidate; `-c` scans every candidate
  whole and tallies — the harder proof the resident-index win holds when per-file
  work rises. The count lane is **reported, not gated** (absolute count latency is
  box-specific); its `d_count`/`rg_count` carry the same not-like-for-like caveat
  as `d_files`/`rg_files`, so its **speedup** is the claim, not count equality.
- **Two honest caveats, printed not hidden:**
  1. gist's matched-file set is a systematic **subset** of `rg`'s (a corpus-walker
     difference owned by the _cold_ certificate); the daemon tracks the _cold gist_
     set, not `rg`'s. Both counts (`d_files`, `rg_files`) sit in the table so the
     speedup is never mistaken for like-for-like. Exact warm==cold==oracle parity
     is gated **hermetically** by the Zig suite (`serve_test`, `resident_test`,
     [`freshness_test`](../../src/surface/exec/session/freshness_test.zig)) — not by a live-tree
     count race.
  2. The microsecond fast path is armed only where a filesystem watcher proves
     quiescence (**Linux inotify** and **macOS FSEvents** today; every other
     target reconciles each query and pays the _freshness tax_). The certificate
     labels whatever the platform delivers, and the gate enforces the floor
     **only on the armed path**.

Even unarmed, the resident path wins: the committed macOS certificate — captured
before the FSEvents backend landed — measures a **7.2× geomean** over `rg` cold,
because `rg` re-walks and re-scans the whole monorepo (~350 ms) every call while
the daemon pays only the reconcile walk (~45 ms) plus an in-RAM index query. Now
that macOS arms via FSEvents (as Linux does via inotify) the reconcile vanishes
on a quiescent tree and the number approaches the in-process ceiling; re-run
`certify_session.sh` to republish the armed figure.

## Files

| File                    | Role                                                                                                              |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `certify_session.sh`    | build → run the daemon slate → time `rg` cold → write the certificate + `session_macro.csv` + `session_meta.json` |
| `gate_session.py`       | fail-closed latency gate: committed floor (armed only) + opt-in `--live` remeasure                                |
| `session_baseline.json` | `armed_geomean_floor` — the armed-path speedup floor (theorem-backed; see the file's comment)                     |
| `session_macro.csv`     | committed per-needle medians (`needle · d_files · rg_files · warm_ms · rg_ms · speedup`)                          |
| `session_count_macro.csv` | committed count-lane medians (`needle · d_count · rg_count · warm_ms · rg_ms · speedup`) — reported, not gated   |
| `session_meta.json`     | provenance the gate reads (`armed`, `watcher`, `platform`, `geomean_speedup`)                                     |

```bash
cd pkg/kernels/irregex
bench/session/certify_session.sh              # remeasure + republish (RUNS=8 WARMUP=2 default)
python3 bench/session/gate_session.py         # committed floor (hermetic)
GIST_BENCH=1 python3 bench/session/gate_session.py --live   # + live remeasure on this box
```
