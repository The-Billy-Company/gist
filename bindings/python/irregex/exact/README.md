# `irregex.exact` — pattern search

The `ripgrep`-parity face: _where is this pattern?_ One request shape lowers into
whichever transport can serve it, and the answer is byte-identical either way.

| Module         | Concern                                                                                                |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| `request.py`   | `SearchRequest` (the one request shape), `Match`/`Submatch`, `Ranked`, and the match/rank vocabularies |
| `cursor.py`    | `Engine` + `Cursor` — the in-process pull cursor and its cancel token                                  |
| `aggregate.py` | `tally`/`Group` — bucketing matches by an axis, so a sweep answers in one pass                         |
| `ranked.py`    | `rank` — the definition-first view, the one exact verb whose answer is analytic rows                   |

`SearchRequest` is deliberately the _only_ request type in the package: a caller
that can build one can reach every transport, and an option the warm tiers cannot
express becomes a fall-through rather than an error.

`rank` is the odd member. It answers a question `grep` cannot ask — _which file
defines this?_ — and its rows carry the engine's own `def`/`use`/`gen` class.
Because the human view has no `--json`, the fallback rung scrapes the rendered
block; the rows it produces go through the same schema decoder the in-process
plane feeds, so the two tiers cannot disagree about what a row means.
