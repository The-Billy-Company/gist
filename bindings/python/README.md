---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains:
        - "engine ="
        - "multiline ="
        - "unicode ="
        - "[irregex.grades]"
        - "[irregex.lifecycle]"
        - "[compose.verbs]"
      description: The matcher controls, the grade bands, the atlas lifecycle, and the composed verbs all remain contract sections.
    - file: pkg/kernels/irregex/src/surface/cli/grade.zig
      contains: ["pub const Channel = enum", "pub const Grade = enum"]
      description: Kinship calibration has one Zig source, which irregex/grade.py mirrors and tests/test_grade_parity.py reads as its oracle.
---

# billy-irregex — the importable kernel API

## What it is

The Python face of [irregex](../../README.md) — all three engines through one
package: Gist's `ripgrep`-parity **exact search**, Relate's **compression
kinship and retrieval**, and the **composed** verbs that use both at once.
Repository automation imports the kernel once instead of learning
binary-specific Python names or hand-rolling subprocess parsing.

```python
import irregex

# exact — where is this pattern?
for m in irregex.search(r"func\s+\w+\(", paths=["services/backend"]):
    print(f"{m.path}:{m.line_number}: {m.text}")

hits  = irregex.files("TODO", types=["py"])         # files-with-matches (-l)
total = irregex.count("panic", paths=["services"])  # total matching lines
refs  = irregex.search(r"(?<=class )\w+", engine="auto")  # PCRE2 when needed

# compression — what resembles this, and what would explain it?
twins  = irregex.similar("services/backend/api/main.go", min_grade="strong")
to_read = irregex.pack("how does wallet crediting settle").paths

# composed — both engines on one question
radius = irregex.blast("WalletService")             # what moves if I change it
```

Distribution name is `billy-irregex`; it imports as `irregex`.

## This is not the CLI with a Python skin

A terminal reads top to bottom and discards structure; a program wants the
opposite. Where the two differ, this package follows the program:

| The CLI                                | Here                                   | Why it matters                                                                                     |
| -------------------------------------- | -------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Prints a calibration verdict to stderr | `row.grade`, `min_grade=`              | A caller cannot read stderr, and `0.78` looks like a result while meaning "both files are Python". |
| Prints the scored population to stderr | `Kin.scored` / `.warm` / `.elapsed_ms` | "Nearest of three" and "nearest of twenty thousand" are different claims.                          |
| Truncates output to a context budget   | complete result sets                   | A silently trimmed list is a wrong list.                                                           |
| `blast` prints six sections            | `Blast.paths` / `.exact_paths`         | The conclusion under the sections is the edit set.                                                 |
| `family` interleaves two row classes   | `.families` / `.distinct`              | A program wants one class, not a stream to re-sort.                                                |
| Coordinates only                       | `Region.read()`                        | A human goes and looks at the file; a program has to be handed the code.                           |
| Warmth is invisible                    | `atlas_status()`                       | A long-running process decides once, instead of paying a cold walk per call.                       |

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

## Kinship — the questions a regex cannot ask

Exact search answers _where is this string_. The compression engine answers
_what resembles this_, which is what you actually want before writing a helper
that already exists, or when hunting the fork family behind a bug fixed in three
places:

```python
# before extracting a helper: does a near-twin already exist?
if irregex.similar("pkg/tools/support/scan.py", min_grade="strong"):
    ...                                         # extend it, don't fork it

irregex.dups(max_distance=0.15, roots="clients/web")   # copy-paste pairs
irregex.clusters(min_size=3)                           # whole fork families
irregex.echoes(roots="services/backend")               # same skeleton, renamed
irregex.concepts(roots="services/ai")                  # duplicated *functions*
irregex.fragments("retry with exponential backoff")    # nearest functions to an idea
```

`channel=` picks what "near" means — `copies` compares raw bytes, `shapes`
compares normalized structure so a renamed twin surfaces, `twins` ranks by how
much more shape than vocabulary a pair shares, `any` takes whichever sees more.
Every result is a `Kin` sequence: it indexes and iterates like a list, and also
carries the provenance the CLI leaves on stderr — `scored` (the population the
answer was drawn from), `warm` (atlas-served or live), `elapsed_ms`, and
`at_least(grade)` for a second filter without a second process.

`concepts`/`fragments` compare **function fragments** rather than files, so one
duplicated validator inside two otherwise-unrelated modules still surfaces. Their
members are `Region`s — path plus line span plus headline — and `Region.read()`
hands back the source text, because a program needs the code, not coordinates.

## Retrieval — what would explain this?

Given prose, the engine can price which files describe it most cheaply. That is
the context-assembly question, and `pack` answers the set form of it: each pick
is priced by the bits it adds _beyond_ the picks already chosen, so a
near-duplicate of an earlier pick never makes the list.

```python
plan = irregex.pack("how does the resident session reconcile freshness", top=6)
for p in plan:
    print(f"{p.rank}. {p.path}  +{p.marginal_bits:.0f} bits")
plan.coverage, plan.foreign      # how much of the query is explained / unknown here

irregex.recall("fold changed files into a persisted anchor")  # recall, no regex
irregex.quote("const fd = std.posix.openat(")                 # where is this from?
```

`recall` is content recall for when you cannot spell the exact name — run it,
then `search()` the exact symbol it surfaces. `quote` rewrites a text as corpus
quotations priced in bits; `Quotation.novelty` is the share nothing could quote,
and `bits_per_byte` is the corpus-conditional rate (low means the corpus already
knows this text). Quotation reads the codex shelf, so build it first with
`atlas_index(shelf=True)`.

## Composed — both engines on one question

The `irregex` face (ADR-367) narrows the corpus with the exact matcher, then runs
compression **only inside that candidate set**. Exact and statistical evidence
stay in separate fields; there is deliberately no fused relevance number.

```python
radius = irregex.blast("WalletService")       # what moves if I change this?
radius.paths                                  # the edit set, deduped, exact-first
radius.exact_paths                            # only proof, no statistical kin
radius.seed, radius.dependents, radius.dependencies
radius.twins, radius.ripple, radius.comments  # incl. the stale-doc surface
radius.truncated                              # did --budget trim a tail?

# the reading set among files that actually match some intents
irregex.context("wallet crediting", ["WalletService", "credit"], roots="services")

# which implementations are forks of each other — compared as code, not as files
report = irregex.family("func.*Retry", echo_min=0.15, roots="services/backend")
report.families, report.distinct               # two row classes, kept apart

irregex.provenance("pasted snippet")           # citations re-verified against live bytes
```

`blast` is the pre-edit question, and `Blast.paths` is the conclusion the six CLI
sections are evidence for. `family` lifts every exact hit to its **enclosing
function** before comparing, so two unrelated modules sharing one copy-pasted
helper finally surface — and it returns families and unaffiliated implementations
as separate collections instead of one stream to re-sort. `context`/`family`
require a scope (`roots=` or `corpus_wide=True`), refused in Python rather than
as an opaque exit 2, so a composed query can never silently sweep `vendor/`.

## Calibration — a distance is not an answer

`0.78` looks like a result and often means "both files are Python". The kernel
grades every distance against band cut points per channel
([`src/surface/cli/grade.zig`](../../src/surface/cli/grade.zig),
[`contract/search_api.toml`](../../contract/search_api.toml) `[irregex.grades]`),
and the CLI prints that verdict to stderr — where no caller can read it. Here it
is on the row:

```python
for row in irregex.similar("services/ai/tools/code/workshop.py"):
    print(row.grade, row.distance)     # strong 0.19

irregex.dups(min_grade="strong")                     # withheld engine-side
irregex.grade_of("twins", 0.31)                      # Grade.MODERATE
irregex.Grade.MODERATE.meets(irregex.Grade.WEAK)     # True — a floor, not equality
```

`Channel` and `Grade` are `StrEnum`s, so `"strong"` works anywhere a `Grade`
does. `Grade` orders strongest-first and `Channel` knows its own polarity — a gap
channel improves as it _rises_ while a distance channel improves as it _falls_,
which is exactly the inversion a hand-rolled threshold gets wrong.
`tests/test_grade_parity.py` reads the Zig source as its oracle: every tag,
alias, cut point, and polarity is asserted against the kernel, so the mirror
cannot drift.

## Why it exists

GIST used to be reachable only as a shell reflex (the `gist` CLI). Scripts that
wanted its speed shelled out to `rg` and parsed text. This package gives them —
and Billy's agent code-search tool — **one** request shape (`SearchRequest`) over
**one** engine, per [ADR-352](../../../../../docs/architecture/3-decisions/352-gist-unified-search-api.md).

The kinship, retrieval, and composed faces were reachable only as a shell reflex
for the same reason, and they are the worse loss: their answers are _graded and
scoped_, and every one of those qualifiers is a stderr line a subprocess caller
throws away. A script that shelled `relate similar` got a bare float — no band,
no population, no warmth — and had to reinvent the calibration the kernel already
performed. Everything the CLI prints as commentary is a field here.

## How it works

It is a **pure-Python wrapper** over the certified binaries: a `SearchRequest`
lowers into the exact rg-parity argv the CLI accepts, the binary runs with
`--json`, and the JSON-lines stream is parsed into `Match` records — so results
come from the _same_ engine the CLI uses, never a second matcher. The kinship,
retrieval, and composed verbs lower the same way, through `relate` and `irregex`
(`RELATE_BIN` / `IRREGEX_BIN` override, same three-step resolution as
`GIST_BIN`), and additionally parse the last stderr diagnostic record — the
provenance a `Kin`/`Packed` result reports. No analysis is reimplemented in
Python: grades come from the row when the engine emitted one, and the Zig kernel
stays the sole case, class, and calibration authority.

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

The compression face has its own warm tier — the kinship atlas, the function
fragment table, and the codex shelf — and its own report. A long-running process
decides warmth **once** instead of paying a cold corpus walk per call:

```python
state = irregex.atlas_status()
if not state.can_quote:                       # quote/provenance *require* the shelf
    state = irregex.atlas_index(shelf=True)   # every other verb merely prefers it
state.atlas.staleness      # share of the snapshot a warm query will redo live
state.fragments.ready      # concepts/fragments have their own artifact
```

The three artifacts are reported independently because the verbs are: `atlas`
(kinship + composed `family`), `fragments` (`concepts`/`fragments`), and `shelf`
(quotation). Readiness is about **speed, not correctness** — a missing or corrupt
artifact degrades to a live rebuild with byte-identical answers, so warmth is
never a dependency, and `no_index=True` forces live on any kinship verb. The one
exception is the shelf, which `quote`/`provenance` genuinely require; that is
what `can_quote` is for, so it can be preflighted instead of caught.

## Prior art

Wraps the same engine as `rg` (the tool it is a drop-in for); the request/result
contract mirrors ripgrep's `--json` record stream. The cffi transport
(`irregex/_ffi.py`) follows the sibling kernel bindings' ABI-mode `dlopen` loader
(`lamina`, `principia`, `billog`).
