# billy-irregex tests

Four tiers: contract-only (no binary, no library), cold subprocess, warm
session/FFI, and cross-language parity — each skipping cleanly when its
prerequisite is absent. Run with `uv run pytest` from `bindings/python/`.

## Contract and calibration (no binary needed)

- `test_contract.py` — the `irregex.contract` mirror must not drift from the
  canonical `contract/search_api.toml` or the driven binary's version (ADR-352).
- `test_grade_parity.py` — Python calibration (channels, bands, polarity) parsed
  from the Zig kernel source (`channel.zig`) as the sole oracle. No numbers typed
  twice.
- `test_rows.py` — the analytic row decoder driven from synthesized value arrays
  against `schema.gen.py`: absent vs zero, unnamed ordinals, nested rows, batch
  boundaries. No binary, no library.
- `test_agent.py` — the `request_from_tool` seam: a tool-boundary dict maps into
  `SearchRequest` fields, with place/ranking left to the caller.

## Cold subprocess (needs `gist`/`relate`/`irregex` binary)

- `test_search.py` — behavioral tests over a throwaway corpus, plus **rg-parity**
  asserting GIST's discovery set is byte-equivalent to ripgrep's. Skips without
  `gist` or `rg` on PATH.
- `test_aggregate.py` — the `tally`/`summary` layer. Pure cases (synthetic
  matches, no binary) + integration cases asserting `summary` agrees with the
  flat `search` it derives from.
- `test_rank.py` — the engine's `--rank` view. Pure row-grammar parse (no binary)
  - integration cases that build a throwaway index and assert the engine's own
    `def`/`use`/`gen` classification round-trips.
- `test_kinship.py` — the two kinship questions (`similar`, `pairs`/`families`/
  `distinct`) and the multi-pattern sweep (`patterns`/`pattern_counts`), over a
  throwaway corpus. Oracles are independent of the verb's own output.
- `test_retrieval.py` — compression retrieval (`recall`/`pack`/`quote`) over a
  throwaway corpus with a redirected artifact home. Properties, not outputs.
- `test_compose.py` — composed narrowing (`blast`, `provenance`,
  `families(matching=…)`): proves exact + compression answer better together,
  and that `provenance` only attributes phrases the live bytes still hold.
- `test_atlas.py` — the compression lifecycle: `atlas_status`/`atlas_index`
  truthfully decode including the missing-artifact case; a warm answer equals
  cold.
- `test_introspection.py` — typed `status()`/`capabilities()` lifecycle and the
  `--schema` manifest parsing.

## Warm path (needs `gist serve` or `libirregex`)

- `test_session.py` — the persistent UDS session (ADR-352 rung 2.5): pure
  `warm_eligible` classifier, fail-open with no daemon, and a live round-trip
  proving warm answers agree with cold.
- `test_ffi_parity.py` — the in-process cffi transport (rung 3): byte-identical
  to cold subprocess for `run`/`files`/`count`, reconciles writes, and declines
  unsupported patterns to cold rather than aborting. Skips without the library.
- `test_cursor.py` — the warm `Engine`/`Cursor` pull surface: records identical
  to cold, `batches()` chunking, `max_results` budget, `CancelToken`, and typed
  errors for unrepresentable requests. Skips without `libirregex`.

## Cross-language parity

- `test_classify_parity.py` — Python's `warm_eligible` and the Zig daemon's
  `classify` must agree on every request shape (ADR-352 rung 2.5 eligibility
  contract). Drives the real binary with `GIST_TRACE=warm`.

```bash
cd pkg/kernels/irregex/bindings/python && uv run pytest
```
