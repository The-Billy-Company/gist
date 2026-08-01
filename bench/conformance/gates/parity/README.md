# bench/conformance/gates/parity

Correctness gates that oracle gist **against `rg`** (or against gist itself) — a
divergence here means the answer is wrong, and each script exits non-zero on any
FN/FP. `scan_regress.sh` sources the shared field registry at
`gist/bench/dominance/races/field.sh`; the
rest are pure gist-side oracles needing no field.

| File                        | Gate                                                                                                                                                                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `equality.sh`               | **index vs `rg`** — gist ≡ `rg` over a byte-exact corpus snapshot; a file in `rg`'s set but not gist's is a trigram-filter false negative, the reverse is an unsound verify. Both must be zero                                                                      |
| `index_elision_parity.sh`   | **index vs itself** — the auto-indexed run ≡ the same query with `--no-index`, proving the index only elides reads, never changes results                                                                                                                           |
| `line_parity.sh`            | **line reporting** — line numbers / `-n` / column output byte-identical to `rg`                                                                                                                                                                                     |
| `unicode_parity.sh`         | **Unicode drop-in** — `gist <pat>` ≡ `rg <pat>` at rg's default Unicode semantics (fold, classes, `\b`/`-w`, and the `(?-u)` opt-out) over a multi-script fixture, once per engine                                                                                  |
| `patterns_corpus_parity.sh` | **multi-pattern set** — `relate patterns -e …` covers the exact file set `gist -l` answers over, keeping the dragnet/trawl a true drop-in                                                                                                                           |
| `partition_parity.sh`       | **the genus partition over a real tree** — `docs ∪ code ∪ data` is the unfiltered answer and the pairs are disjoint; each `--no-X` is its positive's exact complement; `-t`/`-T` agree with the long flags; index and daemon change speed only; no genus un-hides   |
| `phantom_walk_parity.sh`    | **the `tree.map` snapshot vs itself** — the phantom-served run ≡ the same query with `GIST_NO_PHANTOM=1` (every directory listed live), across both the served and the cost-declined branch, with content-edit and membership-change freshness as the adverse cases |
| `scan_regress.sh`           | **no-prefilter fallback** — the live-tree full-read fallback ≡ `rg (?-u)` (exits 1 on FN/FP) plus a min-of-N speed floor                                                                                                                                            |

`partition_parity.sh` has no `rg` column on purpose: ripgrep cannot express a
docs/code axis (its type globs are basename-only), so there is no oracle to
borrow and the invariants themselves are the specification. It is the gate that
notices when `--docs` quietly starts returning _most_ of the paper trail — the
classifier unit tests judge spellings, and a tree is where files go missing.

`phantom_walk_parity.sh` is the differential twin of `index_elision_parity.sh`
with the directory-membership snapshot as the subject instead of the trigram
index, and it guards a claim that is easy to lose: the snapshot may only change
_syscalls_. Both of the walk's branches have to be exercised, because it chooses
between them per directory on cost — a filtered query is served from the mapping
while a broad one declines to the live listing — so the gate pairs `broad-*`
cases against `glob-*` ones. Its freshness cases are the ones that matter most: a
child rewritten in place leaves its parent's clocks untouched, so the directory
stays provably servable while the file is stale, and only per-file freshness
keeps that from becoming a false negative.

```bash
cd <irregex-repo-root>
bench/conformance/gates/parity/equality.sh 150 1
bench/conformance/gates/parity/index_elision_parity.sh
bench/conformance/gates/parity/partition_parity.sh
bench/conformance/gates/parity/phantom_walk_parity.sh
bench/conformance/gates/parity/unicode_parity.sh
```
