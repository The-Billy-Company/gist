---
doc_radar:
  occurrences:
    - {file: pkg/kernels/irregex/bench/rgsuite/results.json, pattern: '"bucket": "PASS"', equals: 405}
    - {file: pkg/kernels/irregex/bench/rgsuite/results.json, pattern: '"bucket": "FAIL"', equals: 0}
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
    - file: pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
      contains:
        - "gist vs ripgrep across 12 classes: 12 win · 0 parity · 0 loss"
        - "6.3× geomean end-to-end speedup"
        - "11.4× faster than csearch"
        - "30.4× faster than ripgrep"
---

# Gist — exact code search built for agents

**Status:** shipped product + measured evidence. CLI face:
`src/surface/face/gist/`. Authoritative cold path: `src/surface/exec/cold/`. Public
compatibility contract: `gist --schema` (rendered from
`src/surface/exec/cold/argv/args.zig` `flag_catalog`). Prior art:
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
   irrelevant reads; phantom and content snapshots remove the directory and
   file-open floors; a warm session avoids process and corpus setup; an FFI
   lets tools invoke the same engine in-process.
2. **The useful answer arrives first.** `--rank` lifts likely definitions and
   dense authored matches while sinking generated files, mirrors, deep paths,
   and repeated call-site shapes. Its weighted fusion is tuned for what wastes
   an agent's context. It changes order, never membership.
3. **Rich regex remains indexable when proof permits.** Required literals let
   PCRE2 lookarounds and backreferences use the trigram index; alternation
   covers, SIMD gates, and Crest extend the useful proof surface. Anything
   unproved scans.
4. **Compatibility is a contract, not a resemblance.** The CLI, stdout,
   stderr, Unicode defaults, and exit codes are ripgrep-shaped. `gist --schema`
   states every supported, divergent, ignored, and rejected flag.
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
  → live scope proof
      live walk or clock-proven phantom membership
  → sound candidate proof
      trigram requirements
      + Crest run requirements
      + changed-file freshness overlay
  → verified bytes
      live read or clock-proven content shard
  → hand-tuned matching
      SIMD fixed strings
      + byte-class DFA / Pike VM
      + resource-capped PCRE2
  → optional agent ranking
  → ripgrep-shaped output
```

Each arrow has one authority:

- **The walk owns inclusion.** Gitignore, hidden-file, type, and path rules
  decide what may be searched.
- **The index owns only read-elision.** It can prove a file irrelevant; it
  cannot introduce a file or certify a match.
- **Snapshots own only work-elision.** They may replace a directory listing or
  file open only while live clocks prove their bytes current.
- **The matcher owns truth.** Linear regex, fixed-string, or resource-capped
  PCRE2 executes against current bytes.
- **Ranking owns presentation.** It reorders the complete verified hit set.

This separation is the core safety property. Gist can become faster by adding
better proofs, never by weakening the answer.

The law reaches beyond match candidates. Trigrams and Crest prove files
irrelevant; the phantom walk proves directory membership unchanged; the
content shard proves a mapped body still current. Four different elisions,
one rule: uncertainty returns the work to the live path.

---

## 2. Why it fits an agent

### Search is high-frequency

The index and resident session compound across a work session. The first
query establishes reusable state; later queries pay for the question, not the
repository again. Warm paths remain optional accelerators: if a request shape,
buffer, watcher, or freshness condition is uncertain, they decline to the
authoritative cold path. On both macOS (per-file FSEvents) and Linux (inotify,
whose realpath'd roots note every changed path and arm exactness on
case-sensitive volumes), reconciliation is proportional to the changed set;
non-ASCII paths scope too, resolved through the `realpath` canonicalization
oracle. A queue overflow, an unregistered subtree, or a casefolded Linux root
declines exactness and forces live reconciliation — never a stale answer.

### Context is scarce

Agents do not merely need matches; they need the few lines worth reading.
Bounded context flags retain ripgrep semantics, while `--rank` fuses
declaration geometry, lexical density, shape rarity, path depth, and
authored-vs-generated or mirrored classification through weighted Reciprocal
Rank Fusion. Generated code is deliberately weighted strongly enough to lose
the lexical and declaration advantages its boilerplate creates. The complete
set remains available.

### Tools need a stable surface

One matcher is exposed three ways:

| path                         | job                                                       |
| ---------------------------- | --------------------------------------------------------- |
| cold subprocess              | authoritative answer for the full supported CLI surface   |
| resident UDS session         | warm reusable engine; declines when the request is unsafe |
| in-process FFI (`irregex_*`) | the same engine embedded in another tool                  |

The subprocess is sufficient. The other paths remove overhead without
creating a second definition of search. The resident protocol, eligibility
classifier, shared-memory transport, watcher backends, and FFI statuses are
therefore not parallel products; they are guarded ways to reach the same
answer with less ceremony.

---

## 3. What the work contributes

### New mathematics

**Crest sieve.** A per-document vector of longest runs by byte class is
compared with a regex-AST-derived lower bound on runs every match must contain.
It soundly prunes literal-free class repetitions that substring indexes cannot
express. On the committed narrow-class slate, it turns a trigram blind spot
into a 6.3× geomean end-to-end speedup. The theorem, calculus, count-cousin
ablation, adversarial prior-art review, and corpus proof live in
[`../crest/`](../crest/).

### New boundary

Gist's **systems/workload composition** is original: a ripgrep-shaped local
search tool whose live tree remains authoritative while every faster tier
earns permission to elide work. Index, snapshot, resident, and FFI state can
make an answer cheaper; none can make it true. That boundary is built for an
agent issuing constant, exact queries against a tree changing underneath it.

Against scan-first grep, Gist keeps the familiar exact-search contract while
putting linear and PCRE2-only expressions behind the same candidate index
whenever proof permits. Against csearch and Zoekt, it keeps the live local
tree—not an indexed snapshot—in command; against tgrep, its closest public
shape, every uncertain resident request can decline to a complete cold path.
On the certified warm workload that composition is 11.4× faster than csearch
and 30.4× faster than ripgrep by geomean. It does not claim the hosted scale or
semantic and structural breadth of adjacent systems.

### Hand-tuned craft

Prior art and authorship are not opposites. Gist does not claim to have
invented trigrams, PCRE2, SIMD, watchers, RRF, work stealing, or daemonized
search; it does claim the substantial engineering required to make them behave
as one instrument. The regex lane carries a custom Thompson-to-byte-DFA
compiler, Pike fallback, conservative PCRE2 proof parser, Unicode machinery,
and workload-tuned SIMD/Teddy dispatch. The corpus lane carries compact
postings, generation-atomic persistence, bulk metadata, phantom membership,
content shards, and fused parallel walking. The agent lane carries weighted
ranking, fail-closed watcher reconciliation, a versioned resident protocol,
and a compatibility surface mined against the live ripgrep oracle.

---

## 4. Evidence before adjectives

The tracked differential replay passes all 405 scoreable ripgrep cases on
each independent walk engine with zero in-scope failures. The committed
certificate records statistically gated wins in all 12 registered cold query
classes; its other layers audit port pressure, roofline headroom, candidate
byte touches, the warm tier, and Crest. Operational evaluation keeps lifecycle,
resources, scale, and concurrency separate from query dominance. These are
bounded results, not universal constants: `TESTING.md` owns the evidence map,
and generated artifacts own the numbers.

---

## 5. Contract and boundaries

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
