# billy-gist tests

- `test_contract.py` — the `gist.contract` mirror must not drift from the
  canonical `contract/search_api.toml` or the driven binary's version
  (ADR-352). Runs without a binary except the version-parity case.
- `test_search.py` — behavioral tests over a throwaway corpus, plus **rg-parity**
  tests asserting GIST's discovery set is byte-equivalent to ripgrep's. They
  skip cleanly when no `gist` binary is built (`make install-gist`) or no `rg`
  is on PATH.

```bash
cd pkg/kernels/gist/bindings/python && uv run pytest        # or: python -m pytest
```
