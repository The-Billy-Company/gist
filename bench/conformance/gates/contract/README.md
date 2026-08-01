# bench/conformance/gates/contract

Fail-closed **behavioral-contract** gates — the invariants gist promises callers
that aren't a direct `rg` diff. `streams.sh` and `fail_closed.sh` source the
shared field registry at
`gist/bench/dominance/races/field.sh`; the
rest are self-contained.

| File                  | Contract                                                                                                                                                                                                      |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `streams.sh`          | **output split** — results→stdout, diagnostics (`--rank`'s timing line / guidance)→stderr, the `rg`-conventional split that keeps gist composable                                                             |
| `enum_determinism.sh` | **enumeration completeness** — with the soft cap live, `-l`/`-c`/`--count-matches`/`--files-without-match`/`--files` return the complete, run-to-run-stable set, never a truncated work-stealing-order subset |
| `fail_closed.sh`      | **degrade-to-correct** — a missing/corrupt index or a refused engine degrades to a correct live scan rather than a wrong or empty answer                                                                      |
| `freshness_fs.sh`     | **filesystem freshness** — a file changed after indexing is still found (the freshness overlay is exact-or-widen)                                                                                             |
| `ci_order.sh`         | **orchestration** — correctness gates run first, performance (certificate + ratio floors) second                                                                                                              |

```bash
cd <irregex-repo-root>
bench/conformance/gates/contract/streams.sh
bench/conformance/gates/contract/enum_determinism.sh
```
