# billy-gist — the importable search API

## What it is

The Python face of [GIST](../../README.md), Billy's dogfooded, `ripgrep`-parity
code-search kernel. One clean, script-friendly `search()` (plus `files()`,
`count()`, `status()`) that any repository automation can import instead of
hand-rolling `subprocess` argv and output parsing per site.

```python
import gist

for m in gist.search(r"func\s+\w+\(", paths=["services/backend"]):
    print(f"{m.path}:{m.line_number}: {m.text}")

hits  = gist.files("TODO", types=["py"])         # files-with-matches (-l)
total = gist.count("panic", paths=["services"])  # total matching lines
```

Distribution name is `billy-gist`; it imports as `gist`.

## One request shape, at every face

`search()`/`files()`/`count()` are conveniences over `SearchRequest`, the single
shape the CLI, the package, and Billy's agent tool all speak. Build it once and
reuse it — or map it straight from an agent tool payload:

```python
# Billy's fs_search(place, query, glob, context_lines, semantic, at) — or any
# coding-agent search call — is the same actor asking "find these matches here".
req = gist.request_from_tool({"query": "panic", "glob": "*.go", "context_lines": 2})
#   aliases  : query→pattern, glob→globs, context_lines→context
#   dropped  : place / at / semantic  (transport + ranking = the place adapter's
#              call, NOT GIST's — one semantic API does not require one transport)
matches = gist.run(req)                 # local place: run it here
#                                        # remote place: forward `req` to the
#                                        # machine/bridge that owns the tree
```

The alias + routing-key map is pinned in the contract
([`contract/search_api.toml`](../../contract/search_api.toml) `[tool_boundary]`)
and parity-tested, so the seam can't drift.

## Find, then aggregate

`search`/`files`/`count` answer *where* a pattern occurs. `summary` answers *how
it is distributed* — the question an agent asks next — by searching, then
grouping the matches into buckets ranked by count:

```python
hot = gist.summary("TODO", paths=["services"], by="dir")   # search + aggregate
for g in hot.top(5):
    print(f"{g.count:4}  {g.key}")          # busiest directories first

# which ADRs does the tree cite most? — bucket by the literal that matched
gist.summary(r"ADR-\d+", by="match").top(10)

# a custom axis is any Callable[[Match], str]
gist.summary("panic", by=lambda m: m.path.split("/")[0])    # top-level component
```

`by` is a named axis — `"file"` · `"dir"` · `"ext"` · `"match"` — or a callable.
`tally(matches, by=...)` is the pure core: it aggregates any `Match` sequence
you already have (so it composes with `search` and is unit-testable without the
binary), and only `MatchKind.MATCH` lines are counted — `-A/-B/-C` context lines
never inflate a tally. Aggregation is a result-side layer: it does **not** widen
`SearchRequest` (the contract stays match-finding-only) and never runs a second
matcher.

## Which hit matters most — the ranked view

`rank` is gist's one native shape with no rg equivalent: the definition-first
[RRF view](../../README.md#ranking) that puts a symbol's declaration ahead of
its 200 call sites and **demotes generated files** (which the repo forbids
editing, so they're never the target):

```python
for r in gist.rank("SearchRequest", limit=8):
    print(f"{r.count:>3} [{r.kind}]  {r.path}:{r.line_number}")   # def | use | gen

authored = [r for r in gist.rank("apperr.New") if not r.generated]  # skip codegen
```

Each `Ranked` row carries the engine's own `def`/`use`/`gen` classification
(`RankKind`) — read straight from `--rank`, **never reclassified in Python**, so
"what is generated" can't fork from the engine (`src/rank/signals.zig`). Ranking
reads the persisted index, so it needs one built (`make install-gist`); with no
index there is nothing to rank and the result is empty. `limit` caps the rows
(default 20).

## Why it exists

GIST used to be reachable only as a shell reflex (the `gist` CLI). Scripts that
wanted its speed shelled out to `rg` and parsed text. This package gives them —
and Billy's agent code-search tool — **one** request shape (`SearchRequest`) over
**one** engine, per [ADR-352](../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md).

## How it works

It is a **pure-Python wrapper** over the certified `gist` binary: a
`SearchRequest` lowers into the exact rg-parity argv the CLI accepts, the binary
runs with `--json`, and the JSON-lines stream is parsed into `Match` records — so
results come from the *same* engine the CLI uses, never a second matcher.

Subprocess is the authoritative transport (ADR-352): a pattern outside GIST's
linear-time syntax exits the child with code 2 and surfaces as a typed
`UnsupportedPatternError` — it never terminates the host the way an in-process
`die()`/exit would.

The binary is resolved at call time: env `GIST_BIN`, then `gist` on PATH, then
the repo's `zig-out/bin/gist`. Build it with `make install-gist`.

## Warm path — persistent `Session` (ADR-352 rung 2.5)

For a many-query caller (doc-radar, a lint pass, an agent loop), a `Session`
keeps a Unix-socket connection to a running `gist serve` daemon warm across
calls, so an eligible query skips the cold subprocess's process + index-mmap +
candidate-read startup entirely:

```python
with gist.Session() as s:                      # dials $GIST_SESSION_SOCK / the repo default
    hot   = s.files(gist.SearchRequest("TODO"))       # -l, warm
    total = s.count(gist.SearchRequest("panic"))      # --count-matches, warm
```

It is **fail-open by construction**: no daemon listening, an ineligible request
(`gist.warm_eligible(req)` is `False` for scoped roots, globs/types, context, or
any rich flag), or a wire hiccup transparently falls back to the byte-identical
cold subprocess — the daemon is a pure accelerator, never a new failure mode.
The wire protocol is the same one `src/session/protocol.zig` defines and the Zig
CLI + Rust clients speak, so all three frame-match against the one daemon.

## Prior art

Wraps the same engine as `rg` (the tool it is a drop-in for); the request/result
contract mirrors ripgrep's `--json` record stream. The cffi graduation rung
follows the sibling kernel bindings (`lamina`, `principia`, `billog`).
