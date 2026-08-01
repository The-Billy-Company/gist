# bench/conformance/gates

Permanent, fail-closed correctness and contract gates — each exits non-zero on
any violation, so a regression can't ship silently. They are split by **what
they oracle against**:

| Folder                            | Oracles against                          | Files                                                                                                              |
| --------------------------------- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| [`parity/`](parity/README.md)     | `rg` (or gist itself)                    | `equality` · `index_elision_parity` · `line_parity` · `unicode_parity` · `patterns_corpus_parity` · `partition_parity` · `scan_regress` |
| [`contract/`](contract/README.md) | gist's own behavioral promises           | `streams` · `enum_determinism` · `fail_closed` · `freshness_fs` · `ci_order`                                       |
| [`oracle/`](oracle/README.md)     | an independent engine / accounting model | `indexed_pcre_oracle.py` · `index_size_accounting.py`                                                              |

`parity/scan_regress.sh` and `contract/streams.sh` source the shared field
registry at
`gist/bench/dominance/races/field.sh`; `equality.sh`,
`index_elision_parity.sh`, and `enum_determinism.sh` are pure gist-side oracles
and need no field registry (`enum_determinism.sh` diffs gist against itself and
needs no `rg`).

## `parity/index_elision_parity.sh` — the index is acceleration-only

Builds a throwaway, hermetic corpus (signal + noise + a `.gitignore`d file +
a hidden file), indexes it, then for a battery of query shapes (literal,
regex, caseless, word, count, files-with(out), context, invert,
only-matching, type-/path-scoped) asserts the auto-indexed run's stdout and
exit code have the same byte-exact line multiset as the same query run with
`--no-index` — duplicates remain significant, while the parallel walk's
incidental cross-file scheduling order is normalized. A post-index-edit case
also proves the freshness overlay still finds a needle that arrived after the
index was built. Any divergence means the index is altering _results_, not just
skipping reads, which breaks gist's core safety claim.

```bash
cd <irregex-repo-root>
bench/conformance/gates/parity/index_elision_parity.sh
```

## `parity/partition_parity.sh` — the genus partition is a partition

`--docs` / `--code` / `--data` claim to _partition_ the corpus, and a partition
is a set-theoretic promise no unit test over spellings can make: it is about a
whole tree at once. Over the live repo this gate asserts the promise directly —
the three genera **cover** the unfiltered answer and **don't overlap**; each
`--no-X` is the exact complement of its positive; the `-t docs` / `-T docs`
aliases agree with the long flags line-for-line; the trigram index and the
resident daemon change latency only (armed ≡ stripped, warm ≡ cold); and no
genus **un-hides** a file rg's defaults hide — `.git/` contents never appear
under `--code`, which is exactly the bug the first draft shipped.

Two non-vacuity checks keep it honest: an extensionless `docs/`-resident file
must be _rescued_ into `--docs` (proving location outranks a missing extension),
and the docs and code answers must actually differ in both directions (proving
the flags aren't quietly no-ops). There is no `rg` column because ripgrep has no
docs/code axis to oracle against; the invariants are the specification.

```bash
cd <irregex-repo-root>
bench/conformance/gates/parity/partition_parity.sh
```

## `contract/enum_determinism.sh` — enumeration is complete under the cap

`parity/equality.sh` proves gist ≡ `rg` on the **full (uncapped)** matching-file
set. This gate proves the sibling invariant it can't see: with the **default**
~25k-token soft context cap ON, the compact per-file modes —
`-l`/`--files-with-matches`, `-c`/`--count`, `--count-matches`,
`--files-without-match`, and `--files` — return the **complete, run-to-run-stable**
set, never a soft-cap-truncated subset. Truncating the parallel engine's
worker-discovery-order stream at the cap used to return a nondeterministic subset
of files run-to-run (the same `gist -l foo` yielding a different set each call);
`corpus.exemptSoftCap` (keyed on `Opts.enumeration`) lifts only the soft guard
for these modes, and this gate freezes that.

Over a hermetic corpus whose enumeration output exceeds 100 KiB, each mode is
checked two ways under the default cap: **complete** (default-cap set ==
`GIST_UNCAP=1` set) and **stable** (three back-to-back runs identical as a sorted
set). A positive control first proves the cap is genuinely live on the corpus — a
non-exempt content mode truncates — so the completeness proof is never vacuous.
Runs the cold work-stealing engine (`GIST_NO_AUTOSERVE=1` + `--no-index`), where
the order-dependent truncation lived; the warm client applies the identical
exemption in `tryWarm`, so the engines can't disagree on which files `-l` returns.

```bash
cd <irregex-repo-root>
bench/conformance/gates/contract/enum_determinism.sh
```

## `parity/equality.sh` — the INDEX-path soundness oracle

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
cd <irregex-repo-root>
bench/conformance/gates/parity/equality.sh 150 1   # gist ≡ rg over a byte-exact corpus snapshot, per needle
```

## `parity/unicode_parity.sh` — the Unicode drop-in oracle

gist is a pure byte automaton; it now folds case, tests word boundaries, and
matches character/property classes over **Unicode codepoints by default**, the
same as `rg`. This gate freezes a multi-script fixture (Latin diacritics with
fold orbits like `café`/`CAFÉ` and `straße`, Greek including the final-sigma
`Σ`/`σ`/`ς` orbit, Cyrillic, CJK, fullwidth digits, and a lone invalid-UTF-8
byte) and asserts `gist rg <pat>` is stdout + exit-code byte-identical to
`rg <pat>` across four surfaces — Unicode fold (`-i`/`-S`), classes
(`\w \d \s . \p{...}`), word boundaries (`\b`/`-w`), and the `(?-u)` /
`--no-unicode` ASCII opt-out that must reproduce the old byte behavior exactly.
Runs once per engine (parallel `pipeline.zig` + serial `run.zig`).

```bash
cd <irregex-repo-root>
bench/conformance/gates/parity/unicode_parity.sh
```

## `parity/scan_regress.sh` — the no-prefilter fallback oracle

`equality.sh` proves the path where the trigram index elides reads. A regex
the index can't prefilter at all (`\w{3,8}`, `[a-f0-9]{2,}`, `panic|0x`, …)
gets no elision — the unified `ripgrep/` engine reads and regex-scans every
candidate itself over the live tree ([`src/exec/cold/engine/swarm/`](../../../src/exec/cold/engine/swarm)
drives the fused work-stealing walk+read+scan fan-out), so `equality.sh`'s frozen-snapshot proof
doesn't cover it — this script is the companion oracle:

1. **soundness** — diffs gist's match-set against plain `rg (?-u)` over the
   same live roots (gist's tree-walk honors `.gitignore` and hidden-file
   exclusion exactly like `rg`'s default, so no `--no-ignore`/`--hidden` skew)
   and **exits 1 on any FN/FP** (a file `rg` matches past the 4 MiB
   `per_file_cap` is a documented cap-skip, not a failure);
2. **race** — min-of-N vs `rg` as the speed floor for the full-read path.

Built ReleaseFast (release-vs-release with `rg`).

```bash
cd <irregex-repo-root>
bench/conformance/gates/parity/scan_regress.sh         # gate + race, default runs=12
bench/conformance/gates/parity/scan_regress.sh 20      # tighter timing
```

## `contract/streams.sh` — the stdout/stderr output contract

gist brands itself an _agent-friendly_ code locator: an agent in a shell does
`gist foo -l > files` and `gist foo | head`. This script reproduces the
pre-fix bug (results leaking onto stderr, or diagnostics mixed into stdout)
as a falsifiable assertion so it can never regress — each invocation is
checked for (a) results present on stdout and (b) no diagnostic leaking onto
stdout, with a distinct stderr budget for `--rank`'s timing line.

```bash
cd <irregex-repo-root>
bench/conformance/gates/contract/streams.sh
```
