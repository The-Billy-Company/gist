# gist tests

Contract-only, cold subprocess, warm session/FFI, and cross-language parity —
each skipping cleanly when its prerequisite is absent. Kinship, retrieval,
atlas, compose, and row-decoder suites live with the packages that own them
(`relate`, `blast`, `irregex`).

```bash
cd bindings/python && uv run pytest
```
