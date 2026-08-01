# bench/races

The multi-tool field races — gist vs the seven-tool field defined in
[`field.sh`](field.sh) (see `../README.md` for the tool roster and the
fairness rules every race honors). `field.sh` is **sourced, never
executed**; it defines the tool registry, the shared `ROOTS`/`XDIRS` scoping,
the `$SCOPE` ignore contract gist and rg share (identical flags on both sides,
so the rg-equality oracle stays honest), and the per-tool invocation helpers
(`compete_lit_cmd`, `compete_rgx_cmd`, `hf_mean`, …) that every race and gate
script in `bench/` builds on.

| File             | Race                                                                                                                                                                                                                                                                                                             |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `field.sh`       | shared competitor registry — locations, tool roster, fairness scoping, invocation helpers (sourced only)                                                                                                                                                                                                         |
| `warm.sh`        | **warm**: gist's resident-index p50 vs the unindexed scanners at their warm fastest (the long-lived agent-session model)                                                                                                                                                                                         |
| `cold.sh`        | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed) — in **two emit lanes**, `-l` files-with-matches then `-c` per-file count                                                                                                                               |
| `regex.sh`       | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)`                                                                                                                                                                                                               |
| `pcre.sh`        | **cold PCRE**: gist's `-P` (vendored PCRE2 JIT, trigram-prefiltered) vs `rg -P` / `ugrep -P` on lookaround/backref queries                                                                                                                                                                                       |
| `searchzip.sh`   | **cold `-z`**: gist vs rg vs ugrep over a compressed corpus — in-process `std.compress` decode vs a fork-a-decompressor-per-file (gist beats both on gzip/zstd/xz; bzip2 + the external-codec tail have no in-process Zig decoder)                                                                               |
| `relate.sh`      | **relate**: `relate similar <text>` (paraphrase retrieval by conditional description length) vs the exact-search field — gist proves 0 hits on the class (capability line), then relate one-pass vs the K-token gist emulation; doubles as the relate quality gate (planted source must rank top-1, else exit 1) |
| `scanner.sh`     | **scanner (no index)**: `gist --no-index` — no persisted index, no daemon — vs rg over the same 12 classes, in the same `-l` and `-c` lanes, sampled INTERLEAVED round-robin so a load excursion on a shared machine can't be read as a tool difference; feeds Layer I                                           |
| `multipattern.sh` | **multipattern**: multi-needle field race over the shared competitor registry                                                                                                                                                                                                                                    |

## Scenarios

- **Cold literal slate** (`cold.sh`): a guaranteed miss (pure index win),
  very-selective symbols, medium, common tokens touching thousands of files, and
  a 2-byte punctuation needle (the `<3 B`, no-trigram-filter fallback). Raced in
  two emit lanes over the same needles: **`-l`** files-with-matches (first-hit
  short-circuit — the whole field, indexed + unindexed) and **`-c`** per-file
  count (whole-candidate scan + tally, no short-circuit — the unindexed grep-`-c`
  field). The count lane proves the index win holds when per-candidate work rises;
  gist's `-c` stays byte-parity with rg (matrix + flagbench), so its cell is
  oracle-gated against rg exactly like `-l`. Both indexed rivals are absent from
  the count lane by construction — zoekt has no per-file `-c`, and csearch's `-c`
  is a total-match tally, not grep's per-line-per-file count.
- **Cold regex slate** (`regex.sh`): 22 patterns grouped by tier —
  literal-prefix, anchored `^`/`$`, counted `{n,m}`, dense classes (`\w{3,8}` —
  the byte-class DFA's home), alternation cover sets, and a prefilter-less
  mixed alternation.
- **Warm slate** (`warm.sh`): the same adversarial literal set the field
  races on, raced against gist's resident RAM index (no process spawn, no
  cold-load) — the model an agent session actually lives in.
- **Search-zip slate** (`searchzip.sh`): a synthetic nested tree of
  `COUNT` compressed files per format (`COUNT=400 RUNS=8` default), each tool on
  its transparent-`-z` path. The corpus is nested (not flat) because gist's
  pipeline steals work per directory — a flat archive would pin it to one worker.
- **Scanner slate** (`scanner.sh`): the cold slate's own 12 classes,
  raced with gist's advantage removed — `--no-index` plus `GIST_NO_AUTOSERVE=1`,
  so each cell is a fresh process doing a live walk, read, and scan. It answers
  the "ripgrep is a scanner by design" objection on ripgrep's home turf, and it
  is the only race here that does **not** sample block-per-tool: each round runs
  every tool once in rotation (`RUNS=15`, 2 warmup), because ~10 agents share
  this machine and a block of samples is a block of moments. Each cell is
  equivalence-checked against rg's exact result set before it is timed, an
  `flock`-style owner dir keeps two concurrent invocations from interleaving into
  one output tree, and `SCANNER_NO_BUILD=1` skips the rebuild when a coworker's
  in-flight change has the tree failing to compile. Rows land in
  `.local/gist-compete/scanner/`.
- **Relate slate** (`relate.sh`): a synthetic deterministic corpus of
  boilerplate-heavy files with per-file topical vocabulary; queries are
  paraphrases of planted files (verbatim in no file). relate must retrieve each
  planted source top-1 (hard gate), gist must find 0 exact hits, and the timing
  lane races relate's one pass against the one-gist-per-token emulation.

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,cold_count,regex,warm}.csv`.

```bash
# from the gist package root
bench/dominance/races/warm.sh       # WARM: gist resident p50 vs the unindexed scanners
bench/dominance/races/cold.sh       # COLD literal: gist vs csearch/zoekt + rg/ugrep/ag/ggrep/git-grep
bench/dominance/races/regex.sh      # COLD regex: same field, per feature tier
bench/dominance/races/pcre.sh       # COLD PCRE: gist -P vs rg -P / ugrep -P
bench/dominance/races/searchzip.sh  # COLD -z: gist vs rg vs ugrep over compressed files
bench/dominance/races/relate.sh     # RELATE: relate paraphrase retrieval + quality gate
bench/dominance/races/scanner.sh    # SCANNER: gist --no-index vs rg, interleaved (Layer I)
```

Layer I of the certificate is minted from that last race plus the
`irregex/bench/conformance/rgsuite` conformance lanes. One line wires it (the
parent owns the mint; this is the invocation it needs):

```bash
python3 bench/certificate/report/scanner.py "${COMPETE_DIR}/scanner" \
  --certificate "${CERT}" --csv "${ART}/scanner.csv" \
  --conformance "${COMPETE_DIR}/surface.json" \
  --mined bench/conformance/rgsuite/results.json \
  --fuzz "${COMPETE_DIR}/fuzz.json" \
  --conformance-baseline "${ART}/scanner_conformance.json" \
  --fuzz-baseline bench/conformance/rgsuite/fuzz_baseline.json
```

`--fuzz` is **mandatory**. It was optional while any divergence was an outright
refusal, and those two rules together left "omit the lane" as the only way a
real run could mint — the certificate published two 100% figures and printed the
fuzz command in its own reproduce block without ever carrying that command's
result. The residual is now reportable and ratcheted shrink-only per class
(`--fuzz-baseline`), so the honest outcome and the mintable one coincide.

The two halves of Layer I age at very different rates: a flag surface moves
whenever gist catalogues an improvement (minutes to re-probe), while the timing
table needs a quiescent machine. So conformance can be re-verified on its own,
and the timed table is left exactly as minted — re-rendering it from a noisier
race to move a flag count would trade a clean measurement for a worse one:

```bash
python3 bench/conformance/rgsuite/surface.py --json "${COMPETE_DIR}/surface.json"
python3 bench/certificate/report/scanner.py --conformance-only \
  --certificate "${CERT}" --conformance "${COMPETE_DIR}/surface.json" \
  --mined bench/conformance/rgsuite/results.json \
  --fuzz "${COMPETE_DIR}/fuzz.json" \
  --fuzz-baseline bench/conformance/rgsuite/fuzz_baseline.json
```

It fails closed on the same evidence the full mint does (any divergence,
rejection, unprobed value flag, failing undo pair, mined FAIL, a conformance
percentage under the committed floor, or a fuzz residual that grew in total or
in any one class — or that holds a class the baseline does not name) and refuses
outright if no timing table has been minted for it to sit under.
