# `gist.exact` — pattern search

The ripgrep-parity face: where is this pattern? Request types live in
`irregex.request`; this package consumes them.

| Module | Concern |
|---|---|
| `cursor.py` | `Engine` + `Cursor` — in-process pull cursor and cancel token |
| `aggregate.py` | `tally` / `Group` — bucket matches by an axis |
| `ranked.py` | `rank` — definition-first analytic view |

`SearchRequest` is the only request shape: build one and every transport can
serve it. Options a warm tier cannot express fall through rather than error.
