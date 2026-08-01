# bench/conformance

**Fail-closed correctness — no timing claim lives here.** Every gate in this
bucket exits non-zero on a divergence, so a soundness regression can never ship
silently. Speed belongs to `dominance/`; this bucket only answers _is the answer
right?_

| Folder                          | What                                                                                                                                                                                                                                                                                     |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`gates/`](gates/README.md)     | the permanent correctness gates, split by what they oracle against: [`parity/`](gates/parity/README.md) (gist ≡ `rg`), [`contract/`](gates/contract/README.md) (output/enumeration/orchestration invariants), [`oracle/`](gates/oracle/README.md) (indexed-PCRE + index-size accounting) |
| [`rgsuite/`](rgsuite/README.md) | the ripgrep drop-in replay — one heavily cross-imported suite, kept flat on purpose                                                                                                                                                                                                      |
| [`diag/`](diag/README.md)       | diagnostic goldens (`--json`/trace shapes)                                                                                                                                                                                                                                               |
| [`shapes/`](shapes/README.md)   | the CLI-shape admission matrix (was `matrix/`): `shapes.toml` → `shapes.py` → `baseline.json`                                                                                                                                                                                            |
| [`targets/`](targets/README.md) | the cross-compile portability matrix                                                                                                                                                                                                                                                     |
| `relate/bench/conformance/relate/`   | the Layer-G retrieval contract for the `relate` face (was `knn/`)                                                                                                                                                                                                                        |
