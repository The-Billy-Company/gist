# gist - indexed code search for Python

Exact regex search over a working tree, with ripgrep's semantics and a
persisted trigram index underneath. Same ignore precedence, same match
semantics; the index just proves most files cannot match before anything opens
them, and every survivor is checked against current bytes.

```bash
pip install gist-search
```

The distribution is `gist-search` but the import stays `gist`. The plain `gist`
name on PyPI belongs to an unrelated author, so installing under it would fetch
a stranger's package; this is the same bs4 / PIL / cv2 split.

This package is the bindings, not the engine: every verb answers by running the
`gist` binary, so that has to be on `PATH` (or `$GIST_BIN`). Without it the
first call raises `GistNotFoundError` rather than failing quietly. See
[what it needs](#what-it-needs).

```python
import gist

for m in gist.search(r"func\s+\w+\(", paths=["src/server/api"]):
    print(f"{m.path}:{m.line_number}: {m.text}")

hits = gist.files("TODO", types=["py"])
total = gist.count("panic", paths=["services"])
refs = gist.rank("SearchRequest", limit=8)
```

`rank` is the one with no grep equivalent: it puts a symbol's definition above
its two hundred call sites and sinks generated files below authored ones, which
is the shape you want when the best hit matters more than every hit.

This package exposes search and its trigram-index lifecycle only. Kinship lives
in [`relate-search`](https://pypi.org/project/relate-search/) and the composed
verbs in [`blast-search`](https://pypi.org/project/blast-search/); importing
`gist` does not make either reachable. It depends on the
[`irregex`](https://pypi.org/project/irregex/) Python package for the shared
substrate (request types, row protocol, shell / daemon / native transports),
which imports as `irgx`.

## What it needs

The `gist` binary on `PATH` (or `$GIST_BIN`), which
[the repository](https://github.com/The-Billy-Company/gist) builds with
`zig build`. No index is required; without one gist scans the live tree and
returns the same answers, just slower.

## Layout

| Path | Owns |
|---|---|
| `gist/exact/` | `SearchRequest` consumers — aggregate, ranked, warm `Engine`/`Cursor` |
| `gist/index/` | trigram index status / build / capabilities |
| `gist/agent.py` | tool-boundary dict → `SearchRequest` |

Shared contract mirrors, the analytic ladder, and binary location live under
`irgx.contract` / `irgx.runtime`.

## The rest of the family

| Package | Question |
|---|---|
| **`gist-search`** | where is this exact pattern? |
| [`relate-search`](https://pypi.org/project/relate-search/) | what resembles this, and what repeats? |
| [`blast-search`](https://pypi.org/project/blast-search/) | what breaks if I change this symbol? |
| [`irregex`](https://pypi.org/project/irregex/) | the linear-time regex engine underneath all three |

## Development

```bash
cd bindings/python && uv sync --group dev && uv run pytest
```
