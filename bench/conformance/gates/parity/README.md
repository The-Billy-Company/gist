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
| `type_union_parity.sh`      | **`-t` is a union** — every type named on the line reaches the answer, built-in or `--type-add`, in any order, byte-identical to `rg`; `-T <custom>` subtracts exactly its positive, and a custom `-t` still respects `.gitignore`                                  |
| `scan_regress.sh`           | **no-prefilter fallback** — the live-tree full-read fallback ≡ `rg (?-u)` (exits 1 on FN/FP) plus a min-of-N speed floor                                                                                                                                            |

`partition_parity.sh` has no `rg` column on purpose: ripgrep cannot express a
docs/code axis (its type globs are basename-only), so there is no oracle to
borrow and the invariants themselves are the specification. It is the gate that
notices when `--docs` quietly starts returning _most_ of the paper trail — the
classifier unit tests judge spellings, and a tree is where files go missing.

`patterns_corpus_parity.sh` is the one gate here that **constrains its corpus**
rather than building one, because its subject is a population over a real tree.
Everything it needs is a declared knob — the pruned root, the plain root, and
the slate of `<label> <pattern> [<scope>]` cases — so a package measuring itself
fails every one of them, loudly and by design. `bench/apparatus/corpora/`
generates a tree that supplies them all offline, and that is how to see it green:

```bash
bench/apparatus/corpora/fetch.sh torture
(cd .local/gist-corpora/torture && gist index)
GIST_CORPUS_ROOT="$PWD/.local/gist-corpora/torture" GIST_PARITY_SLATE=torture \
  bench/conformance/gates/parity/patterns_corpus_parity.sh
```

`type_union_parity.sh` synthesizes its corpus for the opposite reason
`patterns_corpus_parity.sh` constrains one: its subject is a flag's algebra, not
a population, and it needs go, py, rust, ts and tsx in one tree to ask the
question at all. gist's own checkout is pure Zig, so reading whatever tree it
runs in would make the interesting cases match nothing and pass as vacuously
equal — which is exactly how the bug it guards survived. The mix is the whole
point: built-in types union with built-in types correctly, and a custom type
alone matches `rg` exactly, so only a line holding both diverged.

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
bench/conformance/gates/parity/type_union_parity.sh
bench/conformance/gates/parity/unicode_parity.sh
```
