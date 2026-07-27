# gist crate tests

The Rust twin of the [Python suite](../../python/tests) — the same behaviors over
the same certified `gist` binary, so both faces prove parity against one engine.

## Contract (no binary needed)

- `contract.rs` — the `gist::contract` mirror must not drift from the canonical
  `contract/search_api.toml` or the driven binary's version (ADR-352). Runs
  without a binary except the version-parity case.

## Cold subprocess (needs `gist`/`relate`/`irregex` binary)

- `search.rs` — behavioral tests over a throwaway corpus, plus **rg-parity** tests
  asserting GIST's discovery set is byte-equivalent to ripgrep's. Skips without
  `gist` or `rg` on PATH.
- `aggregate.rs` — the result-side `tally`/`summary` layer. Pure cases (synthetic
  matches, no binary) + integration cases asserting `summary` agrees with `search`.
- `rank.rs` — the engine's `--rank` view. Pure row-grammar parse (crate-private);
  integration cases build a throwaway index and assert the engine's own
  `def`/`use`/`gen` classification round-trips.
- `analytic.rs` — the seventeen analytic verbs end-to-end (ADR-377): planted
  corpus, real binaries, expectations from `[row_schemas]`/`[irregex.grades]`
  rather than from captured output.

## Warm path (needs `gist serve` or `--features native`)

- `session.rs` — the persistent resident-session client (ADR-352 rung 2.5): pure
  `warm_eligible` classifier, fail-open with no daemon, and a live round-trip
  proving warm agrees with cold.
- `cursor.rs` — the in-process `Engine`/`Cursor` (`--features native`):
  byte-identical to cold, `batches()` chunking, `max_results` budget,
  `CancelToken`, typed errors for unsupported patterns. Skips without `gist`.

```bash
cd pkg/kernels/irregex/bindings/rust && cargo test                   # cold (skips without gist/rg)
cd pkg/kernels/irregex/bindings/rust && cargo test --features native # + in-process cursor
```
