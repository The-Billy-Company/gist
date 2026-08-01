# The `gist` package

Search only. Substrate lives in `irregex`; kinship in `relate`; composed verbs
in `blast`.

| Path | Owns |
|---|---|
| `__init__.py` | `search` / `files` / `count` / `rank` / `summary` and re-exports |
| `exact/` | aggregate, ranked view, warm `Engine`/`Cursor` |
| `index/` | trigram index lifecycle + capabilities |
| `agent.py` | tool-boundary → `SearchRequest` |

Request types (`Match`, `SearchRequest`, …) are imported from `irregex.request`.
Transports and errors come from `irregex.runtime`.
