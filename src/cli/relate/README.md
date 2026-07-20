---
doc_radar:
  counts:
    - description: "the relate face: dispatch, eight verb drivers, lifecycle, schema, shared kinship plumbing"
      glob: pkg/kernels/irregex/src/cli/relate/*.zig
      unit: files
      equals: 10
  sentinels:
    - description: "main.zig lists exactly the ten verbs on the unknown-verb help line"
      file: pkg/kernels/irregex/src/cli/relate/main.zig
      contains: "search | pack | quote | similar | dups | clusters | echoes | patterns | index | status"
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
repeats a shape under different names, and which of these N intents hit
where?_ Eight query verbs and one lifecycle tell that story
([ADR-363](../../../../../../docs/architecture/3-decisions/363-irregex-primitives.md)):

```text
relate search <text>  [--top N] [--json] [ROOT...]
    which files describe this text most cheaply? Two-stage compression
    retrieval: a winnowed-fingerprint lexicon nominates, then a
    suffix-automaton cross-parse decides (score = coding gain in [0,1])

relate pack <text>    [--top N] [--json] [ROOT...]
    the SET of files that jointly describes <text> cheapest; greedy
    submodular max-coverage; each pick priced by the bits it ADDS beyond
    the picks before it (anti-redundant context assembly)

relate quote <text>   [--json]
    rewrite <text> as maximal verbatim quotations from the WHOLE corpus,
    priced in bits; the Ziv–Merhav cross-parse on the persisted codex
    shelf, O(|text|); corpus size never appears in the query cost

relate similar <path> [--lens bytes|structure|fused] [--top N] [--json]
               [--no-index] [ROOT...]
    nearest files by compression kinship: "what else in this tree is
    LIKE this file?" The lens picks the distance channel: bytes (LZJD
    dictionary distance, vocabulary-true, the default), structure (the
    normalized silhouette: renamed twins surface), or fused (min of both)

relate dups           [--max-distance T] [--top N] [--json] [--no-index] [ROOT...]
    near-duplicate pairs across the corpus, closest first: copy-paste
    drift, forked fixtures, mirrored modules

relate clusters       [--max-distance T] [--min-size N] [--top N] [--no-index] [ROOT...]
    fork FAMILIES: connected components of the verified dup graph,
    largest first: the whole fixture farm in one answer, not a pair
    list the caller re-joins (exactly the transitive closure of dups)

relate echoes         [--min-echo E] [--top N] [--json] [--no-index] [ROOT...]
    DRY candidates dups cannot see: pairs far apart in bytes but close
    in structure (echo = byte distance − structure distance), widest
    gap first — same skeleton, different vocabulary

relate patterns -e P [-e P…] [-f FILE] [-F] [-i]
                [--by pattern|file] [--under GLOB] [--top N] [ROOT...]
    ONE walk, N patterns, exact per-pattern attribution, shaped
    engine-side (--by groups, --under filters, --top limits)

relate index [--shelf]     build + persist the kinship atlas (and, with
                           --shelf, the codex shelf quote reads)
relate status [--json]     atlas + shelf readiness and freshness
```

Plus the conventions every irregex face keeps: `--help` / `--version` /
`--schema` (JSON capability manifest), results on stdout (`--json` = NDJSON),
diagnostics on stderr, unknown verbs exit 2.

This directory is only the face: `main.zig` classifies the verb and hands
off to the sibling drivers (`search.zig` · `pack.zig` · `quote.zig` ·
`verbs.zig` · `family.zig` · `echoes.zig` · `lifecycle.zig` · `schema.zig`),
with the shared view resolver + pair machinery in `kinship.zig`. The engines
live under [`src/search/similarity/`](../../search/similarity/README.md)
(sketch · silhouette · lexicon · zipper),
[`src/search/batch/`](../../search/batch/README.md)
(patterns · loom), [`src/index/codex/`](../../index/codex/README.md) (the
FM-index shelf behind `quote`), and
[`src/index/atlas/`](../../index/atlas/README.md) (the persisted kinship
atlas behind the warm verbs).

## The warm tier: why relate is an engine, not a shim

I persist one LZJD sketch (~1 KiB) and one structure silhouette (~2 KiB) per
corpus file into the **kinship atlas**. Then `similar` / `dups` / `clusters` /
`echoes` can read tens of MiB instead of re-reading a couple-hundred-MiB
corpus every time. Here, warm `similar` is ~95 ms versus ~1.1 s live, about
11× faster.

I keep the same covenant as Gist: the atlas is an accelerator, never an
authority. Queries fold in every file changed since the build anchor, emitted
rows are checked against deletion, and `--no-index` or a missing or corrupt
atlas falls back to a live build with **byte-identical answers**. `search` and
`pack` stay live-built because the lexicon's fingerprint density does not
persist economically; the atlas README shows the numbers.

## Why these verbs

I kept watching agents rebuild the same workflows outside the engine. Each verb
pulls one of those loops into the kernel, and each claim traces to a harness:

- **`patterns`** collapses the N-run loop: the 10-pattern relocator-shaped
  slate answers in **~195 ms** with exact attribution vs **~1.2 s** for 10
  sequential `gist -l` runs (~6×). A fused alternation `(?:a)|(?:b)` is
  fast but loses _which_ pattern hit, the whole point
  (`bench/races/multipattern.sh`). Exactness is the contract: a `PatternSet`
  answer must equal N independent single-pattern runs bit for bit, tested
  with the prefilter gate forced both on and off.
- **`pack`** answers the question every independent top-K retriever
  (embeddings included) cannot: ranked lists surface near-duplicates
  together, so an agent assembling context pays for the same information K
  times. Coverage over priced fingerprints is submodular, so the greedy
  sweep (Nemhauser–Wolsey–Fisher 1978, lazy order per Minoux 1978) is
  (1−1/e)-optimal: model-free, deterministic, with exact marginal-bits
  receipts per pick.
- **`similar` / `dups` / `clusters`** make kinship a primitive instead of a
  per-tool hack. There is no parser, tokenizer, or language list; the compressor
  discovers the vocabulary, which is what makes the matching deliberately
  _irregular_. `clusters` returns the transitive families restructure/dedup
  sweeps re-derive by hand from pair lists (token-parsing dup tools stop at
  per-language pairs).
- **`echoes`** reports what neither channel can say alone. Byte kinship calls
  a renamed twin unrelated; structure distance alone has no clean absolute
  threshold (measured: family-max vs cross-min overlap at every winnow
  setting). The _difference_ — `echo = bytes − structure` — is self-calibrated
  per pair: high echo means "far more shared shape than shared vocabulary,"
  the Type-2 clone an abstraction should collapse. On the graduation eval
  (54 lint-registry rows, 19 labeled family members) the echo ranking hit
  P@10 = 100% against an 11.9% base rate. The structure channel is
  MOSS-style winnowed shingles over a normalized token stream
  (identifiers→I, numbers→N, strings→S, comments dropped, pan-language
  keywords kept) — a squint, not a parse, so the no-language-list covenant
  holds. Plain duplication ranks LOW here by design; `dups` already owns it.
- **`quote`** is the corpus-global tier: text the corpus knows quotes at
  **~0.15 bits/byte**, foreign bytes at **~15**. That is a ~90× separation, each
  phrase attributed to an exemplar file, flat in corpus size
  (`zig build codex-scale`, tables in
  [`src/index/codex/README.md`](../../index/codex/README.md)).
- **`search`** is the retrieval shape of the same idea: rank files by how
  cheaply each would describe the query, two-stage so the exact (expensive)
  decider only prices nominated candidates.

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

## Prior art

I did not invent the math. The central spark was Benedetto, Caglioti, and
Loreto's
[_Language Trees and Zipping_](https://doi.org/10.1103/PhysRevLett.88.048702)
(Phys. Rev. Lett. 2002): use compressor-defined relative entropy to measure how
well one text's language describes another. That paper turned compression from
storage into comparison for me.

The full citation trail — LZJD, winnowing/MOSS, Ziv–Merhav, FM-index, submodular
pack, what we measured and left (embeddings, Hyperscan, NCD-gzip) — plus the
composition claim and evidence inventory live in
[`research/relate/`](../../../research/relate/) (`PRIOR_ART.md` · `CLAIM.md` ·
`TESTING.md`). What is mine here is the composition, not the theorems. (The one
place this kernel carries genuinely new math is on the gist side: the crest
sieve, [`research/crest/`](../../../research/crest/PROOF.md).)
