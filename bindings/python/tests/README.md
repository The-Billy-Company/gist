# billy-irregex tests

- `test_contract.py` — the `irregex.contract` mirror must not drift from the
  canonical `contract/search_api.toml` or the driven binary's version
  (ADR-352). Runs without a binary except the version-parity case.
- `test_search.py` — behavioral tests over a throwaway corpus, plus **rg-parity**
  tests asserting GIST's discovery set is byte-equivalent to ripgrep's. They
  skip cleanly when no `gist` binary is built (`make install-gist`) or no `rg`
  is on PATH.
- `test_aggregate.py` — the result-side `tally`/`summary` layer. The pure cases
  drive synthetic `Match` records with no binary (ranking, tie-break, context
  skip, every axis); the integration cases assert `summary` agrees with the flat
  `search` it derives from.
- `test_rank.py` — the engine's `--rank` view surfaced as `irregex.rank`. The pure
  cases pin the row grammar + `def`/`use`/`gen` parsing with no binary; the
  integration cases build a throwaway index and assert `rank` reads it back with
  the engine's own classification.

```bash
cd pkg/kernels/irregex/bindings/python && uv run pytest        # or: python -m pytest
```
