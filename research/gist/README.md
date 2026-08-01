---
doc_radar:
  paths_exist:
    - src/surface/face/gist/main.zig
    - contract/surface.toml
    - ../irregex/contract/engine.toml
    - bench/certificate/artifact/CERTIFICATE.md
  sentinels:
    - file: ../irregex/src/exec/cold/argv/catalog.zig
      contains:
        - "pub const flag_catalog"
        - "unsupported_fail_loud"
    - file: ../irregex/bench/conformance/gates/contract/ci_order.sh
      contains:
        - "pcre parity -P"
        - "index-elision parity"
        - "macro certificate"
    - file: contract/surface.toml
      contains:
        - 'subprocess = { status = "authoritative"'
    - description: "canary for the Layer A (index-on) 12-class win range quoted below — a re-mint moves both bounds, and breaking here is the signal to restate them"
      file: bench/certificate/artifact/CERTIFICATE.md
      contains:
        - "gist vs ripgrep across 12 classes: 12 win · 0 parity · 0 loss"
        - "machine: **Apple M4 Max**"
        - "8.93x"
        - "5.78x"
    - description: "canary for the Layer I (scanner-only) sweep and geomean this file leads with, and the Layer J scale caveat that bounds both"
      file: bench/certificate/artifact/CERTIFICATE.md
      contains:
        - "24 win · 0 parity · 0 loss"
        - "the scanner alone is **1.93× faster than ripgrep**"
        - "352,316 files / 5.5 GiB on disk"
        - "wins 5, ties 2, loses 5"
---

# Gist — research map for agent-loop code search

Gist studies one systems question: **how often can an agent search a changing
repository without letting acceleration impersonate truth?** Its answer is a
ripgrep-shaped locator whose live tree remains authoritative while a
persistent trigram index, Crest sidecar, resident session, PCRE2 literal
proofs, and definition-biased ranking optimize the repeated locate → inspect →
refine loop.

The research claim is the measured **systems/workload composition**. The
product case, ancestry, and evidence are kept separate so usefulness does not
stand in for novelty and benchmark speed does not stand in for correctness.

## This folder (research: writing + scope only)

| file                           | research role                                                                                                                                          |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [`CLAIM.md`](CLAIM.md)         | the positive product thesis: why agent search is a distinct workload, how one query works, what the architecture unlocks, and where originality begins |
| [`PRIOR_ART.md`](PRIOR_ART.md) | the comparison set: agent search, indexed search, matchers, ranking, and the exact ancestry of every borrowed technique                                |
| [`TESTING.md`](TESTING.md)     | the falsification record: rg-oracle parity, index-elision, freshness, resident fail-open, Certificate layers A–D, and reproduction commands            |

## The code (lives with the system, not here)

| where                                                    | what                                                                           |
| -------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `src/surface/face/gist/`                                 | the product CLI face (search, index, status, serve, codex)                     |
| `src/exec/cold/`                                 | authoritative cold path: argv → walk → index elision → verify → emit           |
| `src/corpus/index/trigrams/` + `src/corpus/index/crest/` | candidate filters (trigrams + crest sidecar)                                   |
| `src/kernel/rank/`                                       | definition-biased `--rank` view                                                |
| `src/exec/session/`                              | fail-open resident UDS session                                                 |
| `bench/gates/` + `bench/rgsuite/` + `bench/certify/`     | correctness-before-speed gates, mined rg parity, Dominance-and-Fit Certificate |

Novel math that rides inside gist (forced-class-run pruning) is documented
separately in `irregex/research/crest/` — not duplicated here.

## Run

```bash
zig build                 # ReleaseFast binaries + PATH + trigram index
gist 'SearchRequest' --rank       # everyday agent search
gist '[0-9a-f]{12}'               # crest sieve elides pruned reads
gist --schema                     # authoritative public compatibility contract
zig build test
bash bench/certificate/mint/mint.sh           # refresh Certificate layers (see TESTING.md)
```

## Measured (committed Certificate artifact)

Two layers, two claims, and the research record keeps them apart because they
answer different objections.

**Layer A — index on.** On the recorded certificate corpus, gist beat a cold
ripgrep in all 12 query classes by 5.78×–8.93× under fail-closed statistics
(lower median **and** Mann–Whitney p < 0.05). This is the regime an agent runs
in; it is an indexed engine against a scanner, and it does not answer "would
you win without the index?"

**Layer I — index off, daemon off.** The answer to that question, and the
number to lead with when the claim is contested: `gist --no-index` with no
resident session, a fresh process doing the same live walk, read, and scan
ripgrep does, wins **24 of 24 certified cells** (the 12 classes' `-l` argv plus
a `-c` lane where nothing can short-circuit) — 0 parity, 0 losses, every cell
at p < 0.001 — for a **1.93× geomean**. The index is then worth a further 3.1×
on top of that, which is where Layer A's wider range comes from.

**Where the corpus stops generalizing.** Both layers are minted on the source
monorepo (20,660 files / 204.6 MiB) on an Apple M4 Max — the workload the tool
is built for, and therefore not a neutral proof. Layer J re-runs the field at
352,316 files / 5.5 GiB of Linux/LLVM/Go/Rust, where csearch still takes the
cheap-literal classes (gist wins 5, ties 2, loses 5) and peak RSS, not time, is
the binding ceiling.

All of these are measurements from
[`bench/certify/artifact/CERTIFICATE.md`](../../bench/certificate/artifact/CERTIFICATE.md),
not universal constants. Correctness gates always run before performance gates
(`bench/gates/ci_order.sh`).

## Status

**Shipped.** Dogfooded as the agents' everyday exact/regex locator
(`zig build`; workspace rule: gist not ripgrep). Start with the
positive case in [`CLAIM.md`](CLAIM.md), audit its ancestry in
[`PRIOR_ART.md`](PRIOR_ART.md), then test every assertion against
[`TESTING.md`](TESTING.md) and the four-bucket `gist --schema` contract.
