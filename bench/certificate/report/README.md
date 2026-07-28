# bench/certificate/report

The **splicers** — one per certificate section. Each reads a lane's raw CSV/JSONL
and renders its fail-closed table into `CERTIFICATE.md`. They are flat siblings
on purpose: every `<x>.py` does `sys.path.insert(0, HERE)` then `from stats
import …`, so `stats.py` (the stdlib mirror of
[`../../apparatus/harness/stats.zig`](../../apparatus/harness/stats.zig) —
per-class bootstrap-CI median + Mann-Whitney) must stay beside them.

| File                                                                        | Section it splices                                                |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| `stats.py`                                                                  | the shared statistics kernel + the Layer-A cold macro table       |
| `warm.py`                                                                   | Layer A warm tier — daemon dominance over cold gist + rivals      |
| `rank.py`                                                                   | Layer A `--rank` lane                                             |
| `relate.py`                                                                 | Layer G relate boundary + recall\@1 + pack + short-recall         |
| `crest.py`                                                                  | Layer E crest-sieve prune/speedup                                 |
| `codex.py`                                                                  | Layer F codex decodability / sub-entropy space / self-recognition |
| `scale.py` · `scanner.py` · `multipattern.py` · `indexq.py` · `portable.py` | the remaining per-mechanism / portability side-car tables         |
| `test_crest.py`                                                             | unit test for the crest splicer                                   |

The 12 classes here are byte-identical to `probes.zig`, so the macroscopic table
maps 1:1 by class name to the microscopic one.
