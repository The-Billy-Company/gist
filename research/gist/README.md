---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/surface/face/gist/main.zig
    - pkg/kernels/irregex/contract/search_api.toml
    - pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
  sentinels:
    - file: pkg/kernels/irregex/src/surface/exec/cold/argv/args.zig
      contains:
        - "pub const flag_catalog"
        - "unsupported_fail_loud"
    - file: pkg/kernels/irregex/bench/gates/ci_order.sh
      contains:
        - "pcre parity -P"
        - "index-elision parity"
        - "macro certificate"
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains:
        - 'subprocess = { status = "authoritative"'
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

| where                                                    | what                                                                       |
| -------------------------------------------------------- | -------------------------------------------------------------------------- |
| `src/surface/face/gist/`                                 | the product CLI face (search, index, status, serve, codex)                 |
| `src/surface/exec/cold/`                                 | authoritative cold path: argv → walk → index elision → verify → emit       |
| `src/corpus/index/trigrams/` + `src/corpus/index/crest/` | candidate filters (trigrams + crest sidecar)                               |
| `src/kernel/rank/`                                       | definition-biased `--rank` view                                            |
| `src/surface/exec/session/`                              | fail-open resident UDS session                                             |
| `bench/gates/` + `bench/rgsuite/` + `bench/certify/`     | correctness-before-speed gates, mined rg parity, Certificate of Optimality |

Novel math that rides inside gist (forced-class-run pruning) is documented
separately in [`../crest/`](../crest/PROOF.md) — not duplicated here.

## Run

```bash
make install-gist                 # ReleaseFast binaries + PATH + trigram index
gist 'SearchRequest' --rank       # everyday agent search
gist '[0-9a-f]{12}'               # crest sieve elides pruned reads
gist --schema                     # authoritative public compatibility contract
cd pkg/kernels/irregex && zig build test
make bench-gist-certify           # refresh Certificate layers (see TESTING.md)
```

## Measured (committed Certificate artifact)

On the recorded certificate corpus, gist beat ripgrep in all 12 query classes
by 1.97×–23.57× under fail-closed statistics (lower median **and** Mann–Whitney
p < 0.05). Those are measurements from
[`bench/certify/artifact/CERTIFICATE.md`](../../bench/certify/artifact/CERTIFICATE.md),
not universal constants. Correctness gates always run before performance gates
(`bench/gates/ci_order.sh`).

## Status

**Shipped.** Dogfooded as the agents' everyday exact/regex locator
(`make install-gist`; workspace rule: gist not ripgrep). Start with the
positive case in [`CLAIM.md`](CLAIM.md), audit its ancestry in
[`PRIOR_ART.md`](PRIOR_ART.md), then test every assertion against
[`TESTING.md`](TESTING.md) and the four-bucket `gist --schema` contract.
