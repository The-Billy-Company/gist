---
doc_radar:
  counts:
    - description: "the relate face: dispatch shell, five verb drivers, lifecycle, the verb table, shared options/units/kinship plumbing"
      glob: pkg/kernels/irregex/src/surface/face/relate/*.zig
      unit: files
      equals: 11
  occurrences:
    - description: "the verb table declares exactly seven verbs, each owning its handler"
      file: pkg/kernels/irregex/src/surface/face/relate/repertoire.zig
      pattern: '\.run = '
      equals: 7
    - description: "four retired names still coach to the verb that absorbed the question"
      file: pkg/kernels/irregex/src/surface/face/relate/repertoire.zig
      pattern: '\.because = '
      equals: 4
  sentinels:
    - description: "the two kinship questions are one probe verb and one repetition verb"
      file: pkg/kernels/irregex/src/surface/face/relate/repertoire.zig
      contains:
        - "probe.runSimilar"
        - "repeat.runEchoes"
    - description: "the repetition verb is configured on three axes, not split into four verbs"
      file: pkg/kernels/irregex/src/surface/face/relate/options.zig
      contains:
        - "unit: Unit = .file"
        - "channel: Channel = .copies"
        - "shape: Shape = .pairs"
    - description: "the binary is its repertoire and nothing else — the process is rendered too"
      file: pkg/kernels/irregex/src/surface/face/relate/main.zig
      contains:
        - "manifest.drive("
        - "relate_repertoire.face"
    - description: "help, --schema, dispatch, the verb list, and the process all render from the one table"
      file: pkg/kernels/irregex/src/surface/cli/manifest.zig
      contains:
        - "pub fn dispatch("
        - "pub fn usage("
        - "pub fn schema("
        - "pub fn drive("
    - description: "the verbs are contract-documented, not CLI folklore"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: "[irregex.verbs]"
    - description: "the warm tier is contract-documented too"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains: "[irregex.lifecycle]"
---

# relate: compression-as-search

## What it is

`relate` came from the question after Gist. If text is bits, and compressors
give repeated structure a shorter description, could I stop before producing
one compressed blob and return the things that share that structure instead?
That is compression as search.

Where `gist` asks _"where is this exact pattern?"_, `relate` handles the
set-shaped questions beside it: _what is this thing like, what repeats in here,
which files cover a topic together, and where did this pasted text come from?_

There are exactly **two kinship questions**, and the surface now says so.
`similar` is the **neighbor verb**: one probe, one ranked answer. `echoes` is the
**repetition verb**: no probe, a survey of the corpus against itself. Everything
that used to be a separate verb — `search`, `dups`, `clusters`, `concepts` — was
a _corner_ of one of those two, reached by a flag rather than a name. Five query
verbs and two lifecycle verbs now tell the whole story
([ADR-363](../../../../../../../docs/architecture/3-decisions/363-irregex-primitives.md)):

The positive product thesis, the mathematical ancestry, and the falsification
record are kept separately in
[`CLAIM.md`](../../../../research/relate/CLAIM.md),
[`PRIOR_ART.md`](../../../../research/relate/PRIOR_ART.md), and
[`TESTING.md`](../../../../research/relate/TESTING.md). This README explains the
shipped instrument; the dossier explains why compression earns each verb.

```text
relate similar <path | path#Lnnn | text>
               [--as copies|twins|shapes|any] [--unit file|function]
               [--matching PAT]... [--min-grade G]
               [--top N] [--json] [--no-index] [ROOT...]
    THE NEIGHBOR VERB — one probe, one ranked answer. The probe's own
    shape picks the question:
      a PATH scores compression kinship against every other unit;
      `path#Lnnn` scores the FUNCTION containing that line (and adopts
        --unit function and the shapes channel, because a 40-line body
        cannot fill an LZ78 dictionary the way a file can);
      bare TEXT scores coding gain — recall, "which files describe this
        most cheaply" — unless --as names a kinship channel, which turns
        the same text into a record to compare against.
    Ranking always returns rows, so each one is graded and a
    background-only answer says so on stderr instead of looking like a find

relate echoes  [--unit file|function|match] [--as copies|twins|shapes|any]
               [--shape pairs|families|distinct]
               [--max-distance T] [--min-echo E] [--min-size N]
               [--min-lines N] [--min-mass N] [--include-generated]
               [--matching PAT]... [--min-grade G]
               [--top N] [--brief] [--json] [--no-index] [ROOT...]
    THE REPETITION VERB — no probe: the corpus against itself, along
    three independent axes.
      --unit   what a row IS            file · function · match
      --as     which repetition         copies · twins · shapes · any
      --shape  what the answer is FOR   pairs · families · distinct
    The default (`file`, `twins`, `pairs`) is the DRY signal byte kinship
    cannot see: far apart in bytes, close in structure. Corners of the
    same cube are the four verbs this absorbed — `--as copies` is
    verified near-duplicate pairs, `+ --shape families` is their
    transitive closure, `--unit function --shape families` is the same
    idea cloned across files, and `--shape distinct` inverts the whole
    question into "what has no kin at all?"

relate pack <text> [--matching PAT]... [--match any|all] [-F] [-i]
            [--top N] [--json] [ROOT...]
    the SET of files that jointly describes <text> cheapest; greedy
    max-coverage over corpus-priced query chunks; each pick priced by the
    bits it ADDS beyond the picks before it (anti-redundant context
    assembly). With --matching, novelty is priced INSIDE the exact filter
    and every pick names the patterns that admitted it

relate quote <text>   [--json]
    rewrite <text> as maximal verbatim quotations from the WHOLE corpus,
    priced in bits; the Ziv–Merhav cross-parse on the persisted codex
    shelf is O(|text|) after load; CLI latency also includes loading the
    shelf and checking filesystem freshness

relate patterns -e P [-e P…] [-f FILE] [-F] [-i]
                [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]
    ONE walk, N patterns, exact per-pattern attribution, shaped
    engine-side (--by groups, --under filters, --top limits)

relate index [--shelf]     build + persist the kinship atlas (and, with
                           --shelf, the codex shelf quote reads)
relate status [--json]     atlas + shelf readiness and freshness
```

### The names that folded

Four verbs are gone as names and intact as questions. Typing one is not an
unknown-command error — it exits 2 with the invocation that answers it:

| was               | is now                                                       |
| ----------------- | ------------------------------------------------------------ |
| `search`          | `relate similar <text>`                                      |
| `dups`            | `relate echoes --as copies`                                  |
| `clusters`        | `relate echoes --as copies --shape families`                 |
| `concepts`        | `relate echoes --as shapes --shape families --unit function` |
| `irregex context` | `relate pack --matching PAT`                                 |
| `irregex family`  | `relate echoes --matching PAT`                               |

The last two are the composition fold: exact-then-compression is a **modifier**
(`--matching`) on the questions relate already asks, not a parallel binary of
its own ([ADR-367](../../../../../../../docs/architecture/3-decisions/367-composed-irregex-cli.md)).
`irregex` keeps only the two verbs that are genuinely new compositions rather
than a filtered relate query — `provenance` and `blast`.

Plus the conventions every irregex face keeps: `--help` / `--version` /
`--schema` (JSON capability manifest), results on stdout (`--json` = NDJSON),
diagnostics on stderr, unknown verbs exit 2.

## Ergonomics: ask the question, then choose the verb

Relate is the native lane of irregex. It does not preserve grep syntax because
these are not grep-shaped questions. Its ergonomic contract is instead one
question per verb, with a small shared vocabulary for scope, result count,
machine output, and acceleration.

| If your reflex is to…                              | What you actually want                      | Native Relate choice                             |
| -------------------------------------------------- | ------------------------------------------- | ------------------------------------------------ |
| search several vague terms and inspect every hit   | files that best explain some text           | `relate similar TEXT`                            |
| collect a top-K list and deduplicate it by hand    | a non-redundant context set                 | `relate pack TEXT`                               |
| ask where a pasted passage came from               | corpus-attributed verbatim provenance       | `relate quote TEXT`                              |
| diff one file against many candidates              | nearest units to one known unit             | `relate similar PATH`                            |
| ask whether a helper you are about to write exists | nearest FUNCTIONS to this one               | `relate similar PATH#Lnnn`                       |
| compare likely duplicate files                     | verified near-duplicate pairs               | `relate echoes --as copies`                      |
| reconnect duplicate pairs yourself                 | complete fork families                      | `relate echoes --as copies --shape families`     |
| miss renamed copy-paste with byte similarity       | shared structure under different vocabulary | `relate echoes` (the default)                    |
| find the same FUNCTION duplicated across files     | function-level families                     | `relate echoes --unit function --shape families` |
| audit what is genuinely one-of-a-kind              | the complement of every family              | `relate echoes --shape distinct`                 |
| grep first, then reason inside the hits            | compression scoped to an exact filter       | `… --matching PAT`                               |
| run N independent exact searches                   | one attributed walk for N patterns          | `relate patterns -e A -e B …`                    |

### The default move

For humans and coding agents:

1. Decide whether you have a **probe** or not. One thing whose neighbors you
   want is `similar`; the corpus against itself is `echoes`. That single
   question picks the verb, and everything after it is a flag.
2. For `echoes`, name the three axes in the order you actually think in: what a
   row IS (`--unit`), which repetition you mean (`--as`), and what you will DO
   with the answer (`--shape` — `pairs` to inspect, `families` to act on,
   `distinct` to audit the complement).
3. Pass roots positionally to constrain corpus work. Use `--top N` to bound
   human output and `--json` when another tool or agent will consume records.
4. Let the atlas accelerate kinship verbs. Use `--no-index` only as the live
   differential oracle, `relate status` to inspect freshness, and
   `relate index --shelf` when you want both the warm atlas and quotation
   shelf.
5. Read each score in its own direction — and let the **grade** do it for you.
   Lower distance is closer (`copies`/`shapes`/`any`); higher is stronger for
   the `twins` gap and for `recall` coding gain; `pack` reports the marginal
   bits each new choice contributes. Every row carries the band for its own
   polarity, so you never have to remember which way a number runs.

### Niche choices that change the question

- **A path probe versus a text probe:** the same verb, two different
  measurements, chosen by what you handed it. A path is a **record** — it has
  bytes and a skeleton, so it is compared, and the answer is a distance. Bare
  text is a **query** — prose has no skeleton to compare, so a structural number
  over it would be a number about nothing; it is priced instead by coding gain
  against the corpus. Naming `--as` on text overrides that and says "no, treat
  this snippet as a record": legitimate when you paste code and want to know
  what is shaped like it.
- **A fragment probe adopts the channel its scale supports:** `path#Lnnn` moves
  the unit to `function`, and with no explicit `--as` also moves the channel to
  `shapes`. Measured on this corpus, a function's nearest **byte** neighbor sits
  at ~0.81 — grade `none`, indistinguishable from background — while its nearest
  **silhouette** neighbor sits at 0.52 and is the sibling implementation the
  reader was looking for. A 40-line body cannot fill an LZ78 dictionary the way
  a file can, so normalizing identifiers away is what leaves any signal at all.
- **Ranking versus a survey versus a set:** `similar` ranks candidates
  independently against one probe. `echoes` has no probe — it surveys the corpus
  against itself. `pack` chooses a _set_ whose members pay only for information
  not already covered by earlier picks. Use `pack` for context assembly, and
  `similar` when independent rank is the desired output.
- **One channel vocabulary:** every kinship verb reads the same `--as`
  channel. `copies` (the default) respects vocabulary and finds copy-paste
  drift; `shapes` normalizes identifiers, numbers, strings, and comments so
  renamed twins surface; `twins` ranks the gap between those two, which is the
  `echoes` signal; `any` accepts whichever channel sees the stronger kinship.
  The metric names `bytes`/`structure`/`echo`/`fused` remain accepted as
  `--lens` aliases — they are spellings of the same enum, not a second path.
  `recall` is the one channel a flag cannot name: it is chosen by handing the
  verb text instead of a path, because asking a file to be a query is a category
  error dressed as a flag.
- **Grades, so background never reads as a hit:** ranking verbs always return
  rows, which is why an answer with no real kin used to look exactly like a
  find. Every score is now banded (`identical`/`strong`/`moderate`/`weak`/
  `none`) against the thresholds this README documents, the band rides each
  `--json` row, `--min-grade G` withholds anything weaker than `G`, and an
  answer that is entirely background explains itself on stderr in gist's hint
  grammar (`GIST_HINTS=0` mutes it). A trimmed but genuine answer reports what
  it withheld without recanting the finding.
- **Pairs, families, and the complement:** `--shape pairs` (with
  `--max-distance T`, or `--min-echo E` on the gap channel) verifies nominated
  pairs at or past a threshold. Seed buckets are probabilistic and capped, so
  this guarantees emitted-pair precision, not exhaustive recall. `--shape
families` returns the transitive components of that emitted graph — the unit a
  restructure sweep actually acts on — and admits `--min-size N`; a family is
  graded by its **loosest** edge, so one weak link cannot hide inside a strong
  cluster. `--shape distinct` inverts the whole question: the units with no
  admitted edge, each carrying its nearest miss as the receipt for why it is
  alone. The default channel stays the `twins` gap rather than pretending
  structure has one universal duplicate threshold.
- **Noise floors are per-unit, not per-verb:** a survey applies a mass floor
  (files too small to fingerprint would otherwise pair with each other at
  distance 0, since two empty sketches really are identical) and, at
  `--unit function`, a line floor. Generated files are withheld from surveys by
  default — a codegen tree is _supposed_ to repeat, and left in it drowns every
  authored finding — and `--include-generated` turns that back into the question
  ("did the generators drift?"). A probe keeps generated candidates, because
  "what resembles this" has a legitimate generated answer.
- **Pattern attribution:** `patterns` preserves which pattern hit which line.
  Use repeated `-e`, `-f FILE`, `-F`, and `-i` for matching; `--by pattern|file`
  groups counts, `--under GLOB` filters paths, and `--top N` limits results
  engine-side.
- **Quotation requires the shelf:** `quote` reads the whole persisted codex,
  not a root-scoped live corpus. Build it with `relate index --shelf`; a stale
  shelf is reported rather than silently treated as current.
- **Exact first, compression inside (`--matching`):** every query verb takes
  repeated `--matching PAT` (plus `--match any|all`, `-F`, `-i`). The exact
  engine narrows the corpus to a typed candidate set, and the compression
  question is then asked **only inside that subset** — so the statistics are
  priced against the files that matched rather than against 20k strangers, and
  each pick can name the patterns that admitted it. This is the whole of what
  the retired `irregex context` / `irregex family` verbs did; composition is a
  modifier, not a second binary.
- **Warm coverage is verb-specific:** a text probe and `pack` nominate from
  Gist's mmap-backed trigram codebook, then fold changed files through the same
  freshness overlay; every kinship question reads the kinship atlas (and, at
  `--unit function`, the parallel fragment atlas). Narrow explicit kinship
  scopes rebuild live when that is cheaper than loading the global atlas.
  Missing or corrupt acceleration changes cost, never results.
- **Corpus admission is shared with Gist:** positional roots, nested
  `.gitignore` / `.ignore` / `.rgignore` precedence, hidden-file exclusion,
  and freshness admission all use the same corpus-layer matcher. Relate adds
  only the corpus-specific VCS/build skip list.
- **Scores are honest at the boundary:** a negative recall score means the
  candidate describes the text worse than cold encoding, not an error.
  `pack` reports foreign fingerprints instead of pretending the corpus covered
  them, and `quote` prices unknown text rather than forcing attribution.
- **Deterministic machine use:** `--json` emits NDJSON on stdout while
  diagnostics stay on stderr. Pair, family, and pattern outputs have stable
  orderings, so agents should parse records instead of scraping prose.

The checked-in [`search_api.toml`](../../../../contract/search_api.toml) is the
versioned verb contract. The sections below explain the math, corpus policy,
and evidence behind each choice.

This directory is only the face. `repertoire.zig` declares the verb surface
once — each row carrying its usage form, its human blurb, its machine summary,
its typed flags, and the handler that runs it — and
[`surface/cli/manifest.zig`](../../cli/manifest.zig) renders `--help`,
`--schema`, the dispatch, the unknown-verb line, **and the process itself**
from that one table. So `main.zig` holds no surface at all: it names its
repertoire and hands over. The work lives in five sibling drivers — `probe.zig`
(the neighbor verb) · `repeat.zig` (the repetition verb) · `pack.zig` ·
`quote.zig` · `attribute.zig` — plus `lifecycle.zig`, over three shared layers
that exist precisely because the two kinship verbs used to duplicate them:
`options.zig` parses one flag vocabulary into one `Opts`, `units.zig` resolves
any `unit × warmth × optional exact filter` into one comparison table, and
`kinship.zig` holds the parallel fingerprinting and pair machinery. Scoring,
sorting, grading, and the closing verdict are shared through
[`surface/cli/grade.zig`](../../cli/grade.zig)'s `Sift`, so a verb contributes
only its question. The engines live under
[`src/kernel/kinship/`](../../../kernel/kinship/README.md)
(sketch · silhouette · concepts · lexicon · zipper),
[`src/kernel/batch/`](../../../kernel/batch/README.md)
(patterns · loom), [`src/corpus/index/codex/`](../../../corpus/index/codex/README.md) (the
FM-index shelf behind `quote`), and
[`src/corpus/index/atlas/`](../../../corpus/index/atlas/README.md) (the persisted kinship
atlas behind the warm verbs).

## The warm tier: why relate is an engine, not a shim

I persist one LZJD sketch (~1 KiB) and one structure silhouette (~2 KiB) per
corpus file into the **kinship atlas**. Then a broad `similar` or `echoes` query
can read the compressed view instead of re-reading the corpus; narrow explicit
scopes take the cheaper live path. A text probe and `pack` reuse Gist's
persisted trigram codebook for nomination and read only a bounded exact-decider
pool. `--unit function` reads a parallel **fragment atlas** (`concepts.frag`):
one structural silhouette per function fragment, folded for freshness the same
way, so function-level questions answer warm too — byte sketches are the only
live read there, and only for the fragments a byte-bearing channel actually
nominates. The committed contract is useful current-byte answers, not a timeless
speed ratio: measure both rungs on the corpus and machine you care about.

I keep the same covenant as Gist: an index is an accelerator, never an
authority. Queries fold in every file changed since the build anchor, emitted
rows are checked against deletion, and `--no-index` or missing/corrupt state
falls back to live work. The recall path's exact decider sees bounded windows
around the query evidence rather than constructing suffix automata over
multi-MiB files, so top-K latency is bounded by query and evidence-pool size
instead of the total corpus byte count.

## Why these verbs

I kept watching agents rebuild the same workflows outside the engine. Each verb
pulls one of those loops into the kernel. Two of these were once four verb names
apiece; the question each answers is unchanged, so the argument for it is kept
under the name that now carries it:

- **`patterns`** collapses the N-run loop. The fused alternation is a
  skip-only gate; it cannot by itself satisfy the real contract: a
  `PatternSet` answer must equal N independent Gist runs bit for bit, with the
  prefilter forced both on and off. `patterns_test.zig` gates exactness;
  `bench/races/multipattern.sh` is an ad hoc throughput race, not a committed
  performance certificate.
- **`pack`** answers a question independent top-K does not: ranked lists can
  surface near-duplicates together, so an agent pays for the same information
  K times. Coverage over corpus-priced query chunks is submodular, so the
  greedy sweep is a (1−1/e)-approximation for that objective
  (Nemhauser–Wolsey–Fisher 1978) and emits exact marginal-bit receipts.
  Set-aware RAG is prior art too; Relate's distinction is the model-free,
  auditable bit objective.
- **`similar`** makes kinship a primitive instead of a per-tool hack: hand it
  one thing, get its neighbors. Byte kinship has no parser or language registry;
  the structure channel adds one pan-language token squint rather than
  per-language ASTs. Folding retrieval into it was not tidying — a text probe and
  a path probe are the _same_ request ("what in this corpus is near this?") over
  two kinds of probe, and keeping them as two verbs meant an agent had to know
  which noun it held before it could ask.
- **`echoes`** is the survey shape of that primitive, and the reason it is one
  verb rather than four is that `dups`, `clusters`, and `concepts` were never
  different questions — they were the same comparison with a different unit, a
  different channel, and a different output shape. Naming them separately forced
  the caller to know which corner had been given a name (there was no
  `--unit function --shape pairs` verb at all, though the question is perfectly
  sensible), and it duplicated the score-sort-grade-emit-report flow four times:
  `echoes.zig` and `similar.zig` sat at a 0.2180 structural gap — the second
  widest in this directory — which is precisely that shared flow measured from
  the outside. Its default channel reports what neither raw channel can say
  alone. Byte kinship calls a renamed twin unrelated; structure distance alone
  has no clean absolute threshold (measured: family-max vs cross-min overlap at
  every winnow setting). The _difference_ — `echo = bytes − structure` — is
  self-calibrated per pair: high echo means "far more shared shape than shared
  vocabulary," the Type-2 clone an abstraction should collapse. The structure
  channel is MOSS-style winnowed shingles over a normalized token stream
  (identifiers→I, numbers→N, strings→S, comments dropped, pan-language keywords
  kept) — one language-agnostic squint, not a per-language parse.
- **`--unit function`** drops kinship from the file to the FUNCTION. Files answer
  "what forked from what?"; the finer question an agent asks is "which functions
  across the tree are the same idea — the repeated engine, the duplicated JSON
  dump, the copy-pasted validator — regardless of name or file?" The comparison
  unit becomes the function fragment (`regions.extractAll` over authored
  brace-family + Python source), so a helper cloned into six files surfaces as
  one six-member family instead of hiding in six unrelated files. It reuses the
  same channels, the same seed-nomination and union-find pass, and the same
  warm-fold discipline — over the fragment atlas rather than the file atlas.
  Families are ranked by conservative repeated-line opportunity, never a fused
  similarity number, and the channels stay side by side so the reader judges the
  relation.
- **`quote`** is the corpus-global tier: text the corpus knows quotes at
  **0.14–0.17 bits/byte**, foreign bytes at **12.65–15.16** in the committed
  scale table—an **88–94×** separation. Each phrase is attributed to an
  exemplar file, with query work linear in text length
  (`zig build codex-scale`, tables in
  [`src/corpus/index/codex/README.md`](../../../corpus/index/codex/README.md)).
- **the `recall` channel** is the retrieval shape of the same idea, and it lives
  inside `similar` because that is the same request with a query for a probe:
  rank files by how cheaply each would describe the text, two-stage so the exact
  (expensive) decider only prices nominated candidates.
- **`--matching`** is the composition ([ADR-367](../../../../../../../docs/architecture/3-decisions/367-composed-irregex-cli.md)).
  A hand-rolled `gist -l | relate …` pipe throws the match information away
  between the two steps and then pays whole-corpus statistical noise on a subset;
  narrowing inside the kernel keeps the exact and statistical scores in separate
  fields, prices novelty against the candidate set, and lets each row name the
  patterns that admitted it. Composed verbs of their own turned out to be the
  wrong shape for this: `context` was `pack` narrowed and `family` was `echoes`
  narrowed, so both are now the flag.

## Evidence status

The proof strength is intentionally uneven and visible:

| claim                                   | authority                                  | status                                |
| --------------------------------------- | ------------------------------------------ | ------------------------------------- |
| `patterns` equals N solo Gist runs      | `patterns_test.zig` with prefilter on/off  | gated                                 |
| both prefilter tiers equal that oracle  | `trawl_test.zig` + arm 1 forcing each tier | gated (dragnet and trawl, at every N) |
| `patterns` answers the `gist -l` corpus | `bench/gates/patterns_corpus_parity.sh`    | gated (index armed and stripped)      |
| warm atlas equals `--no-index`          | atlas fold/deletion tests                  | gated                                 |
| quote scale and bit separation          | `zig build codex-scale` + codex tables     | committed measurement                 |
| compression versus semantic embeddings  | `zig build relate-knn`                     | rerunnable comparative harness        |
| warm latency                            | local comparison only                      | no committed timing artifact          |
| echo ranking quality                    | heuristic + unit properties                | no checked-in labeled evaluation      |

The durable test inventory is
[`research/relate/TESTING.md`](../../../../research/relate/TESTING.md). Numbers
without a committed artifact do not become product guarantees.

## Corpus policy: read this before comparing to `gist`

I make two deliberate choices here, both documented at the seam:

- **relate analytics read the INDEX corpus** (every non-binary file under
  the roots minus VCS/build subtrees, the same wider-than-gitignore policy
  `gist index` uses), because they are corpus analytics, not per-file greps.
  `gist <pattern>` keeps the rg-parity gitignore walk. The two file sets are
  intentionally not identical (`verbs.zig` header).
- **`quote` reads the persisted shelf** (`relate index --shelf`, the same
  artifact `gist codex build` writes; one shelf, two product faces), not a
  per-invocation build: a cross-parse is only corpus-global if the index
  actually spans the corpus, and an FM-index build is a lifecycle event, not
  a query cost. Staleness is reported on stderr the same way `gist codex`
  reports it (`quote.zig` header).

## Research claim and prior art

I did not invent the math. The central spark was Benedetto, Caglioti, and
Loreto's
[_Language Trees and Zipping_](https://doi.org/10.1103/PhysRevLett.88.048702)
(Phys. Rev. Lett. 2002): use compressor-defined relative entropy to measure how
well one text's language describes another. That paper turned compression from
storage into comparison for me.

The positive case for files, sets, families, and provenance lives in
[`CLAIM.md`](../../../../research/relate/CLAIM.md). The full citation trail—LZJD,
winnowing/MOSS, Ziv–Merhav, FM-indexes, submodular selection, and the
neighboring systems we measured and left—lives in
[`PRIOR_ART.md`](../../../../research/relate/PRIOR_ART.md). Exactness, atlas
identity, the embedding boundary, and reproduction commands live in
[`TESTING.md`](../../../../research/relate/TESTING.md).

What is mine here is the measured composition, not the theorems. The stronger
novel-math claim in this kernel is Gist's Crest sieve
([`research/crest/PROOF.md`](../../../../research/crest/PROOF.md)).
