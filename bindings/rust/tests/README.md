# gist crate tests

The Rust twin of the [Python suite](../../python/tests) — the same behaviors over
the same certified `gist` binary, so both faces prove parity against one engine.

- `contract.rs` — the `gist::contract` mirror must not drift from the canonical
  `contract/search_api.toml` or the driven binary's version (ADR-352). Runs
  without a binary except the version-parity case.
- `search.rs` — behavioral tests over a throwaway corpus, plus **rg-parity** tests
  asserting GIST's discovery set is byte-equivalent to ripgrep's. They skip
  cleanly when no `gist` binary is built (`make install-gist`) or no `rg` is on
  PATH.
- `session.rs` — the persistent resident-session client (ADR-352 rung 2.5): the
  pure `warm_eligible` classifier, fail-open when no daemon is listening, and a
  live round-trip against a spawned daemon that must agree with cold.
- `aggregate.rs` — the result-side `tally`/`summary` layer. The pure cases drive
  synthetic `Match` records with no binary (ranking, tie-break, context skip,
  every axis, a custom `tally_by` axis); the integration cases assert `summary`
  agrees with the flat `search` it derives from.
- `rank.rs` — the engine's `--rank` view surfaced as `gist::rank`. The pure
  row-grammar + `def`/`use`/`gen` parse lives in `src/contract.rs` (the parser is
  crate-private); here the integration cases build a throwaway index and assert
  `rank` reads it back with the engine's own classification.

```bash
cd pkg/kernels/irregex/bindings/rust && cargo test        # skips cleanly without gist/rg
```
