# bench/races

The multi-tool field races — gist vs the seven-tool field defined in
[`_compete.sh`](_compete.sh) (see `../README.md` for the tool roster and the
fairness rules every race honors). `_compete.sh` is **sourced, never
executed**; it defines the tool registry, the shared `ROOTS`/`XDIRS` scoping,
and the per-tool invocation helpers (`compete_lit_cmd`, `compete_rgx_cmd`,
`hf_mean`, …) that every race and gate script in `bench/` builds on.

| File                  | Race                                                                                                                     |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `_compete.sh`         | shared competitor registry — locations, tool roster, fairness scoping, invocation helpers (sourced only)                 |
| `headtohead.sh`       | **warm**: gist's resident-index p50 vs the unindexed scanners at their warm fastest (the long-lived agent-session model) |
| `coldquery.sh`        | **cold literal**: fresh-process gist vs csearch/zoekt (indexed) + rg/ugrep/ag/ggrep/git-grep (unindexed)                 |
| `regex_headtohead.sh` | **cold regex**: same field, gist's byte-class DFA vs RE2 (csearch/zoekt) and PCRE (`-P`) / `(?-u)`                       |
| `pcre_headtohead.sh`  | **cold PCRE**: gist's `-P` (vendored PCRE2 JIT, trigram-prefiltered) vs `rg -P` / `ugrep -P` on lookaround/backref queries |
| `searchzip_headtohead.sh` | **cold `-z`**: gist vs rg vs ugrep over a compressed corpus — in-process `std.compress` decode vs a fork-a-decompressor-per-file (gist beats both on gzip/zstd/xz; bzip2 + the external-codec tail have no in-process Zig decoder) |

## Scenarios

- **Cold literal slate** (`coldquery.sh`): a guaranteed miss (pure index win),
  very-selective symbols, medium, common tokens touching thousands of files, and
  a 2-byte punctuation needle (the `<3 B`, no-trigram-filter fallback).
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

Each race prints per-query times with gist's speedup, then a summary: **geomean
speedup and win-rate per tool**, split indexed vs unindexed. Raw rows land in
`.local/gist-compete/{cold,regex,warm}.csv`.

```bash
cd pkg/kernels/gist
bench/races/headtohead.sh          # WARM: gist resident p50 vs the unindexed scanners
bench/races/coldquery.sh           # COLD literal: gist vs csearch/zoekt + rg/ugrep/ag/ggrep/git-grep
bench/races/regex_headtohead.sh    # COLD regex: same field, per feature tier
bench/races/pcre_headtohead.sh     # COLD PCRE: gist -P vs rg -P / ugrep -P
bench/races/searchzip_headtohead.sh # COLD -z: gist vs rg vs ugrep over compressed files
```
