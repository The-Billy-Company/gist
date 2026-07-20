# Gist — the composition claim (scope, contract, non-claims)

**Status:** shipped product + measured evidence. CLI face:
`src/cli/gist/`. Authoritative cold path: `src/runtime/cold/`. Public
compatibility contract: `gist --schema` (rendered from
`src/runtime/cold/argv/args.zig` `flag_catalog`). Prior art:
`PRIOR_ART.md`; evidence inventory: `TESTING.md`. Novel crest math:
[`../crest/PROOF.md`](../crest/PROOF.md).

**One sentence.** Persist an optional candidate index over a live working
tree, use it only to skip reads that cannot match, always verify survivors
against current bytes, expose a broad fail-loud ripgrep-compatible CLI
subset, and (when asked) rank hits for an agent's bounded context — measured
so a faster wrong answer cannot earn a win.

---

## 0. What is claimed (and what is not)

### The claim

Gist's contribution is a **systems/workload composition** for one repository
and one high-frequency consumer: coding agents repeatedly issuing small
grep-shaped queries against a concurrently changing tree. It combines:

1. an optional persisted candidate index (trigrams + crest sidecar) with
   fail-open live scanning;
2. a freshness overlay so unindexed edits stay visible;
3. a broad, explicit, fail-loud ripgrep-compatible CLI subset
   (`flag_catalog` → `gist --schema`);
4. definition-biased, generated-code-aware ranking for bounded agent context;
5. a fail-open resident session and in-process FFI that may decline rather
   than invent answers;
6. reproducible correctness and cold-start performance gates (Certificate of
   Optimality layers A–D).

None of those ingredients alone is novel (except the crest sieve — separate
dossier). The value is integrating and measuring them against the agent
search loop without claiming the semantic, hosted, or structural breadth of
the systems in `PRIOR_ART.md`.

### Explicit non-claims

Gist is:

- **not a new indexing algorithm** for the trigram family; document and
  positional n-gram indexes have decades of literature and production use
  (Cox 2012 is direct ancestry);
- **not a claim that every pattern is linear-time**; the default engine is
  RE2/Pike-family linear matching; lookaround, backreferences, and other
  PCRE2-only constructs require `-P` or `--engine auto` escalation, with
  resource caps — backtracking is opted into, never disguised;
- **not a semantic code-intelligence engine**; it does not resolve types,
  definitions, references, or call graphs — `--rank`'s declaration-shaped
  boost is heuristic text ranking, not name resolution;
- **not a Sourcegraph/Moderne/GitHub Code Search replacement**; those systems
  cover hosted multi-repository search, permissions, semantic metadata,
  navigation, governance, and transformation workflows that Gist does not
  attempt;
- **not structural search or rewrite**; Semgrep, ast-grep, Comby, and
  OpenRewrite answer a different class of question.

`gist --schema` is authoritative for the narrower public compatibility
contract. Where any prose (including this dossier) lags the shipped binary,
the schema, the live differential harness, and the committed certificate win.

---

## 1. The public contract

### Flag surface

`src/runtime/cold/argv/args.zig` `flag_catalog` is the single source of truth
for argv handling and `gist --schema`. It buckets every flag into:

| bucket | meaning |
|---|---|
| supported | behavior matches the documented ripgrep-compatible semantics |
| supported_with_differences | accepted; deliberate documented deltas (see CLI README) |
| accepted_but_ignored | compatibility no-ops (e.g. some mmap/color/limit knobs) |
| unsupported_fail_loud | unknown or rejected → exit 2, never a silent empty |

Unicode case folding, `\b`/`\w` word semantics, and character properties are
**default-on** (rg parity); `(?-u)` / `--no-unicode` selects ASCII-byte
semantics. Multiline is native (`-U`). PCRE2 is vendored and selected with
`-P` or auto-escalation.

### Three transports, one answer

| path | role |
|---|---|
| cold subprocess | **authoritative** — can answer every supported request |
| resident UDS session | fail-open accelerator; declines on doubt / overflow / ineligible shape |
| in-process FFI (`irregex_*`) | embedder route to the same resident engine |

Contract: [`contract/search_api.toml`](../../contract/search_api.toml).
Accelerators may save work; they may not invent a file set or return stale
content. `--no-index` is the differential oracle for the index-elision
invariant.

### Exit codes (rg-shaped)

- `0` — at least one match
- `1` — clean search, no match
- `2` — invalid argv, unsupported syntax, unreadable path, or search error

An unknown flag or a pattern rejected by the selected engine is therefore an
error, never a convincing empty result.

---

## 2. Design invariants (load-bearing)

1. **Tree tells the truth.** The walk chooses the files. The index only
   removes provable non-candidates. Files changed since the index anchor are
   read live.
2. **Fail-open acceleration.** Missing index, stale coverage, crest-sidecar
   absence, caseless crest disable, warm-session doubt — all fall back to
   reading current bytes, never to a wrong empty.
3. **Correctness before speed.** `bench/gates/ci_order.sh` runs parity and
   elision gates before the Certificate. A faster wrong answer cannot earn a
   benchmark win.
4. **Fail loud on the unsupported.** The product is a tested subset, not a
   silent partial clone of every ripgrep flag ever shipped.

---

## 3. Relationship to Crest

The trigram family shares one blind spot: patterns with no extractable
literal (`[0-9a-f]{12}` and kin) concede a full scan. The **crest sieve** —
a per-document max-run-per-class signature plus an AST-derived forced-run
lower bound — is the one place inside gist where the *math* is new. Its
theorem, calculus, adversarial prior-art review, and fail-closed corpus proof
live in [`../crest/`](../crest/). This dossier owns the *product* claim
around the agent loop; Crest owns the *necessary-condition* claim for that
literal-free hole.

---

## 4. Standing obligation

The composition claim and non-claims are dated with the shipped surface. If
a prior system already integrates the same measured contract for the same
workload, the correct move is to cite it and re-scope — never to quietly
drop this dossier. Performance numbers are Certificate artifacts, not
universal constants; refresh them with the harness rather than hand-editing
prose.
