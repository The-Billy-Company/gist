---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/src/surface/exec/cold/engine/serial.zig
      contains: ["used purely to ELIDE reads", "never to change the file set"]
    - file: pkg/kernels/irregex/src/kernel/match/regex/pcre2/literal.zig
      contains: ["pub fn required"]
    - file: pkg/kernels/irregex/src/kernel/rank/signals.zig
      contains: ["pub fn declarationConfidence", "pub fn shapeFingerprint", "pub fn isGenerated"]
    - file: pkg/kernels/irregex/src/kernel/primitives/crest.zig
      contains: ["pub const Vector", "pub fn crest"]
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains:
        - 'subprocess = { status = "authoritative"'
        - 'uds = { status = "operational-accelerator"'
        - 'ffi = { status = "operational-accelerator"'
---

# Gist — exact code search built for agents

**Status:** shipped product + measured evidence. CLI face:
`src/cli/gist/`. Authoritative cold path: `src/runtime/cold/`. Public
compatibility contract: `gist --schema` (rendered from
`src/runtime/cold/argv/args.zig` `flag_catalog`). Prior art:
`PRIOR_ART.md`; evidence inventory: `TESTING.md`. Novel crest math:
[`../crest/PROOF.md`](../crest/PROOF.md).

**Gist is grep rebuilt around the coding-agent loop.** It keeps ripgrep's
familiar command shape and a fail-closed correctness contract, then makes the
repeated operation agents actually perform—locate, inspect, refine, locate
again—fast enough to be a primitive rather than a tax.

---

## 0. The product thesis

Code search for an agent is not one large query. It is dozens or hundreds of
small questions against a tree changing underneath the searcher:

- Where is this symbol defined?
- Which call sites matter?
- Did the rename leave a straggler?
- Can this regex match anywhere at all?
- Which result is authored code rather than generated noise?

The winning tool must make those questions cheap without making stale answers
plausible. That is Gist's purpose: **agent-speed search with the working tree
still in command**.

### What Gist changes

1. **Repeated search becomes a resident operation.** A persisted index avoids
   irrelevant reads; a warm session avoids process and corpus setup; an FFI
   lets tools invoke the same engine in-process.
2. **The useful answer arrives first.** `--rank` lifts likely definitions and
   dense authored matches while sinking generated files, mirrors, deep paths,
   and incidental text. It changes order, never membership.
3. **Rich regex remains indexable when proof permits.** Required literals let
   PCRE2 lookarounds and backreferences use the trigram index. Crest handles
   an important literal-free class. Anything unproved scans.
4. **Compatibility is a contract, not a resemblance.** The CLI, stdout,
   stderr, Unicode defaults, and exit codes are ripgrep-shaped. `gist
--schema` states every supported, divergent, ignored, and rejected flag.
5. **Current bytes always win.** The live walk chooses the corpus. Changed
   files widen candidates. Every survivor is verified against the file now on
   disk.

The result is deliberately boring to call:

```bash
gist 'class Wallet' --rank
gist 'pgxpool\.\w+' services/backend -t go
gist -P '(?<=route\()"/api/[^"]+"' -U
```

The difference is underneath: fewer tree reads, less repeated setup, less
junk placed above the answer, and no permission for an optimization to
manufacture an empty result.

---

## 1. How one query works

```text
argv
  → live scope walk
  → sound candidate proof
      trigram requirements
      + Crest run requirements
      + changed-file freshness overlay
  → current-byte matching
  → optional agent ranking
  → ripgrep-shaped output
```

Each arrow has one authority:

- **The walk owns inclusion.** Gitignore, hidden-file, type, and path rules
  decide what may be searched.
- **The index owns only read-elision.** It can prove a file irrelevant; it
  cannot introduce a file or certify a match.
- **The matcher owns truth.** Linear regex, fixed-string, or resource-capped
  PCRE2 executes against current bytes.
- **Ranking owns presentation.** It reorders the complete verified hit set.

This separation is the core safety property. Gist can become faster by adding
better proofs, never by weakening the answer.

### Two ways to prove a file cannot match

**Required text.** Most patterns imply one or more literals every match must
contain. The trigram index intersects those posting lists before any file
read. Gist extends that proof conservatively into PCRE2: if a literal is not
required across every branch, it is not used.

**Required shape.** Some patterns have no literal at all—`[0-9a-f]{12}` is
the canonical case—but still require a run of a certain byte class. Crest
stores the longest class-runs in each document and proves when that required
shape is absent. Trigrams and Crest are complementary necessary conditions;
neither is a matcher.

---

## 2. Why it fits an agent

### Search is high-frequency

The index and resident session compound across a work session. The first
query establishes reusable state; later queries pay for the question, not the
repository again. Warm paths remain optional accelerators: if a request shape,
buffer, watcher, or freshness condition is uncertain, they decline to the
authoritative cold path.

### Context is scarce

Agents do not merely need matches; they need the few lines worth reading.
Bounded context flags retain ripgrep semantics, while `--rank` fuses
declaration geometry, lexical density, match rarity, path depth, and
generated-code signals. The complete set remains available.

### Tools need a stable surface

One matcher is exposed three ways:

| path                         | job                                                       |
| ---------------------------- | --------------------------------------------------------- |
| cold subprocess              | authoritative answer for the full supported CLI surface   |
| resident UDS session         | warm reusable engine; declines when the request is unsafe |
| in-process FFI (`irregex_*`) | the same engine embedded in another tool                  |

The subprocess is sufficient. The other paths remove overhead without
creating a second definition of search.

---

## 3. What is original

Gist's **systems/workload composition** is original: a ripgrep-shaped local
search tool whose live tree remains authoritative while trigram, Crest,
resident, FFI, and ranking layers optimize the repeated coding-agent loop.

One component makes a stronger algorithmic claim:

- **Crest sieve.** A per-document vector of longest runs by byte class is
  compared with a regex-AST-derived lower bound on runs every match must
  contain. It soundly prunes literal-free class repetitions that substring
  indexes cannot express. The theorem, calculus, adversarial prior-art
  review, and corpus proof live in [`../crest/`](../crest/).

The rest is systems design. Gist does not claim to have invented trigrams,
PCRE2, SIMD scanning, watchers, RRF, or daemonized search. It claims that
their usual boundaries are wrong for an agent making constant, exact queries
against a live local tree—and demonstrates a better boundary.

---

## 4. Contract and boundaries

`gist --schema` is the machine-readable surface. It classifies flags as
supported, supported with documented differences, accepted compatibility
no-ops, or fail-loud refusals. Unicode is default-on; multiline is native;
`-P` selects resource-capped PCRE2. Exit codes remain rg-shaped:

- `0` — at least one match
- `1` — clean search, no match
- `2` — invalid argv, unsupported syntax, unreadable path, or search error

Gist locates text. It does not resolve types or call graphs, perform AST
rewrites, or provide hosted multi-repository governance. Those are adjacent
systems, not failed ambitions.

The differential harness in `TESTING.md` defines current conformance. The
certificate defines recorded performance. If either disagrees with prose,
the artifact wins.

The enduring claim is simple: **search as often as an agent thinks, without
ever teaching speed to impersonate truth.**
