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
trail of **citations that appear in the shipped gist code and READMEs**, plus
neighboring families we measured and left. The precise claim and non-claims
live in `CLAIM.md`. Every external source is listed with a link and
annotation in [§ References](#references).

---

## 0. Where cited in the tree

| citation                                                                                      | role in gist                                             | code / docs                                                                  |
| --------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------- |
| [Cox 2012](#r-cox-trigram) / [codesearch](#r-codesearch)                                      | required-trigram candidate filter                        | `src/corpus/index/trigrams/`, `src/kernel/match/regex/analysis/`, CLI README |
| [ripgrep](#r-ripgrep)                                                                         | CLI face, ignore dialect, rgsuite oracle                 | `src/surface/exec/cold/`, `bench/rgsuite/`, `src/surface/face/gist/`         |
| [Thompson](#r-thompson) / [Cox re1](#r-cox-re1) / [RE2](#r-re2) / [rust-regex](#r-rust-regex) | linear NFA → DFA / Pike lane + UTF-8 ranges              | `src/kernel/match/regex/`                                                    |
| [PCRE2](#r-pcre2)                                                                             | opt-in backtracking (`-P` / `--engine auto`)             | `src/kernel/match/regex/pcre2/`                                              |
| [memchr](#r-memchr)                                                                           | first+last-byte SIMD presence for `-F`                   | `src/kernel/match/scan/simd.zig`                                             |
| [Cormack et al. 2009](#r-rrf)                                                                 | weighted RRF for `--rank`                                | `src/kernel/rank/rank.zig`                                                   |
| [tgrep](#r-tgrep) / [Zoekt](#r-zoekt) / [Blackbird](#r-blackbird)                             | closest indexed / agent shapes we measured against       | CLI README § Prior art, Certificate                                          |
| [ugrep](#r-ugrep) / [ag](#r-ag) / [GNU grep](#r-gnu-grep) / [git grep](#r-git-grep)           | PCRE-capable _scan_ peers (no index)                     | package README evidence §1                                                   |
| [pg_trgm](#r-pg-trgm) / RE2 `FilteredRE2`                                                     | trigram-family siblings that share the literal-free hole | package README + crest dossier                                               |
| [qgrep](#r-qgrep) / [Hound](#r-hound) / [livegrep](#r-livegrep)                               | neighboring indexed designs                              | this file §3                                                                 |

Codex FM-index math, Hyperscan-vs-`patterns`, and compression kinship are
**relate** (and the shared `src/corpus/index/codex/` module) — see
[`../relate/PRIOR_ART.md`](../relate/PRIOR_ART.md), not this file.

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
  governance, and transformation workflows that Gist does not attempt;
- **not compression-as-search or corpus quotation**; those are `relate`
  (LZJD / Ziv–Merhav / codex shelf) — see [`../relate/PRIOR_ART.md`](../relate/PRIOR_ART.md).

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

## 2. Unindexed grep peers (CLI face and oracle)

These tools _scan_ the tree. They are the field's PCRE-capable half — and
the shape gist deliberately copies for argv, ignore rules, stdout, and exit
codes — while adding a sound candidate index the peers lack.

### ripgrep (primary face)

[BurntSushi/ripgrep](#r-ripgrep) is the everyday mental model and the live
oracle behind `bench/rgsuite/`: gitignore/`.ignore`/`.rgignore` precedence,
0/1/2 exit codes, JSON-lines records, Unicode defaults, mined upstream test
replay. Gist is a **tested subset**, not a silent clone of every flag rg ever
shipped (`flag_catalog` → `gist --schema`). The walk skeleton and ignore
dialect are deliberate rg-parity reimplementations certified by that suite.

### Other PCRE-capable scanners

[ugrep](#r-ugrep), [The Silver Searcher (ag)](#r-ag), [GNU grep](#r-gnu-grep)
(`grep -P`), and [git grep](#r-git-grep) also express lookaround /
backreferences by scanning. Indexed peers ([csearch](#r-codesearch),
[Zoekt](#r-zoekt)) stay on RE2-family matchers and cannot enter that race.
Gist's unusual intersection — documented in the package README evidence §1 —
is a vendored, JIT'd, resource-capped [PCRE2](#r-pcre2) verifier behind the
**same** persisted trigram index as the linear engine, with fail-open scan
when required literals cannot be proven.

---

## 3. Indexed regex and code-search systems

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

[qgrep](#r-qgrep) searches a compressed, incrementally updated indexed _copy_
of source data and supports content, path, and fuzzy file queries. Gist
keeps live source files authoritative for grep-shaped search and uses its
trigram/crest indexes only to avoid reads that cannot match. (`gist codex`
is a thin lifecycle face over the shared codex shelf; the FM-index
bibliography and `relate quote` story live in
[`../relate/PRIOR_ART.md`](../relate/PRIOR_ART.md) § Corpus quotation and
[`src/corpus/index/codex/README.md`](../../src/corpus/index/codex/README.md) — not here.)

---

## 4. Semantic navigation and symbol indexes

These systems answer a different class of question from byte/regex search:

- [LSP 3.17](#r-lsp) — workspace symbols, definitions, references, code actions
- [LSIF](#r-lsif) — persisted code-intelligence (archived; superseded by SCIP)
- [SCIP](#r-scip) — language-agnostic persisted navigation protocol
- [Universal Ctags](#r-ctags) — compact language-object tag indexes

Gist may rank text that looks like a declaration, but that heuristic is not
name resolution and must not be presented as semantic intelligence.

---

## 5. Structural search and transformation

Text search is also distinct from syntax-aware matching and rewriting:

- [Semgrep](#r-semgrep) — code-shaped patterns for static analysis
- [ast-grep](#r-astgrep) — tree-sitter structural search / rewrite
- [Comby](#r-comby) — language-aware template search and replacement
- [OpenRewrite](#r-openrewrite) / [Lossless Semantic Trees](#r-lst) —
  format-preserving, type-attributed refactoring

Gist deliberately remains a byte/regex locator. Agents should compose it with
these tools when the question is structural or transformational.

---

## 6. Matching engines (ancestry, not competition)

The linear lane descends from Thompson's
[Regular Expression Search Algorithm](#r-thompson) (CACM 1968), the Pike
VM, Cox's [Regular Expression Matching Can Be Simple And Fast](#r-cox-re1),
and [RE2](#r-re2). Unicode range compilation follows the Thompson/Cox UTF-8
decomposition used by RE2 and [rust-regex](#r-rust-regex) (eager byte-class
DFA here; rust-regex's lazy-per-haystack powerset is a recorded trade).
Caseful `-F` presence uses a memchr-style first+last-byte SIMD gate after
[BurntSushi/memchr](#r-memchr).

Complex constructs use the vendored [PCRE2](#r-pcre2) engine with JIT and
resource caps. Gist does not claim to make backtracking expressions linear;
`-P` deliberately selects PCRE2 semantics, while `--engine auto` keeps the
linear engine whenever it can express the pattern.

---

## 7. Ranking

The bounded result view (`--rank`) uses weighted Reciprocal Rank Fusion from
Cormack, Clarke, and Büttcher ([SIGIR 2009](#r-rrf)). Its inputs are
language-agnostic text and path signals (lexical density, declaration-shaped
boost, path depth, authored-vs-generated). A declaration-shaped boost is not
a symbol table.

---

## 8. N-gram and regex-index literature

The relevant research predates Gist and establishes both the design space and
its limits:

- [Cho & Rajagopalan 2002](#r-cho) — selective multi-gram indexes for regex
- [Kim et al. 2010](#r-kim) — posting-list plans for q-gram substring search
- [Cox 2012](#r-cox-trigram) — direct code-search construction + open impl
- [PostgreSQL `pg_trgm`](#r-pg-trgm) — color-trigram graph from the regex CFA
- [RE2](#r-re2) `FilteredRE2` / `PrefilterTree` — required-atom presence filter
- [SWE at Google ch. 17](#r-swe17) — trigrams → suffix arrays → sparse n-grams
- [Gibney & Thankachan 2021](#r-gibney) — conditional lower bounds for regex indexing
- [Zhang et al. 2025](#r-zhang) — modern n-gram selection strategies (PVLDB)

The whole trigram/n-gram _presence_ family — csearch, pg_trgm, RE2's
prefilter, Zoekt, Blackbird, gist's own — shares one blind spot: literal-free
class repetitions concede a full scan. That hole is Crest's object — see
[`../crest/PRIOR_ART.md`](../crest/PRIOR_ART.md).

---

## 9. Precise novelty statement

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
quietly drop this file. When a citation lands in shipped code or a face
README, it must appear here (or in the crest/relate sibling dossiers when
that face owns the object). Where prose lags the binary, `gist --schema`, the
live differential harness, and the committed certificate are authoritative.

---

## References

Annotated bibliography for every external source above. Anchor ids match the
in-body citation links.

<span id="r-cursor-search"></span>

1. **Cursor.**
   [Agent search documentation](https://cursor.com/docs/agent/tools/search).
   _Annotation:_ Agent-selected Instant Grep + semantic retrieval + file
   reads — gist owns only the deterministic exact/regex leg.

<span id="r-cursor-semsearch"></span> 2. **Cursor.**
[Semantic search report](https://cursor.com/blog/semsearch).
_Annotation:_ Hybrid grep + embedding evaluation; gist does not claim
the semantic half.

<span id="r-tgrep"></span> 3. **Microsoft tgrep.**
[github.com/microsoft/tgrep](https://github.com/microsoft/tgrep).
_Annotation:_ Closest public local-agent trigram+grep shape;
client/server + watchers — gist keeps cold subprocess authoritative.

<span id="r-trigrep"></span> 4. **Moderne Trigrep.**
[moderne.ai — Trigrep](https://www.moderne.ai/moderne-agent-tools/trigrep).
_Annotation:_ Org-scoped multi-repo search over Zoekt-compatible indexes
enriched from OpenRewrite LSTs — portfolio plane gist does not have.

<span id="r-trigrep-docs"></span> 5. **Moderne.**
[Trigrep user documentation](https://github.com/moderneinc/moderne-docs/blob/main/docs/user-documentation/agent-tools/trigrep.md).
_Annotation:_ Query dialects, structural filters, CLI/MCP delivery for
Trigrep.

<span id="r-ripgrep"></span> 6. **BurntSushi / ripgrep.**
[github.com/BurntSushi/ripgrep](https://github.com/BurntSushi/ripgrep).
_Annotation:_ Primary CLI mental model and live rgsuite oracle —
ignore dialect, exit codes, Unicode defaults; gist is a tested subset.

<span id="r-ugrep"></span> 7. **ugrep.**
[github.com/Genivia/ugrep](https://github.com/Genivia/ugrep).
_Annotation:_ PCRE-capable scanner peer — lookaround/backrefs by tree
walk, no sound candidate index.

<span id="r-ag"></span> 8. **The Silver Searcher (ag).**
[github.com/ggreer/the_silver_searcher](https://github.com/ggreer/the_silver_searcher).
_Annotation:_ Fast code-oriented scanner; peer in the unindexed PCRE
half of the field.

<span id="r-gnu-grep"></span> 9. **GNU grep.**
[gnu.org/software/grep](https://www.gnu.org/software/grep/).
_Annotation:_ `grep -P` PCRE scan path — same capability class as
ripgrep/ugrep without an index.

<span id="r-git-grep"></span> 10. **git grep.**
[git-scm.com/docs/git-grep](https://git-scm.com/docs/git-grep).
_Annotation:_ VCS-scoped scanner; peer for PCRE/`-P` workloads that
never build a persisted candidate index.

<span id="r-cox-trigram"></span> 11. **Cox (2012).**
[_Regular Expression Matching with a Trigram Index_](https://swtch.com/~rsc/regexp/regexp4.html).
_Annotation:_ Required-trigram extraction + Boolean candidate query +
verify — direct algorithmic ancestry for gist's candidate index.

<span id="r-codesearch"></span> 12. **Google codesearch.**
[github.com/google/codesearch](https://github.com/google/codesearch).
_Annotation:_ Open `cindex` / `csearch` implementation of Cox's design.

<span id="r-zoekt"></span> 13. **Zoekt.**
[github.com/sourcegraph/zoekt](https://github.com/sourcegraph/zoekt).
_Annotation:_ Production positional-trigram code search with ranking and
multi-repo shards — hosted scale gist does not claim.

<span id="r-zoekt-design"></span> 14. **Zoekt.**
[Design document](https://github.com/sourcegraph/zoekt/blob/main/doc/design.md).
_Annotation:_ Index layout and query planning details for Zoekt.

<span id="r-sourcegraph"></span> 15. **Sourcegraph.**
[Admin architecture](https://sourcegraph.com/docs/admin/architecture).
_Annotation:_ Platform around Zoekt — sync, permissions, navigation;
gist is a local locator only.

<span id="r-blackbird"></span> 16. **GitHub.**
[The technology behind GitHub's new code search](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/).
_Annotation:_ Blackbird — sparse variable-length n-grams at global
scale; gist uses fixed local trigrams.

<span id="r-blackbird-hist"></span> 17. **GitHub.**
[A brief history of code search at GitHub](https://github.blog/engineering/architecture-optimization/a-brief-history-of-code-search-at-github/).
_Annotation:_ Blob dedup and symbol-metadata history for GitHub search.

<span id="r-livegrep"></span> 18. **livegrep.**
[github.com/livegrep/livegrep](https://github.com/livegrep/livegrep).
_Annotation:_ Interactive RE2 over prebuilt indexes via a long-running
backend — shared-repo scale, not agent working-tree loop.

<span id="r-hound"></span> 19. **Hound.**
[github.com/hound-search/hound](https://github.com/hound-search/hound).
_Annotation:_ Per-repo trigram index + Go API/UI following Cox; gist
omits the service/browser face.

<span id="r-qgrep"></span> 20. **zeux/qgrep.**
[github.com/zeux/qgrep](https://github.com/zeux/qgrep).
_Annotation:_ Searches a compressed indexed _copy_ of source; gist
keeps live files authoritative for grep-shaped search. (Codex /
Shannon–Manzini self-index literature → relate dossier.)

<span id="r-lsp"></span> 21. **Language Server Protocol 3.17.**
[Specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/).
_Annotation:_ Live editor↔server symbols/defs/refs — semantic
intelligence, not byte/regex search.

<span id="r-lsif"></span> 22. **LSIF.**
[lsif.dev](https://lsif.dev/).
_Annotation:_ Persisted code-intelligence format (archived; SCIP
successor).

<span id="r-scip"></span> 23. **SCIP.**
[github.com/scip-code/scip](https://github.com/scip-code/scip).
_Annotation:_ Language-agnostic persisted navigation protocol —
definitions/refs/impls, not grep.

<span id="r-ctags"></span> 24. **Universal Ctags.**
[github.com/universal-ctags/ctags](https://github.com/universal-ctags/ctags).
_Annotation:_ Compact tag indexes for symbol navigation; gist's
`--rank` boost is not a tag database.

<span id="r-semgrep"></span> 25. **Semgrep.**
[Philosophy](https://semgrep.dev/docs/contributing/semgrep-philosophy).
_Annotation:_ Syntax-aware pattern matching for analysis — compose with
gist, do not conflate.

<span id="r-astgrep"></span> 26. **ast-grep.**
[ast-grep.github.io](https://ast-grep.github.io/).
_Annotation:_ tree-sitter structural search/lint/rewrite.

<span id="r-comby"></span> 27. **Comby.**
[comby.dev](https://comby.dev/).
_Annotation:_ Lightweight language-aware templates for structural
search and replacement.

<span id="r-openrewrite"></span> 28. **OpenRewrite.**
[docs.openrewrite.org](https://docs.openrewrite.org/).
_Annotation:_ Recipe-driven automated refactoring over LSTs.

<span id="r-lst"></span> 29. **OpenRewrite.**
[Lossless Semantic Trees](https://docs.openrewrite.org/concepts-and-explanations/lossless-semantic-trees).
_Annotation:_ Format-preserving, type-attributed ASTs — Trigrep
enrichment source; not gist's index.

<span id="r-thompson"></span> 30. **Thompson (1968).**
[_Regular Expression Search Algorithm_](https://doi.org/10.1145/363347.363387)
(CACM).
_Annotation:_ Linear-time NFA simulation ancestry for the default
matcher lane.

<span id="r-cox-re1"></span> 31. **Cox.**
[_Regular Expression Matching Can Be Simple And Fast_](https://swtch.com/~rsc/regexp/regexp1.html).
_Annotation:_ Pike-VM / RE2-family linear matching pedagogy gist
follows for the default engine.

<span id="r-re2"></span> 32. **RE2.**
[github.com/google/re2](https://github.com/google/re2).
_Annotation:_ Production linear regex engine; FilteredRE2 is the
presence-prefilter cousin Crest complements.

<span id="r-rust-regex"></span> 33. **rust-regex.**
[github.com/rust-lang/regex](https://github.com/rust-lang/regex).
_Annotation:_ UTF-8 range decomposition lineage and lazy powerset
trade that gist's eager DFA knowingly differs from.

<span id="r-memchr"></span> 34. **BurntSushi / memchr.**
[github.com/BurntSushi/memchr](https://github.com/BurntSushi/memchr).
_Annotation:_ Generic SIMD first+last-byte presence gate behind
caseful `-F` (`scan/simd.zig`).

<span id="r-pcre2"></span> 35. **PCRE2.**
[pcre.org documentation](https://www.pcre.org/current/doc/html/).
_Annotation:_ Vendored backtracking engine for `-P` / `--engine auto`
(lookaround, backreferences) with resource caps.

<span id="r-rrf"></span> 36. **Cormack, Clarke & Büttcher (2009).**
[_Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning Methods_](https://doi.org/10.1145/1571941.1572114)
(SIGIR).
_Annotation:_ Weighted RRF behind gist's bounded `--rank` view —
heuristic text ranking, not name resolution.

<span id="r-cho"></span> 37. **Cho & Rajagopalan (2002).**
[_A Fast Regular Expression Indexing Engine_](https://doi.org/10.1109/ICDE.2002.994755)
(ICDE).
_Annotation:_ Selective multi-gram indexes for regex filtering —
presence-family literature.

<span id="r-kim"></span> 38. **Kim, Woo, Park & Shim (2010).**
[_Efficient processing of substring match queries with inverted q-gram indexes_](https://doi.org/10.1109/ICDE.2010.5447866)
(ICDE).
_Annotation:_ Posting-list plans for q-gram substring search.

<span id="r-pg-trgm"></span> 39. **PostgreSQL `pg_trgm`.**
[`trgm_regexp.c` (source)](https://github.com/postgres/postgres/blob/master/contrib/pg_trgm/trgm_regexp.c).
_Annotation:_ Color-trigram graph from the regex CFA — same no-literal
degeneration to full scan as Cox/Zoekt.

<span id="r-swe17"></span> 40. **Google.**
[_Software Engineering at Google_, chapter 17](https://abseil.io/resources/swe-book/html/ch17.html).
_Annotation:_ Production Code Search evolution: trigrams → suffix
arrays → sparse n-grams; index-size/query-cost trade-off.

<span id="r-gibney"></span> 41. **Gibney & Thankachan (2021).**
[_Text Indexing for Regular Expression Matching_](https://doi.org/10.3390/a14050133)
(_Algorithms_).
_Annotation:_ Conditional lower bounds and preprocessing/query
trade-offs for general regex indexing.

<span id="r-zhang"></span> 42. **Zhang et al. (2025).**
[_An Evaluation of N-Gram Selection Strategies for Regular Expression Indexing_](https://www.vldb.org/pvldb/vol18/p5703-zhang.pdf)
(PVLDB).
_Annotation:_ Modern n-gram _selection_ over the same presence test —
still concedes the literal-free class-repetition hole (Crest's object).
