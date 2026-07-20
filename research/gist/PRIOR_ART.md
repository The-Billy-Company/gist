# Gist — prior art (the full landscape review)

**Claim under review.** A local, regex-first code locator tuned for the
repeated search loop of coding agents: persistent byte-trigram candidate
index, crest sidecar for literal-free class repetitions, freshness-aware
fallback to current files, linear + opt-in PCRE2 verification, ripgrep-like
CLI conventions, and compact definition-biased ranking — measured so
accelerators never overrule current bytes.

**Verdict:** COMPOSITION, not algorithmic novelty for the trigram family
(adversarial landscape review kept current with the shipped surface). Every
ingredient is deliberately standard except the crest sieve (separate dossier:
[`../crest/PRIOR_ART.md`](../crest/PRIOR_ART.md)). This file is the paper
trail: each neighboring family, what it actually does, and the load-bearing
difference. The precise claim and non-claims live in `CLAIM.md`. Every
external source is listed with a link and annotation in
[§ References](#references).

---

## Explicit non-claims

Gist is:

- **not a new indexing algorithm**; document and positional n-gram indexes
  have decades of literature and production use;
- **not a claim that every pattern is linear-time**; the default engine is
  RE2/Pike-family linear matching; lookaround, backreferences, and other
  PCRE2-only constructs require `-P` or `--engine auto`, with resource caps —
  backtracking is opted into, never disguised as linear;
- **not a semantic code-intelligence engine**; it does not resolve types,
  definitions, references, or call graphs — `--rank` is heuristic text
  ranking, not name resolution;
- **not a Sourcegraph/Moderne replacement**; those systems cover hosted
  multi-repository search, permissions, semantic metadata, navigation,
  governance, and transformation workflows that Gist does not attempt.

Unicode case folding and `\b`/`\w` word semantics are **default-on** (rg
parity); `(?-u)` / `--no-unicode` selects ASCII-byte semantics.
`gist --schema` is authoritative for the narrower public compatibility
contract.

---

## 1. Agent-search systems

### Cursor agent search

[Cursor's search docs](#r-cursor-search) describe an agent-selected
combination of exact/regex search ("Instant Grep"), semantic retrieval, and
file reads. The [semantic-search report](#r-cursor-semsearch) evaluates
hybrid grep plus embedding retrieval for codebase questions.

Gist addresses only the deterministic exact/regex leg: local bytes, explicit
paths, current working-tree freshness, and CLI output. It neither reproduces
Cursor's proprietary implementation nor claims its semantic-retrieval role.
(Compression kinship for "what resembles this" is the sibling `relate`
binary — still model-free, still not embeddings.)

### Microsoft tgrep

[microsoft/tgrep](#r-tgrep) is a local, trigram-indexed regex searcher with
a client/server architecture, persistent index, file watching, and a
grep-shaped CLI. It is the closest public agent-oriented design point. Gist
differs in treating the index as optional read elision, preserving a
live-scan fallback when index coverage or freshness is insufficient, and
keeping the cold subprocess capable of answering every supported request
when the resident session declines.

### Moderne Trigrep

[Moderne Trigrep](#r-trigrep) provides sub-second, organization-scoped
search across many repositories. Its [official documentation](#r-trigrep-docs)
describes Zoekt-compatible trigram indexes enriched from OpenRewrite
Lossless Semantic Trees, Sourcegraph/Zoekt query dialects, structural
filters, CLI, and MCP delivery.

Gist indexes local file bytes and adds lightweight byte-level ranking
signals; it has no LST, portfolio control plane, semantic filters, or
transformation engine.

---

## 2. Indexed regex and code-search systems

### Google Code Search and csearch

Russ Cox's [trigram-index article](#r-cox-trigram) explains required-trigram
extraction, Boolean candidate queries, and regex verification. The
accompanying [google/codesearch](#r-codesearch) repository ships `cindex`
and `csearch`. This is direct algorithmic ancestry for Gist's basic
candidate-index design.

### Zoekt and Sourcegraph

[Zoekt](#r-zoekt) is a source-oriented search engine with positional
trigrams, mmap-friendly shards, Boolean queries, regex search, ranking,
multi-repository service components, and ctags-derived symbol signals; its
[design document](#r-zoekt-design) details the index.

[Sourcegraph's architecture](#r-sourcegraph) places Zoekt inside a broader
platform with repository synchronization, permissions, unindexed fallback,
code navigation, and service fan-out. Gist is a local locator, not that
platform.

### GitHub Blackbird

GitHub's [Blackbird architecture article](#r-blackbird) describes a Rust
search engine using variable-length sparse n-grams, regex planning, shard
distribution, and global-scale constraints. Its [history article](#r-blackbird-hist)
also documents blob-level deduplication and symbol metadata. Gist uses a
much simpler local fixed-trigram index and makes no Blackbird-scale claim.

### livegrep

[livegrep](#r-livegrep) provides interactive RE2 search over prebuilt
indexes through a long-running search backend and stateless web front end.
It targets shared, gigabyte-scale repositories; Gist targets a local
working tree and shells naturally from an agent loop.

### Hound

[Hound](#r-hound) builds and refreshes a trigram index per repository
behind a Go API and web UI, explicitly following Cox's design. Gist reuses
the same broad candidate-filter pattern without Hound's repository service
or browser interface.

### qgrep

[qgrep](#r-qgrep) searches a compressed, incrementally updated indexed copy
of source data and supports content, path, and fuzzy file queries. Gist
instead keeps source files authoritative and uses its index to avoid reads
that cannot match. (The separate **codex** shelf is an exact compressed
self-index for literal `count`/`find` — still not qgrep's fuzzy path layer;
see `src/index/codex/`.)

---

## 3. Semantic navigation and symbol indexes

These systems answer a different class of question from byte/regex search:

- [LSP 3.17](#r-lsp) — workspace symbols, definitions, references, code actions
- [LSIF](#r-lsif) — persisted code-intelligence (archived; superseded by SCIP)
- [SCIP](#r-scip) — language-agnostic persisted navigation protocol
- [Universal Ctags](#r-ctags) — compact language-object tag indexes

Gist may rank text that looks like a declaration, but that heuristic is not
name resolution and must not be presented as semantic intelligence.

---

## 4. Structural search and transformation

Text search is also distinct from syntax-aware matching and rewriting:

- [Semgrep](#r-semgrep) — code-shaped patterns for static analysis
- [ast-grep](#r-astgrep) — tree-sitter structural search / rewrite
- [Comby](#r-comby) — language-aware template search and replacement
- [OpenRewrite](#r-openrewrite) / [Lossless Semantic Trees](#r-lst) —
  format-preserving, type-attributed refactoring

Gist deliberately remains a byte/regex locator. Agents should compose it with
these tools when the question is structural or transformational.

---

## 5. Matching engines (ancestry, not competition)

The linear lane descends from Thompson's
[Regular Expression Search Algorithm](#r-thompson) (CACM 1968), the Pike
VM, Cox's [Regular Expression Matching Can Be Simple And Fast](#r-cox-re1),
and [RE2](#r-re2). Unicode range compilation follows the Thompson/Cox UTF-8
decomposition used by RE2 and rust-regex.

Complex constructs use the vendored [PCRE2](#r-pcre2) engine with JIT and
resource caps. Gist does not claim to make backtracking expressions linear;
`-P` deliberately selects PCRE2 semantics, while `--engine auto` keeps the
linear engine whenever it can express the pattern.

---

## 6. Ranking

The bounded result view (`--rank`) uses weighted Reciprocal Rank Fusion from
Cormack, Clarke, and Büttcher ([SIGIR 2009](#r-rrf)). Its inputs are
language-agnostic text and path signals. A declaration-shaped boost is not
a symbol table.

---

## 7. N-gram and regex-index literature

The relevant research predates Gist and establishes both the design space and
its limits:

- [Cho & Rajagopalan 2002](#r-cho) — selective multi-gram indexes for regex
- [Kim et al. 2010](#r-kim) — posting-list plans for q-gram substring search
- [Cox 2012](#r-cox-trigram) — direct code-search construction + open impl
- [SWE at Google ch. 17](#r-swe17) — trigrams → suffix arrays → sparse n-grams
- [Gibney & Thankachan 2021](#r-gibney) — conditional lower bounds for regex indexing
- [Zhang et al. 2025](#r-zhang) — modern n-gram selection strategies (PVLDB)

The whole trigram/n-gram *presence* family shares one blind spot: literal-free
class repetitions concede a full scan. That hole is Crest's object — see
[`../crest/PRIOR_ART.md`](../crest/PRIOR_ART.md).

---

## 8. Precise novelty statement

Gist's contribution is a **systems/workload composition** for one repository
and one high-frequency consumer: coding agents repeatedly issuing small
grep-shaped queries against a concurrently changing tree. It combines:

1. an optional persisted candidate index with fail-open live scanning;
2. a freshness overlay so unindexed edits stay visible;
3. a broad, explicit, fail-loud ripgrep-compatible CLI subset;
4. definition-biased, generated-code-aware ranking for bounded agent context;
5. reproducible correctness and cold-start performance gates.

None of those ingredients alone is novel (crest sieve excepted). The value is
integrating and measuring them against the agent search loop without claiming
the semantic, hosted, or structural breadth of the systems above.

**Standing obligation.** If a prior instance of this same measured contract
for this same workload surfaces, cite it and re-scope the claim — never
quietly drop this file. Where prose lags the binary, `gist --schema`, the
live differential harness, and the committed certificate are authoritative.

---

## References

Annotated bibliography for every external source above. Anchor ids match the
in-body citation links.

<span id="r-cursor-search"></span>
1. **Cursor.**
   [Agent search documentation](https://cursor.com/docs/agent/tools/search).
   *Annotation:* Agent-selected Instant Grep + semantic retrieval + file
   reads — gist owns only the deterministic exact/regex leg.

<span id="r-cursor-semsearch"></span>
2. **Cursor.**
   [Semantic search report](https://cursor.com/blog/semsearch).
   *Annotation:* Hybrid grep + embedding evaluation; gist does not claim
   the semantic half.

<span id="r-tgrep"></span>
3. **Microsoft tgrep.**
   [github.com/microsoft/tgrep](https://github.com/microsoft/tgrep).
   *Annotation:* Closest public local-agent trigram+grep shape;
   client/server + watchers — gist keeps cold subprocess authoritative.

<span id="r-trigrep"></span>
4. **Moderne Trigrep.**
   [moderne.ai — Trigrep](https://www.moderne.ai/moderne-agent-tools/trigrep).
   *Annotation:* Org-scoped multi-repo search over Zoekt-compatible indexes
   enriched from OpenRewrite LSTs — portfolio plane gist does not have.

<span id="r-trigrep-docs"></span>
5. **Moderne.**
   [Trigrep user documentation](https://github.com/moderneinc/moderne-docs/blob/main/docs/user-documentation/agent-tools/trigrep.md).
   *Annotation:* Query dialects, structural filters, CLI/MCP delivery for
   Trigrep.

<span id="r-cox-trigram"></span>
6. **Cox (2012).**
   [*Regular Expression Matching with a Trigram Index*](https://swtch.com/~rsc/regexp/regexp4.html).
   *Annotation:* Required-trigram extraction + Boolean candidate query +
   verify — direct algorithmic ancestry for gist's candidate index.

<span id="r-codesearch"></span>
7. **Google codesearch.**
   [github.com/google/codesearch](https://github.com/google/codesearch).
   *Annotation:* Open `cindex` / `csearch` implementation of Cox's design.

<span id="r-zoekt"></span>
8. **Zoekt.**
   [github.com/sourcegraph/zoekt](https://github.com/sourcegraph/zoekt).
   *Annotation:* Production positional-trigram code search with ranking and
   multi-repo shards — hosted scale gist does not claim.

<span id="r-zoekt-design"></span>
9. **Zoekt.**
   [Design document](https://github.com/sourcegraph/zoekt/blob/main/doc/design.md).
   *Annotation:* Index layout and query planning details for Zoekt.

<span id="r-sourcegraph"></span>
10. **Sourcegraph.**
    [Admin architecture](https://sourcegraph.com/docs/admin/architecture).
    *Annotation:* Platform around Zoekt — sync, permissions, navigation;
    gist is a local locator only.

<span id="r-blackbird"></span>
11. **GitHub.**
    [The technology behind GitHub's new code search](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/).
    *Annotation:* Blackbird — sparse variable-length n-grams at global
    scale; gist uses fixed local trigrams.

<span id="r-blackbird-hist"></span>
12. **GitHub.**
    [A brief history of code search at GitHub](https://github.blog/engineering/architecture-optimization/a-brief-history-of-code-search-at-github/).
    *Annotation:* Blob dedup and symbol-metadata history for GitHub search.

<span id="r-livegrep"></span>
13. **livegrep.**
    [github.com/livegrep/livegrep](https://github.com/livegrep/livegrep).
    *Annotation:* Interactive RE2 over prebuilt indexes via a long-running
    backend — shared-repo scale, not agent working-tree loop.

<span id="r-hound"></span>
14. **Hound.**
    [github.com/hound-search/hound](https://github.com/hound-search/hound).
    *Annotation:* Per-repo trigram index + Go API/UI following Cox; gist
    omits the service/browser face.

<span id="r-qgrep"></span>
15. **zeux/qgrep.**
    [github.com/zeux/qgrep](https://github.com/zeux/qgrep).
    *Annotation:* Searches a compressed indexed *copy* of source; gist
    keeps live files authoritative.

<span id="r-lsp"></span>
16. **Language Server Protocol 3.17.**
    [Specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/).
    *Annotation:* Live editor↔server symbols/defs/refs — semantic
    intelligence, not byte/regex search.

<span id="r-lsif"></span>
17. **LSIF.**
    [lsif.dev](https://lsif.dev/).
    *Annotation:* Persisted code-intelligence format (archived; SCIP
    successor).

<span id="r-scip"></span>
18. **SCIP.**
    [github.com/scip-code/scip](https://github.com/scip-code/scip).
    *Annotation:* Language-agnostic persisted navigation protocol —
    definitions/refs/impls, not grep.

<span id="r-ctags"></span>
19. **Universal Ctags.**
    [github.com/universal-ctags/ctags](https://github.com/universal-ctags/ctags).
    *Annotation:* Compact tag indexes for symbol navigation; gist's
    `--rank` boost is not a tag database.

<span id="r-semgrep"></span>
20. **Semgrep.**
    [Philosophy](https://semgrep.dev/docs/contributing/semgrep-philosophy).
    *Annotation:* Syntax-aware pattern matching for analysis — compose with
    gist, do not conflate.

<span id="r-astgrep"></span>
21. **ast-grep.**
    [ast-grep.github.io](https://ast-grep.github.io/).
    *Annotation:* tree-sitter structural search/lint/rewrite.

<span id="r-comby"></span>
22. **Comby.**
    [comby.dev](https://comby.dev/).
    *Annotation:* Lightweight language-aware templates for structural
    search and replacement.

<span id="r-openrewrite"></span>
23. **OpenRewrite.**
    [docs.openrewrite.org](https://docs.openrewrite.org/).
    *Annotation:* Recipe-driven automated refactoring over LSTs.

<span id="r-lst"></span>
24. **OpenRewrite.**
    [Lossless Semantic Trees](https://docs.openrewrite.org/concepts-and-explanations/lossless-semantic-trees).
    *Annotation:* Format-preserving, type-attributed ASTs — Trigrep
    enrichment source; not gist's index.

<span id="r-thompson"></span>
25. **Thompson (1968).**
    [*Regular Expression Search Algorithm*](https://doi.org/10.1145/363347.363387)
    (CACM).
    *Annotation:* Linear-time NFA simulation ancestry for the default
    matcher lane.

<span id="r-cox-re1"></span>
26. **Cox.**
    [*Regular Expression Matching Can Be Simple And Fast*](https://swtch.com/~rsc/regexp/regexp1.html).
    *Annotation:* Pike-VM / RE2-family linear matching pedagogy gist
    follows for the default engine.

<span id="r-re2"></span>
27. **RE2.**
    [github.com/google/re2](https://github.com/google/re2).
    *Annotation:* Production linear regex engine; FilteredRE2 is the
    presence-prefilter cousin Crest complements.

<span id="r-pcre2"></span>
28. **PCRE2.**
    [pcre.org documentation](https://www.pcre.org/current/doc/html/).
    *Annotation:* Vendored backtracking engine for `-P` / `--engine auto`
    (lookaround, backreferences) with resource caps.

<span id="r-rrf"></span>
29. **Cormack, Clarke & Büttcher (2009).**
    [*Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods*](https://doi.org/10.1145/1571941.1572114)
    (SIGIR).
    *Annotation:* Weighted RRF behind gist's bounded `--rank` view —
    heuristic text ranking, not name resolution.

<span id="r-cho"></span>
30. **Cho & Rajagopalan (2002).**
    [*A Fast Regular Expression Indexing Engine*](https://doi.org/10.1109/ICDE.2002.994755)
    (ICDE).
    *Annotation:* Selective multi-gram indexes for regex filtering —
    presence-family literature.

<span id="r-kim"></span>
31. **Kim, Woo, Park & Shim (2010).**
    [*Efficient processing of substring match queries with inverted q-gram indexes*](https://doi.org/10.1109/ICDE.2010.5447866)
    (ICDE).
    *Annotation:* Posting-list plans for q-gram substring search.

<span id="r-swe17"></span>
32. **Google.**
    [*Software Engineering at Google*, chapter 17](https://abseil.io/resources/swe-book/html/ch17.html).
    *Annotation:* Production Code Search evolution: trigrams → suffix
    arrays → sparse n-grams; index-size/query-cost trade-off.

<span id="r-gibney"></span>
33. **Gibney & Thankachan (2021).**
    [*Text Indexing for Regular Expression Matching*](https://doi.org/10.3390/a14050133)
    (*Algorithms*).
    *Annotation:* Conditional lower bounds and preprocessing/query
    trade-offs for general regex indexing.

<span id="r-zhang"></span>
34. **Zhang et al. (2025).**
    [*An Evaluation of N-Gram Selection Strategies for Regular Expression Indexing*](https://www.vldb.org/pvldb/vol18/p5703-zhang.pdf)
    (PVLDB).
    *Annotation:* Modern n-gram *selection* over the same presence test —
    still concedes the literal-free class-repetition hole (Crest's object).
