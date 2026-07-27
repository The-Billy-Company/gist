# bench/races

The multi-tool field races — gist vs the seven-tool field defined in
[`_compete.sh`](_compete.sh) (see `../README.md` for the tool roster and the
fairness rules every race honors). `_compete.sh` is **sourced, never
executed**; it defines the tool registry, the shared `ROOTS`/`XDIRS` scoping,
the `$SCOPE` ignore contract gist and rg share (identical flags on both sides,
so the rg-equality oracle stays honest), and the per-tool invocation helpers
(`compete_lit_cmd`, `compete_rgx_cmd`, `hf_mean`, …) that every race and gate
script in `bench/` builds on.

| File                      | Race                                                                                                                                                                                                                                                                                                             |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `_compete.sh`             | shared competitor registry — locations, tool roster, fairness scoping, invocation helpers (sourced only)                                                                                                                                                                                                         |
| `headtohead.sh`           | **warm**: gist's resident-index p50 vs the unindexed scanners at their warm fastest (the long-lived agent-session model)                                                                                                                                                                                         |
| `coldquery.sh`            | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed) — in **two emit lanes**, `-l` files-with-matches then `-c` per-file count                                                                                                                               |
| `regex_headtohead.sh`     | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)`                                                                                                                                                                                                               |
| `pcre_headtohead.sh`      | **cold PCRE**: gist's `-P` (vendored PCRE2 JIT, trigram-prefiltered) vs `rg -P` / `ugrep -P` on lookaround/backref queries                                                                                                                                                                                       |
| `searchzip_headtohead.sh` | **cold `-z`**: gist vs rg vs ugrep over a compressed corpus — in-process `std.compress` decode vs a fork-a-decompressor-per-file (gist beats both on gzip/zstd/xz; bzip2 + the external-codec tail have no in-process Zig decoder)                                                                               |
| `relate_headtohead.sh`    | **relate**: `relate similar <text>` (paraphrase retrieval by conditional description length) vs the exact-search field — gist proves 0 hits on the class (capability line), then relate one-pass vs the K-token gist emulation; doubles as the relate quality gate (planted source must rank top-1, else exit 1) |
| `scanner_headtohead.sh`   | **scanner (no index)**: `gist --no-index` — no persisted index, no daemon — vs rg over the same 12 classes, in the same `-l` and `-c` lanes, sampled INTERLEAVED round-robin so a load excursion on a shared machine can't be read as a tool difference; feeds Layer I                                           |

## Scenarios

- **Cold literal slate** (`coldquery.sh`): a guaranteed miss (pure index win),
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
- **Cold regex slate** (`regex_headtohead.sh`): 22 patterns grouped by tier —
  literal-prefix, anchored `^`/`$`, counted `{n,m}`, dense classes (`\w{3,8}` —
  the byte-class DFA's home), alternation cover sets, and a prefilter-less
  mixed alternation.
- **Warm slate** (`headtohead.sh`): the same adversarial literal set the field
  races on, raced against gist's resident RAM index (no process spawn, no
  cold-load) — the model an agent session actually lives in.
- **Search-zip slate** (`searchzip_headtohead.sh`): a synthetic nested tree of
  `COUNT` compressed files per format (`COUNT=400 RUNS=8` default), each tool on
  its transparent-`-z` path. The corpus is nested (not flat) because gist's
  pipeline steals work per directory — a flat archive would pin it to one worker.
- **Scanner slate** (`scanner_headtohead.sh`): the cold slate's own 12 classes,
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
- **Relate slate** (`relate_headtohead.sh`): a synthetic deterministic corpus of
  boilerplate-heavy files with per-file topical vocabulary; queries are
  paraphrases of planted files (verbatim in no file). relate must retrieve each
  planted source top-1 (hard gate), gist must find 0 exact hits, and the timing
  lane races relate's one pass against the one-gist-per-token emulation.

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,cold_count,regex,warm}.csv`.

```bash
cd pkg/kernels/irregex
bench/races/headtohead.sh          # WARM: gist resident p50 vs the unindexed scanners
bench/races/coldquery.sh           # COLD literal: gist vs csearch/zoekt + rg/ugrep/ag/ggrep/git-grep
bench/races/regex_headtohead.sh    # COLD regex: same field, per feature tier
bench/races/pcre_headtohead.sh     # COLD PCRE: gist -P vs rg -P / ugrep -P
bench/races/searchzip_headtohead.sh # COLD -z: gist vs rg vs ugrep over compressed files
bench/races/relate_headtohead.sh   # RELATE: relate paraphrase retrieval + quality gate
bench/races/scanner_headtohead.sh  # SCANNER: gist --no-index vs rg, interleaved (Layer I)
```

Layer I of the certificate is minted from that last race plus the `bench/rgsuite`
conformance lanes. One line wires it (the parent owns `certify_layers.sh`; this
is the invocation it needs):

```bash
python3 "${HERE}/certify_scanner_report.py" "${COMPETE_DIR}/scanner" \
  --certificate "${CERT}" --csv "${ART}/scanner.csv" \
  --conformance "${COMPETE_DIR}/surface.json" --mined "${HERE}/../rgsuite/results.json" \
  --fuzz "${COMPETE_DIR}/fuzz.json" --conformance-baseline 100.0
```
