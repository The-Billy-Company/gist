---
doc_radar:
  paths_exist:
    - pkg/kernels/irregex/src/cli/gist/main.zig
    - pkg/kernels/irregex/contract/search_api.toml
    - pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
  sentinels:
    - file: pkg/kernels/irregex/src/runtime/cold/argv/args.zig
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

# Gist — agent-loop indexed regex locator

A **systems/workload composition** for one repository and one high-frequency
consumer: coding agents repeatedly issuing small grep-shaped queries against a
concurrently changing tree. Persistent byte-trigram candidate index, crest
sidecar for literal-free class repetitions, freshness-aware live fallback,
linear + opt-in PCRE2 verification, ripgrep-like CLI conventions, and compact
definition-biased ranking — measured against a fail-closed correctness slate
and Certificate of Optimality.

That composition is the claim. The underlying techniques are established prior
art (except the crest sieve, which has its own dossier).

## This folder (research: writing + scope only)

| file | role |
|---|---|
| `CLAIM.md` | precise novelty statement, explicit non-claims, public contract (`--schema`), what the composition is and is not |
| `PRIOR_ART.md` | the full landscape review: every neighboring family (agent search, indexed regex, semantic/structural), why each is a different object |
| `TESTING.md` | the complete evidence story: rg-oracle parity, index-elision, freshness, resident fail-open, Certificate layers A–D, reproduction commands |

## The code (lives with the system, not here)

| where | what |
|---|---|
| `src/cli/gist/` | the product CLI face (search, index, status, serve, codex) |
| `src/runtime/cold/` | authoritative cold path: argv → walk → index elision → verify → emit |
| `src/index/trigrams/` + `src/index/crest/` | candidate filters (trigrams + crest sidecar) |
| `src/search/rank/` | definition-biased `--rank` view |
| `src/runtime/session/` | fail-open resident UDS session |
| `bench/gates/` + `bench/rgsuite/` + `bench/certify/` | correctness-before-speed gates, mined rg parity, Certificate of Optimality |

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
(`make install-gist`; workspace rule: gist not ripgrep). Public surface is the
four-bucket flag catalog behind `gist --schema`. Prior-art scope and explicit
non-claims live in `PRIOR_ART.md`; the composition claim in `CLAIM.md`; the
evidence inventory in `TESTING.md`.
