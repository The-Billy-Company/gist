# doc_radar canary (ADR-352)

The plan makes [`doc_radar`](../../../../../../scripts/observe/trust/doc_radar)
the canary for the unified search API: prove GIST is a byte-equivalent
substitute for the `rg` calls the radar makes, and measure the repeated-query
cost, **before** graduating GIST into any live `rg` consumer.

This module is the evidence, run over doc_radar's _real_ query corpus (never a
synthetic stand-in): the one marker-discovery `ripgrep_files` pass plus every
`still_here` count pin declared across all ADRs.

```bash
# from pkg/kernels/gist/bindings/python
uv run --with pyyaml python -m canary.doc_radar          # human summary
uv run --with pyyaml python -m canary.doc_radar --json   # machine evidence
```

`pyyaml` is needed only to replay doc_radar's YAML frontmatter (the radar itself
uses it); the shipped `gist` package stays pure-Python. The gate form lives in
[`tests/test_doc_radar_canary.py`](../tests/test_doc_radar_canary.py) and skips
cleanly without a built `gist` binary or `rg`.

## What it proves

- **Equivalence.** For every query it runs `rg` (the oracle) and GIST (through
  the importable package — the canary dogfoods the new API) and asserts
  identical results. A pattern outside GIST's linear-time engine is recorded as
  `unsupported` (a loud, known `rg` fallback), never a silent divergence.
- **Warm path.** It times the count batch three ways — `rg`, GIST warm
  (persisted `.local/gist-verify/index.gist`), GIST cold (`--no-index`).

## Findings (2026-07, this checkout)

- **58/58 byte-equivalent, 0 unsupported.** Swapping the engine changes no
  radar verdict.
- **GIST ≈1.6x faster than `rg`** across the batch — but `gist_cold ≈
gist_warm`. doc_radar's `still_here` pins search _single explicit files_, so
  the persisted index adds mmap cost without pruning benefit; the win here is
  raw per-invocation speed, not the index.
- The material _index/session_ warm win the plan hypothesized is for
  broad-tree queries and lands cleanly only with the in-process resident
  session ADR-352 defers — each subprocess call still re-pays process +
  mmap startup. This is the evidence that gates that graduation rung.
- The canary immediately caught a **latent doc_radar bug**: a `still_here`
  pattern beginning with `-` (e.g. ADR-326's `--shallow`) was passed
  positionally to `rg`, which misparsed it as a flag and errored (`matches:
-1`, a spurious fail). GIST carries the pattern via `--regexp` and was
  correct. The fix — carry the pattern via `-e`/`--regexp` in the radar's
  wrappers — is the same argv discipline the unified API already uses.
