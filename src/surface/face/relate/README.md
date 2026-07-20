---
doc_radar:
  counts:
    - description: "the relate face: dispatch, nine verb drivers, lifecycle, schema, shared kinship plumbing"
      glob: pkg/kernels/irregex/src/surface/face/relate/*.zig
      unit: files
      equals: 11
  sentinels:
    - description: "main.zig lists exactly the eleven verbs on the unknown-verb help line"
      file: pkg/kernels/irregex/src/surface/face/relate/main.zig
      contains: "search | pack | quote | similar | dups | clusters | echoes | concepts | patterns | index | status"
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
set-shaped questions beside it: _what is this text like, which files cover it
together, how much does the corpus already know, what forked from what, what
repeats a shape under different names, which FUNCTIONS across the tree are the
same idea, and which of these N intents hit where?_ Nine query verbs and two
lifecycle verbs tell that story
([ADR-363](../../../../../../docs/architecture/3-decisions/363-irregex-primitives.md)):

The positive product thesis, the mathematical ancestry, and the falsification
record are kept separately in
[`CLAIM.md`](../../../research/relate/CLAIM.md),
[`PRIOR_ART.md`](../../../research/relate/PRIOR_ART.md), and
[`TESTING.md`](../../../research/relate/TESTING.md). This README explains the
shipped instrument; the dossier explains why compression earns each verb.

```text
relate search <text>  [--top N] [--json] [ROOT...]
    which files describe this text most cheaply? Two-stage compression
    retrieval: the persisted trigram codebook nominates by corpus-priced
    query evidence, then a suffix-automaton cross-parse over bounded
    query-bearing windows decides (coding gain = 1 − warm/cold description
    cost; higher is better and worse-than-cold may be negative)

relate pack <text>    [--top N] [--json] [ROOT...]
    the SET of files that jointly describes <text> cheapest; greedy
    max-coverage over corpus-priced query chunks; each pick priced by the
    bits it ADDS beyond the picks before it (anti-redundant context assembly)

relate quote <text>   [--json]
    rewrite <text> as maximal verbatim quotations from the WHOLE corpus,
    priced in bits; the Ziv–Merhav cross-parse on the persisted codex
    shelf is O(|text|) after load; CLI latency also includes loading the
    shelf and checking filesystem freshness

relate similar <path> [--lens bytes|structure|fused] [--top N] [--json]
               [--no-index] [ROOT...]
    nearest files by compression kinship: "what else in this tree is
    LIKE this file?" The lens picks the distance channel: bytes (LZJD
    dictionary distance, vocabulary-true, the default), structure (the
    normalized silhouette: renamed twins surface), or fused (min of both)

relate dups           [--max-distance T] [--top N] [--json] [--no-index] [ROOT...]
    verified near-duplicate candidate pairs, closest first: copy-paste
    drift, forked fixtures, mirrored modules (candidate generation is
    probabilistic and bucket-capped; emitted-pair precision is exact)

relate clusters       [--max-distance T] [--min-size N] [--top N] [--json]
                      [--no-index] [ROOT...]
    fork FAMILIES: connected components of the emitted verified dup graph,
    largest first: the whole fixture farm in one answer, not a pair
    list the caller re-joins (exactly the transitive closure of dups)

relate echoes         [--min-echo E] [--top N] [--json] [--no-index] [ROOT...]
    DRY candidates dups cannot see: pairs far apart in bytes but close
    in structure (echo = byte distance − structure distance), widest
    gap first — same skeleton, different vocabulary

relate concepts [TEXT] [--lens structure|bytes|echo] [--max-distance T]
                [--min-echo E] [--min-lines N] [--min-size N] [--top N]
                [--brief] [--json] [--no-index] [ROOT...]
    the FUNCTION-level sibling of clusters/echoes: the comparison unit is
    the function fragment, not the file. With no TEXT, package-wide
    families of theoretically-similar functions (the repeated engine, the
    duplicated JSON dump), ranked by consolidation opportunity —
    conservative repeated lines then channel confidence, never a fused
    score. With TEXT, the nearest fragments to that concept ("is this
    already implemented somewhere?"). --lens picks the channel; byte
    sketches are computed only for the fragments a query nominates

relate patterns -e P [-e P…] [-f FILE] [-F] [-i]
                [--by pattern|file] [--under GLOB] [--top N] [--json] [ROOT...]
    ONE walk, N patterns, exact per-pattern attribution, shaped
    engine-side (--by groups, --under filters, --top limits)

relate index [--shelf]     build + persist the kinship atlas (and, with
                           --shelf, the codex shelf quote reads)
relate status [--json]     atlas + shelf readiness and freshness
```

Plus the conventions every irregex face keeps: `--help` / `--version` /
`--schema` (JSON capability manifest), results on stdout (`--json` = NDJSON),
diagnostics on stderr, unknown verbs exit 2.

## Ergonomics: ask the question, then choose the verb

Relate is the native lane of irregex. It does not preserve grep syntax because
these are not grep-shaped questions. Its ergonomic contract is instead one
question per verb, with a small shared vocabulary for scope, result count,
machine output, and acceleration.

| If your reflex is to… | What you actually want | Native Relate choice |
| --- | --- | --- |
| search several vague terms and inspect every hit | files that best explain some text | `relate search TEXT` |
| collect a top-K list and deduplicate it by hand | a non-redundant context set | `relate pack TEXT` |
| ask where a pasted passage came from | corpus-attributed verbatim provenance | `relate quote TEXT` |
| diff one file against many candidates | nearest files to one known file | `relate similar PATH` |
| compare likely duplicate files | verified near-duplicate candidates | `relate dups` |
| reconnect duplicate pairs yourself | complete fork families | `relate clusters` |
| miss renamed copy-paste with byte similarity | shared structure under different vocabulary | `relate echoes` |
| find the same FUNCTION duplicated across files | function-level families or a concept probe | `relate concepts [TEXT]` |
| run N independent exact searches | one attributed walk for N patterns | `relate patterns -e A -e B …` |

### The default move

For humans and coding agents:

1. Name the answer shape before typing the command. Use `search` for a ranked
   file list, `pack` for a jointly useful set, and `quote` for provenance.
2. When a file is already known, use `similar`. Widen to `dups` for pairs,
   `clusters` for whole families, or `echoes` when renaming may hide the shared
   skeleton.
3. Pass roots positionally to constrain corpus work. Use `--top N` to bound
   human output and `--json` when another tool or agent will consume records.
4. Let the atlas accelerate kinship verbs. Use `--no-index` only as the live
   differential oracle, `relate status` to inspect freshness, and
   `relate index --shelf` when you want both the warm atlas and quotation
   shelf.
5. Read each score in its own direction: higher coding gain is better for
   `search`; lower distance is closer for `similar`/`dups`; higher echo is a
   stronger renamed-twin signal; `pack` reports the marginal bits each new
   choice contributes.

### Niche choices that change the question

- **`search` versus `pack`:** `search` ranks files independently. `pack`
  chooses a set whose members pay only for information not already covered by
  earlier picks. Use `pack` for context assembly; use `search` when independent
  rank is the desired output.
- **Similarity lens:** `similar` defaults to `--lens bytes`, which respects
  vocabulary and copy-paste drift. `--lens structure` normalizes identifiers,
  numbers, strings, and comments so renamed twins surface. `--lens fused`
  accepts whichever channel sees the stronger kinship.
- **Pairs, families, and echoes:** `dups --max-distance T` verifies nominated
  pairs at or below a distance threshold. Seed buckets are probabilistic and
  capped, so this guarantees emitted-pair precision, not exhaustive recall.
  `clusters` returns the transitive components of that emitted graph and adds
  `--min-size N`. `echoes --min-echo E`
  is deliberately different: it ranks the gap between byte and structure
  distance rather than pretending structure has one universal duplicate
  threshold.
- **Pattern attribution:** `patterns` preserves which pattern hit which line.
  Use repeated `-e`, `-f FILE`, `-F`, and `-i` for matching; `--by pattern|file`
  groups counts, `--under GLOB` filters paths, and `--top N` limits results
  engine-side.
- **Quotation requires the shelf:** `quote` reads the whole persisted codex,
  not a root-scoped live corpus. Build it with `relate index --shelf`; a stale
  shelf is reported rather than silently treated as current.
- **Warm coverage is verb-specific:** `search` and `pack` nominate from Gist's
  mmap-backed trigram codebook, then fold changed files through the same
  freshness overlay; `similar`, `dups`, `clusters`, and `echoes` use the
  kinship atlas. Narrow explicit kinship scopes rebuild live when that is
  cheaper than loading the global atlas. Missing or corrupt acceleration
  changes cost, never results.
- **Corpus admission is shared with Gist:** positional roots, nested
  `.gitignore` / `.ignore` / `.rgignore` precedence, hidden-file exclusion,
  and freshness admission all use the same corpus-layer matcher. Relate adds
  only the corpus-specific VCS/build skip list.
- **Scores are honest at the boundary:** a negative `search` score means the
  candidate describes the text worse than cold encoding, not an error.
  `pack` reports foreign fingerprints instead of pretending the corpus covered
  them, and `quote` prices unknown text rather than forcing attribution.
- **Deterministic machine use:** `--json` emits NDJSON on stdout while
  diagnostics stay on stderr. Pair, family, and pattern outputs have stable
  orderings, so agents should parse records instead of scraping prose.

The checked-in [`search_api.toml`](../../../contract/search_api.toml) is the
versioned verb contract. The sections below explain the math, corpus policy,
and evidence behind each choice.

This directory is only the face: `main.zig` classifies the verb and hands
off to the sibling drivers (`search.zig` · `pack.zig` · `quote.zig` ·
`verbs.zig` · `family.zig` · `echoes.zig` · `concepts.zig` · `lifecycle.zig`
· `schema.zig`), with the shared view resolver + pair machinery in
`kinship.zig`. The engines live under
[`src/search/similarity/`](../../search/similarity/README.md)
(sketch · silhouette · concepts · lexicon · zipper),
[`src/search/batch/`](../../search/batch/README.md)
(patterns · loom), [`src/index/codex/`](../../index/codex/README.md) (the
FM-index shelf behind `quote`), and
[`src/index/atlas/`](../../index/atlas/README.md) (the persisted kinship
atlas behind the warm verbs).

## The warm tier: why relate is an engine, not a shim

I persist one LZJD sketch (~1 KiB) and one structure silhouette (~2 KiB) per
corpus file into the **kinship atlas**. Then broad `similar` / `dups` /
`clusters` / `echoes` queries can read the compressed view instead of
re-reading the corpus; narrow explicit scopes take the cheaper live path.
`search` / `pack` reuse Gist's persisted trigram codebook for nomination and
read only a bounded exact-decider pool. `concepts` persists a parallel
**fragment atlas** (`concepts.frag`): one structural silhouette per function
fragment, folded for freshness the same way, so function-level discovery answers
warm too — byte sketches for its `bytes` / `echo` lenses are the only live read,
and only for nominated fragments. The committed contract is useful current-byte
answers, not a timeless speed ratio: measure both rungs on the corpus and
machine you care about.

I keep the same covenant as Gist: an index is an accelerator, never an
authority. Queries fold in every file changed since the build anchor, emitted
rows are checked against deletion, and `--no-index` or missing/corrupt state
falls back to live work. Search's exact decider sees bounded windows around
the query evidence rather than constructing suffix automata over multi-MiB
files, so top-K latency is bounded by query and evidence-pool size instead of
the total corpus byte count.

## Why these verbs

I kept watching agents rebuild the same workflows outside the engine. Each verb
pulls one of those loops into the kernel:

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
- **`similar` / `dups` / `clusters`** make kinship a primitive instead of a
  per-tool hack. Byte kinship has no parser or language registry; the optional
  structure channel adds one pan-language token squint rather than per-language
  ASTs. `clusters` returns the transitive families restructure/dedup sweeps
  otherwise re-derive from pair lists.
- **`echoes`** reports what neither channel can say alone. Byte kinship calls
  a renamed twin unrelated; structure distance alone has no clean absolute
  threshold (measured: family-max vs cross-min overlap at every winnow
  setting). The _difference_ — `echo = bytes − structure` — is self-calibrated
  per pair: high echo means "far more shared shape than shared vocabulary,"
  the Type-2 clone an abstraction should collapse. The structure channel is
  MOSS-style winnowed shingles over a normalized token stream
  (identifiers→I, numbers→N, strings→S, comments dropped, pan-language
  keywords kept)—one language-agnostic squint, not a per-language parse. Plain
  duplication ranks low here by design; `dups` already owns it.
- **`concepts`** drops kinship from the file to the FUNCTION. `clusters` and
  `echoes` answer "which files are forks?"; the finer question an agent asks is
  "which functions across the tree are the same idea — the repeated engine, the
  duplicated JSON dump, the copy-pasted validator — regardless of name or file?"
  The comparison unit is the function fragment (`regions.extractAll` over
  authored brace-family + Python source), so a helper cloned into six files
  surfaces as one six-member family instead of hiding in six unrelated files.
  It reuses the same silhouette/sketch channels, the same seed-nomination and
  union-find components pass, and the same warm-fold discipline — over a
  fragment atlas (`concepts.frag`) rather than the file atlas. Ranking is by
  conservative repeated-line opportunity, never a fused similarity number, and
  the channels stay side by side so the reader judges the relation.
- **`quote`** is the corpus-global tier: text the corpus knows quotes at
  **0.14–0.17 bits/byte**, foreign bytes at **12.65–15.16** in the committed
  scale table—an **88–94×** separation. Each phrase is attributed to an
  exemplar file, with query work linear in text length
  (`zig build codex-scale`, tables in
  [`src/index/codex/README.md`](../../index/codex/README.md)).
- **`search`** is the retrieval shape of the same idea: rank files by how
  cheaply each would describe the query, two-stage so the exact (expensive)
  decider only prices nominated candidates.

## Evidence status

The proof strength is intentionally uneven and visible:

| claim                                  | authority                                 | status                           |
| -------------------------------------- | ----------------------------------------- | -------------------------------- |
| `patterns` equals N solo Gist runs     | `patterns_test.zig` with prefilter on/off | gated                            |
| warm atlas equals `--no-index`         | atlas fold/deletion tests                 | gated                            |
| quote scale and bit separation         | `zig build codex-scale` + codex tables    | committed measurement            |
| compression versus semantic embeddings | `zig build relate-knn`                    | rerunnable comparative harness   |
| warm latency                           | local comparison only                     | no committed timing artifact     |
| echo ranking quality                   | heuristic + unit properties               | no checked-in labeled evaluation |

The durable test inventory is
[`research/relate/TESTING.md`](../../../research/relate/TESTING.md). Numbers
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
[`CLAIM.md`](../../../research/relate/CLAIM.md). The full citation trail—LZJD,
winnowing/MOSS, Ziv–Merhav, FM-indexes, submodular selection, and the
neighboring systems we measured and left—lives in
[`PRIOR_ART.md`](../../../research/relate/PRIOR_ART.md). Exactness, atlas
identity, the embedding boundary, and reproduction commands live in
[`TESTING.md`](../../../research/relate/TESTING.md).

What is mine here is the measured composition, not the theorems. The stronger
novel-math claim in this kernel is Gist's Crest sieve
([`research/crest/PROOF.md`](../../../research/crest/PROOF.md)).
