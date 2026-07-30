# bench/dominance

**Measured product performance in the world** — gist against the real
competitor field, and the operational envelope where those numbers hold. A
result here is always a _statistic_ (bootstrap-CI median + Mann-Whitney), never
a single mean.

| Folder                            | What                                                                                                                                                                                                                                                                 |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`races/`](races/README.md)       | the competitor field and the per-rival head-to-heads — `field.sh` defines the roster and the shared timing harness every other race sources; `cold.sh`, `warm.sh`, `regex.sh`, `pcre.sh`, `scanner.sh`, `searchzip.sh`, `relate.sh`, `multipattern.sh` are the lanes |
| [`session/`](session/README.md)   | the warm resident-daemon tier — where the "warm is Nx faster" claim is measured and gated                                                                                                                                                                            |
| [`partition/`](partition/README.md) | the corpus-partition lane — `--docs` against the `-t` union a human hand-assembles, the one question no rival tool has a flag for, gated on population as well as latency                                                                                          |
| [`evaluate/`](evaluate/README.md) | the operational envelope — which regimes the dominance claim is certified over, with its own freshness contract                                                                                                                                                      |

`races/field.sh` is the keystone: it derives `KERNEL`/`REPO`, builds the rival
roster, and exports the timing primitives, so gates in `conformance/` and lanes
in `certificate/mint/` source it rather than re-deriving the field.
