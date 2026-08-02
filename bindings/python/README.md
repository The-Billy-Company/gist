# gist — the importable search API

Exact search over a tree. Kinship lives in the `relate` package; composed verbs
live in `blast`. This package exposes search and its trigram-index lifecycle
only — importing `gist` does not make relate or blast reachable.

```python
import gist

for m in gist.search(r"func\s+\w+\(", paths=["src/server/api"]):
    print(f"{m.path}:{m.line_number}: {m.text}")

hits = gist.files("TODO", types=["py"])
total = gist.count("panic", paths=["services"])
refs = gist.rank("SearchRequest", limit=8)
```

```bash
pip install gist-search
```

The distribution is `gist-search` but the import stays `gist` — the plain
`gist` name on PyPI belongs to an unrelated author, so installing under it
would fetch a stranger's package (the same bs4 / PIL / cv2 split). It depends
on the `irregex` Python package for the shared substrate (request types, row
protocol, shell / daemon / native transports), which imports as `irgx`.

## Layout

| Path | Owns |
|---|---|
| `gist/exact/` | `SearchRequest` consumers — aggregate, ranked, warm `Engine`/`Cursor` |
| `gist/index/` | trigram index status / build / capabilities |
| `gist/agent.py` | tool-boundary dict → `SearchRequest` |

Shared contract mirrors, the analytic ladder, and binary location live under
`irgx.contract` / `irgx.runtime`.

```bash
cd bindings/python && uv sync --group dev && uv run pytest
```
