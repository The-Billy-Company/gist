---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["engine =", "multiline =", "unicode ="]
      description: The documented matcher controls remain canonical request options.
---

# billy-irregex — the importable kernel API

## What it is

The Python face of [irregex](../../README.md), covering Gist's `ripgrep`-parity
search and Relate's corpus kinship operations through one package. Repository
automation imports the kernel once instead of learning binary-specific Python
names or hand-rolling subprocess parsing.

```python
import irregex

for m in irregex.search(r"func\s+\w+\(", paths=["services/backend"]):
    print(f"{m.path}:{m.line_number}: {m.text}")

hits  = irregex.files("TODO", types=["py"])         # files-with-matches (-l)
total = irregex.count("panic", paths=["services"])  # total matching lines
refs  = irregex.search(r"(?<=class )\w+", engine="auto")  # PCRE2 when needed
```

Distribution name is `billy-irregex`; it imports as `irregex`.

## One request shape, at every face

`search()`/`files()`/`count()` are conveniences over `SearchRequest`, the single
shape the CLI, the package, and Billy's agent tool all speak. Build it once and
reuse it — or map it straight from an agent tool payload:

```python
# Billy's fs_search(place, query, glob, context_lines, semantic, at) — or any
# coding-agent search call — is the same actor asking "find these matches here".
req = irregex.request_from_tool({"query": "panic", "glob": "*.go", "context_lines": 2})
#   aliases  : query→pattern, glob→globs, context_lines→context
#   dropped  : place / at / semantic  (transport + ranking = the place adapter's
#              call, NOT GIST's — one semantic API does not require one transport)
matches = irregex.run(req)                 # local place: run it here
#                                        # remote place: forward `req` to the
#                                        # machine/bridge that owns the tree
```

The alias + routing-key map is pinned in the contract
([`contract/search_api.toml`](../../contract/search_api.toml) `[tool_boundary]`)
and parity-tested, so the seam can't drift.

Matching semantics belong in that deep request contract, not in raw argv:
`engine` selects `"linear"`, `"auto"`, or `"pcre2"`; `multiline` and
`multiline_dotall` control cross-line matching; and `unicode=True|False`
explicitly selects Unicode or byte/ASCII semantics across the chosen backend.

## Find, then aggregate

`search`/`files`/`count` answer _where_ a pattern occurs. `summary` answers _how
it is distributed_ — the question an agent asks next — by searching, then
grouping the matches into buckets ranked by count:

```python
hot = irregex.summary("TODO", paths=["services"], by="dir")   # search + aggregate
for g in hot.top(5):
    print(f"{g.count:4}  {g.key}")          # busiest directories first

# which ADRs does the tree cite most? — bucket by the literal that matched
irregex.summary(r"ADR-\d+", by="match").top(10)

# a custom axis is any Callable[[Match], str]
irregex.summary("panic", by=lambda m: m.path.split("/")[0])    # top-level component
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
for r in irregex.rank("SearchRequest", limit=8):
    print(f"{r.count:>3} [{r.kind}]  {r.path}:{r.line_number}")   # def | use | gen

authored = [r for r in irregex.rank("apperr.New") if not r.generated]  # skip codegen
```

Each `Ranked` row carries the engine's own `def`/`use`/`gen` classification
(`RankKind`) — read straight from `--rank`, **never reclassified in Python**, so
"what is generated" can't fork from the engine (`src/rank/signals.zig`). Ranking
uses the persisted index when available and live-ranks the searched files when
it is absent or disabled. `limit` caps the rows (default 20).

## Why it exists

GIST used to be reachable only as a shell reflex (the `gist` CLI). Scripts that
wanted its speed shelled out to `rg` and parsed text. This package gives them —
and Billy's agent code-search tool — **one** request shape (`SearchRequest`) over
**one** engine, per [ADR-352](../../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md).

## How it works

It is a **pure-Python wrapper** over the certified `gist` binary: a
`SearchRequest` lowers into the exact rg-parity argv the CLI accepts, the binary
runs with `--json`, and the JSON-lines stream is parsed into `Match` records — so
results come from the _same_ engine the CLI uses, never a second matcher.

Subprocess is the authoritative transport (ADR-352): a pattern outside the
selected matcher exits the child with code 2 and surfaces as a typed
`UnsupportedPatternError`. Use `engine="auto"` for safe linear-first escalation
or `engine="pcre2"` for explicit PCRE2 JIT.

The binary is resolved at call time: env `GIST_BIN`, then `gist` on PATH, then
the repo's `zig-out/bin/gist`. Build it with `make install-gist`.

## Warm path — persistent `Session` (ADR-352 rung 2.5)

For a many-query caller (doc-radar, a lint pass, an agent loop), a `Session`
keeps a Unix-socket connection to a running `gist serve` daemon warm across
calls, so an eligible query skips the cold subprocess's process + index-mmap +
candidate-read startup entirely:

```python
with irregex.Session() as s:                      # dials $GIST_SESSION_SOCK / the repo default
    s.connect()
    generation = s.generation                 # daemon/session/index identity
    hot   = s.files(irregex.SearchRequest("TODO"))       # -l, warm
    total = s.count(irregex.SearchRequest("panic"))      # -c matching lines, warm
    rich  = s.run(irregex.SearchRequest("TODO"))         # full Match records, warm in-process (FFI)
    cold  = s.run(irregex.SearchRequest("TODO", context=2))  # rich flag → cold subprocess
```

It is **fail-open by construction**: no daemon listening, an ineligible request
(`irregex.warm_eligible(req)` is `False` for scoped roots, globs/types, context, or
any rich flag), or a wire hiccup transparently falls back to the byte-identical
cold subprocess — the daemon is a pure accelerator, never a new failure mode.
The wire protocol is the same one `src/surface/exec/session/protocol.zig` defines and the Zig
CLI + Rust clients speak, so all three frame-match against the one daemon.
`refresh_generation()` reads the daemon's current three-part generation; a
reconnect, daemon restart, or index publication is visible through
`generation_changed`. Sessions are deliberately not thread-safe.

## In-process warm path — cffi (ADR-352 rung 3)

When the host process already holds the shared library and `cffi` (e.g. the AI
service, which depends on `cffi` via the sibling kernels), a `Session`
transparently serves eligible queries **in-process** over the
`irregex_open` / `irregex_search` / `irregex_close` C ABI (`irregex/_ffi.py`
over `libirregex.{dylib,so}`) — no
subprocess or socket. Unlike the UDS transport (files/count only), it streams
full `Match` records, so `Session.run` gains a warm path for the first time;
`files`/`count`/`absent` prefer it too. The ABI-1 options contract carries raw
smart-case, explicit Unicode/ASCII mode, invert-match, context windows, quiet,
and per-file max-count through one size-checked shape. Match records explicitly
identify match versus context; invert records remain matches with zero
submatches, exactly like cold JSON. Explicit `paths` become the C session's root
array, with handles bounded and keyed by `(cwd, roots)` so scopes cannot
cross-contaminate. `engine="auto"` tries this linear FFI path first and falls
through on `IRREGEX_STALE` when PCRE2 is required. Zig remains the sole
case/class authority. Its answer is byte-identical to the cold `gist --json`
stream (records, `-l`, `-c` — a line with repeated hits still counts once),
proven by `tests/test_ffi_parity.py`.

`cffi` is **never required**: `_ffi` fails open to the UDS daemon, then the cold
subprocess, when the library or `cffi` is absent — so the shipped wheel stays
pure-Python and dependency-free. Opt out with `GIST_NO_FFI`; point at a specific
library with `GIST_LIB`. A bad pattern surfaces as a decline (`IRREGEX_STALE`), so
the in-process path can never abort the host — the property rung 3 gated on.

A batch caller need not manage the daemon itself: `irregex.opening_session()`
wraps `irregex.ensure_serve()` (best-effort detached `gist serve` spawn — herd-safe
via the daemon `flock`, opt-out with `GIST_NO_AUTOSERVE`, fail-open to cold) and
yields a connected `Session`. First consumers: the doc-radar `still_here` count
batch prunes tree-absent sentinels with a warm `Session.absent()` before any cold
count, and the codegen/trust lints (`identity`, `fronts`, `boundary_gates`,
`policy`) ride warm rootless `files`/`absent` prefilters. Callers that need
`--hidden`, multi-`-e`, or `--null` records (e.g. `relocator`) stay cold by
design until a hidden-aware daemon rung lands.

## Lifecycle and capabilities

`status()` returns an immutable `IndexStatus`, `index()` builds then returns the
observed status, and `capabilities()`/`schema()` parse the binary-generated
`--schema` manifest into typed, queryable records:

```python
state = irregex.status()
if not state.ready:
    state = irregex.index()

if irregex.capabilities().supports("-P"):
    print("PCRE2 available")
```

## Prior art

Wraps the same engine as `rg` (the tool it is a drop-in for); the request/result
contract mirrors ripgrep's `--json` record stream. The cffi transport
(`irregex/_ffi.py`) follows the sibling kernel bindings' ABI-mode `dlopen` loader
(`lamina`, `principia`, `billog`).
