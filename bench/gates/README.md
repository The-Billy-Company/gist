# bench/gates

Permanent, fail-closed correctness and contract gates — each exits non-zero on
any violation, so a regression can't ship silently. `scan_regress.sh` and
`streams.sh` source the shared field registry at
[`../races/_compete.sh`](../races/_compete.sh); `equality.sh`,
`index_elision_parity.sh`, and `enum_determinism.sh` are pure gist-side oracles
and need no field registry (`enum_determinism.sh` diffs gist against itself and
needs no `rg`).

| File                      | Gate                                                                                                                                                                                                                                   |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `equality.sh`             | **correctness (index vs `rg`)**: gist ≡ `rg` over a byte-exact corpus snapshot — the soundness oracle                                                                                                                                  |
| `index_elision_parity.sh` | **correctness (index vs itself)**: the index-accelerated run ≡ the same query with `--no-index` — proves the index only elides reads, never changes results                                                                            |
| `enum_determinism.sh`     | **correctness (enumeration completeness)**: with the soft cap live, `-l`/`-c`/`--count-matches`/`--files-without-match`/`--files` return the complete, run-to-run-stable set — never a truncated, work-stealing-order-dependent subset |
| `unicode_parity.sh`       | **correctness (Unicode drop-in)**: `gist <pat>` ≡ `rg <pat>` at rg's default (Unicode) semantics over a multi-script fixture — fold, classes, `\b`/`-w`, and the `(?-u)`/`--no-unicode` opt-out, byte-identical on both engines        |
| `scan_regress.sh`         | **correctness (no-prefilter fallback) + race**: the live-tree full-read fallback ≡ `rg` (exits 1 on FN/FP) + min-of-N speed floor                                                                                                      |
| `streams.sh`              | **output contract**: results→stdout, diagnostics (`--rank`'s timing line / guidance)→stderr — the `rg`-conventional split that makes gist composable                                                                                   |
| `ci_order.sh`             | **orchestration**: correctness gates first, then performance (certificate + ratio floors)                                                                                                                                              |

## `index_elision_parity.sh` — the index is acceleration-only

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
cd pkg/kernels/irregex
bench/gates/index_elision_parity.sh
```

## `enum_determinism.sh` — enumeration is complete under the cap

`equality.sh` proves gist ≡ `rg` on the **full (uncapped)** matching-file set.
This gate proves the sibling invariant it can't see: with the **default**
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
cd pkg/kernels/irregex
bench/gates/enum_determinism.sh
```

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
cd pkg/kernels/irregex
bench/gates/equality.sh 150 1      # gist ≡ rg over a byte-exact corpus snapshot, per needle
```

## `unicode_parity.sh` — the Unicode drop-in oracle

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
cd pkg/kernels/irregex
bench/gates/unicode_parity.sh
```

## `scan_regress.sh` — the no-prefilter fallback oracle

`equality.sh` proves the path where the trigram index elides reads. A regex
the index can't prefilter at all (`\w{3,8}`, `[a-f0-9]{2,}`, `panic|0x`, …)
gets no elision — the unified `ripgrep/` engine reads and regex-scans every
candidate itself over the live tree ([`src/exec/cold/engine/swarm/`](../../src/exec/cold/engine/swarm)
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
cd pkg/kernels/irregex
bench/gates/scan_regress.sh         # gate + race, default runs=12
bench/gates/scan_regress.sh 20      # tighter timing
```

## `streams.sh` — the stdout/stderr output contract

gist brands itself an _agent-friendly_ code locator: an agent in a shell does
`gist foo -l > files` and `gist foo | head`. This script reproduces the
pre-fix bug (results leaking onto stderr, or diagnostics mixed into stdout)
as a falsifiable assertion so it can never regress — each invocation is
checked for (a) results present on stdout and (b) no diagnostic leaking onto
stdout, with a distinct stderr budget for `--rank`'s timing line.

```bash
cd pkg/kernels/irregex
bench/gates/streams.sh
```
