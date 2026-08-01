---
doc_radar:
  sentinels:
    - file: ../../contract/surface.toml
      contains: ["[package]", "[transports]", "[tool_boundary]"]
      description: Gist's own surface contract still declares package names, transports, and the tool boundary.
    - file: ../../../irregex/contract/engine.toml
      contains: ["engine =", "multiline =", "unicode ="]
      description: Matcher controls remain engine-contract sections authored by irregex.
    - file: ../../../irregex/contract/analytic.toml
      contains: ["[row_schemas]", "[analytic.verbs]"]
      description: The analytic row plane is substrate and lives with irregex, not with this product.
---

# gist — the importable search API

Exact search over a tree. Kinship lives in the `relate` package; composed verbs
live in `blast`. This package exposes search and its trigram-index lifecycle
only — importing `gist` does not make relate or blast reachable.

```python
import gist

for m in gist.search(r"func\s+\w+\(", paths=["services/backend"]):
    print(f"{m.path}:{m.line_number}: {m.text}")

hits = gist.files("TODO", types=["py"])
total = gist.count("panic", paths=["services"])
refs = gist.rank("SearchRequest", limit=8)
```

Distribution name is `gist`; it imports as `gist`. It depends on the `irregex`
Python package for the shared substrate (request types, row protocol, shell /
daemon / native transports).

## Layout

| Path | Owns |
|---|---|
| `gist/exact/` | `SearchRequest` consumers — aggregate, ranked, warm `Engine`/`Cursor` |
| `gist/index/` | trigram index status / build / capabilities |
| `gist/agent.py` | tool-boundary dict → `SearchRequest` |

Shared contract mirrors, the analytic ladder, and binary location live under
`irregex.contract` / `irregex.runtime`.

```bash
cd bindings/python && uv sync --group dev && uv run pytest
```
