---
doc_radar:
  counts:
    - description: "thin CLI face keeps its four command packages"
      glob: pkg/kernels/irregex/src/surface/face/gist/*/
      equals: 4
      unit: dirs
  sentinels:
    - description: "entrypoint still exposes search, index, codex, status, and resident service"
      file: pkg/kernels/irregex/src/surface/face/gist/main.zig
      contains:
        - "const indexer = gist.commands.indexer;"
        - "const codex_face = gist.commands.codex;"
        - "const search = gist.commands.search;"
        - "const serve = gist.commands.serve;"
        - "const client = gist.commands.client;"
    - description: "the public flag surface still comes from one compatibility catalog"
      file: pkg/kernels/irregex/src/surface/exec/cold/argv/args.zig
      contains:
        - "pub const flag_catalog"
        - "supported_with_differences"
        - "accepted_but_ignored"
        - "unsupported_fail_loud"
    - description: "all three search transports remain operational"
      file: pkg/kernels/irregex/contract/search_api.toml
      contains:
        - 'subprocess = { status = "authoritative"'
        - 'uds = { status = "operational-accelerator"'
        - 'ffi = { status = "operational-accelerator"'
    - description: "the committed fail-closed certificate exists and is fail-closed"
      file: pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
      contains: "a win requires a lower median AND p<0.05"
---

# `gist`: indexed regex search for a live working tree

`gist` is where my bit-level idea became a tool. Text is bits; a required
trigram is a small proof that most files cannot match. Instead of reading them
all, gist rules those files out, then checks every survivor against current
bytes.

I kept ripgrep's useful mental model because that muscle memory is already
embedded in how agents search: pattern, paths, familiar flags, stdout
results, and 0/1/2 exit codes. Preserving that familiarity is why I treated
parity as a product constraint rather than a loose resemblance. Then I added
three things for the agent loop:

1. a persisted candidate index that can prove most files are irrelevant —
   required trigrams, plus a crest sidecar for the class-repetition patterns
   trigrams cannot see;
2. a fail-open resident session that avoids cold startup when the request is
   eligible; and
3. a bounded, definition-biased ranked view for questions where the best hit
   matters more than every hit.

The rule is simple: the tree tells the truth. The persisted index and resident
daemon can save work, but they cannot invent a file set or return stale
content. If an accelerator cannot prove its answer is safe, gist walks the live
tree.

That product thesis, the competitive ancestry behind it, and the gates that
try to falsify it are separated into
[`CLAIM.md`](../../../research/gist/CLAIM.md),
[`PRIOR_ART.md`](../../../research/gist/PRIOR_ART.md), and
[`TESTING.md`](../../../research/gist/TESTING.md). This README explains the
shipped instrument; the dossier explains why its claims deserve belief.

## Quickstart

```bash
make install-gist                    # ReleaseFast binaries, PATH link, trigram index

gist 'SearchRequest'                 # search from the current directory
gist 'SearchRequest' services -n     # explicit scope, line numbers
gist 'SearchRequest' -l              # matching paths only
gist 'SearchRequest' --rank          # best definitions and uses, default top 20
gist 'foo(?=bar)' -P                 # vendored PCRE2: lookaround/backreferences
gist 'foo(?=bar)' --engine auto      # linear first, PCRE2 only if required
gist 'begin.*end' -U                 # multiline mode
gist 'needle' --no-index             # force a pure live walk

gist status --json                  # versioned index/freshness snapshot
gist index                          # rebuild the persisted candidate index
gist serve [ROOT...]                # run the resident UDS service explicitly

gist codex build
gist codex count 'literal'           # exact corpus-wide occurrence count
gist codex tally 'literal' --top 20  # per-file counts, heaviest first
gist codex status

gist --help
gist --schema                        # machine-readable flags and compatibility
```

No index is required. Without one, `gist` scans the live tree. With a covering
index, it automatically skips files that cannot contain the query's required
trigrams and verifies every candidate against current bytes.

`gist rg …` and `gist search …` are aliases for the same search engine. The
canonical form is intentionally verbless.

## Ergonomics: keep the reflex, choose the native shape

Gist has two ergonomic lanes. The **muscle-memory lane** lets a person or agent
replace `rg` with `gist` without stopping to translate the search. The
**native lane** is for an intent ripgrep does not name: rank the best code hit,
force the differential oracle, reuse a warm corpus, or query the compressed
codex. Start in the first lane; cross over only when the question changes.

| Intent | Muscle-memory form | Gist-native choice |
| --- | --- | --- |
| Find matching lines | `rg PATTERN [PATH...]` | `gist PATTERN [PATH...]` |
| Narrow the corpus | `-t`, `-T`, `-g`, `--iglob`, explicit paths | same flags and positional paths |
| Shape familiar output | `-n`, `-l`, `-c`, `-o`, `-A/-B/-C`, `--json` | same output contract |
| Find the best definition or use | inspect ordinary grep output | `--rank[=N]` |
| Use lookaround or backreferences | `-P` | `-P`, or `--engine auto` to escalate only when needed |
| Prove acceleration changed nothing | run another scanner | `--no-index`; its answer is the oracle for the indexed path |
| Avoid repeated startup | external wrapper or server | do nothing; eligible searches transparently use the resident session |
| Count an exact literal without source-file I/O | scan the tree | `gist codex count LITERAL` on a clean shelf |
| Ask what this binary supports | prose or remembered flags | `gist --schema`, generated from the live flag catalog |

### The default move

For both humans and coding agents, the shortest correct sequence is:

1. Type the search you already know: `gist PATTERN [PATH...]`.
2. Scope early when you know the neighborhood: a positional path, `-t TYPE`,
   or `-g GLOB` saves output as well as work.
3. Choose the smallest answer that serves the next step: `-q` for existence,
   `-l` for files, `-c` for per-file counts, ordinary lines for reading, and
   `--rank` when one strong code location matters more than completeness.
4. Stay on the linear engine by default. Use `--engine auto` when a pattern may
   need PCRE2, and `-P` when PCRE2 semantics are the requirement.
5. Let Gist choose acceleration. Reach for `--no-index` only to debug or prove
   parity, `gist status` to inspect freshness, and `gist index` after a large
   tree change when you want to re-anchor performance.
6. Read stderr after a miss. Suggestions and budget notices never contaminate
   stdout, so a person can learn from them while a pipeline keeps rg-shaped
   bytes.

The aliases `gist rg` and `gist search` exist for callers that require a verb,
not because they unlock a different engine. Agents should emit the bare form:
it is shorter, canonical, and leaves the pattern in the same argv position as
ripgrep.

### Niche choices that prevent wrong searches

- **Case and character semantics:** `-i`, `-s`, and `-S` are last-wins.
  Unicode folding, classes, properties, and word boundaries are the default;
  `--no-unicode` or a leading `(?-u)` deliberately selects byte/ASCII
  semantics. Under PCRE2, `--pcre2-unicode` and
  `--no-pcre2-unicode` control that backend separately.
- **Literal, word, line, and inverse matching:** use `-F` when punctuation
  should not become regex, `-w` for a whole Unicode word, `-x` for a whole
  line, and `-v` for non-matching lines. Multiple intents use repeated `-e` or
  a pattern file with `-f`.
- **Hidden and ignored files:** `-u`, `-uu`, and `-uuu` progressively disable
  ignores, add hidden paths, and include binary data. An explicit `-g` or
  `--iglob` include can whitelist an ignored path; a type filter can unhide a
  matching dotfile but does not override gitignore.
- **The `-rn` trap:** recursion is already the default, and ripgrep semantics
  parse bundled `-r` as replacement. `gist -rn PATTERN` therefore means
  `--replace=n`, not “recursive with line numbers.” Spell `-n` alone; Gist
  preserves the behavior for parity but emits a diagnostic.
- **Zero is sometimes a real value:** explicit `-m0` means match nothing and
  exits 1; omitting `-m` means unlimited. Likewise `-M0` explicitly disables
  the long-line cap.
- **Stable ordering:** the default streams in fast parallel discovery order.
  Use `--sort path|modified|accessed|created` or `--sortr` only when stable
  global order is part of the consumer's contract.
- **Unusual input:** `-z` searches compressed files; `--pre CMD` searches a
  preprocessor's stdout and takes precedence over `-z`; `-E/--encoding`
  accepts `auto`, `none`, or the checked-in WHATWG label set. Unknown labels
  and failing preprocessors exit 2 rather than looking like empty searches.
- **Binary intent:** `-a` treats input as text. `--binary` and `-uuu` search a
  binary file in full and print every matching line, intentionally differing
  from ripgrep's one-line binary summary.
- **Machine output:** use `--json` for typed records, `-0` for NUL-delimited
  paths, `--null-data` for NUL-delimited input records, and explicit sorting
  when downstream comparison requires deterministic file order.
- **Agent budgets:** prefer `--rank`, `-l`, `-c`, a narrower path, or `-m N`
  before lifting the soft output guard. `--uncap` or `GIST_UNCAP=1` is the
  deliberate escape hatch; `GIST_HINTS=0` mutes guidance without changing
  results.
- **Warm and codex paths:** the resident session is an invisible, fail-open
  accelerator; unsupported shapes simply stay cold. The codex is different:
  use it only for exact literal `count`/`tally` questions, and treat absence as
  proven only when `gist codex status` reports a clean shelf.

This section teaches selection, not a second flag registry. The checked-in
`flag_catalog` and `gist --schema` remain the exhaustive, versioned answer.

## The search contract

The cold runtime's
[`flag_catalog`](../../runtime/cold/argv/args.zig) is the source of truth for both argv
handling and `gist --schema`. It separates the public surface into exact
support, support with documented differences, accepted no-ops, and unknown
flags that fail with exit 2. I do **not** claim every option ripgrep ever
shipped.

The implemented surface includes:

- regular, fixed (`-F`), smart-case (`-S`), case-insensitive (`-i`), whole-word
  (`-w`), inverted (`-v`), and multiple (`-e`/`-f`) patterns;
- Unicode-by-default case folding, character classes, properties, and word
  boundaries, with `(?-u)` or `--no-unicode` for byte/ASCII semantics;
- the linear RE2/Pike engine, vendored PCRE2 10.47 with JIT (`-P`), and
  `--engine auto` escalation;
- native multiline search (`-U`, `--multiline-dotall`);
- path, type, glob, hidden-file, symlink, depth, size, filesystem, and the full
  `.gitignore`/`.ignore`/`.rgignore` control family;
- context, only-match, count, replacement, heading, column, byte-offset,
  vimgrep, JSON Lines, null-delimited, sorted, and stats output;
- stdin, UTF BOM detection, the WHATWG encoding label set, preprocessing, and
  compressed-file search.

Normal results go to stdout. Diagnostics, timing, output-budget notices, and
no-match suggestions go to stderr. `GIST_HINTS=0` disables suggestions without
touching results.

Search exit codes follow ripgrep:

- `0`: at least one match;
- `1`: a clean search with no match;
- `2`: invalid argv, unsupported syntax, an unreadable path, or another search
  error.

An unknown flag or a pattern rejected by the selected engine is therefore an
error, never a convincing empty result.

### Deliberate differences

These are current product choices, not unfinished claims:

- The parallel walk may discover independent files in a different order.
  Explicit `--sort`/`--sortr` requests are globally ordered after parallel
  reads.
- `--binary` and `-uuu` search a binary file in full instead of emitting
  ripgrep's one-line binary summary.
- `--type-list` is formatted like ripgrep but describes gist's strict superset
  of the type registry.
- `-j` caps gist's adaptive work-stealing pool; it is not a promise to copy
  ripgrep's scheduler.
- `-z` decodes gzip, zlib, zstd, and xz in-process; bzip2, lz4, Brotli, and
  other supported formats use their standard external decoders. `--pre`
  passes the path as argv 1 with stdin closed.
- `--mmap`, `--no-mmap`, `--colors`, `--dfa-size-limit`, and
  `--regex-size-limit` are accepted compatibility no-ops. Color uses gist's
  own palette.
- Agent-facing output has a soft budget of roughly 25k tokens / 100 KiB and a
  hard 256 MiB ceiling. `--uncap` or `GIST_UNCAP=1` lifts the soft limit.

For an exact, versioned answer about a flag, inspect `gist --schema` rather
than relying on a prose list.

## Three execution paths, one answer

### Cold subprocess: authoritative

I keep the normal process as the path that can answer every request:

```text
argv → parse → compile → walk → index read-elision → verify → emit
```

The walk chooses the files. The index only removes provable non-candidates.
Files changed since the index anchor are read live; missing coverage simply
reduces acceleration. `--no-index` is the differential oracle for this
invariant.

### Resident UDS session: fail-open accelerator

To stop paying startup costs, `gist serve` holds corpus bytes and a trigram
index behind a per-repository Unix socket. The CLI may auto-spawn it after an
eligible cold miss. The request classifier deliberately keeps the warm surface
small. This table is a readable snapshot; `runtime/session/request.zig` remains
the executable authority:

| warm-eligible CLI shape                    | stays authoritative-cold                                      |
| ------------------------------------------ | ------------------------------------------------------------- |
| rootless line output (`-n` / `-N` allowed) | any explicit path, including `.`                              |
| rootless `-l` / `--files-with-matches`     | stdin or TTY stdout                                           |
| `-F`, `-i` / `-s` / `-S`, `-w`             | context, JSON, rank, replace, multiline, PCRE2, globs, invert |
| existence/caps via `-q`, `-m N`            | malformed or unrepresentable flag values                      |

The wire contract also defines a count mode, but CLI `-c` keeps ripgrep's
per-file layout and stays cold. Warm I/O has a two-second deadline;
`GIST_NO_AUTOSERVE=1` disables automatic session startup. Eligibility is an
optimization decision, never a support boundary.

Freshness is fail-closed. macOS FSEvents or Linux inotify can narrow the work,
but a reconcile barrier decides whether resident bytes are safe. Doubt,
overflow, an index generation change, or a walk error declines the warm answer
and returns to the subprocess. See the
[`ResidentSession`](../../runtime/session/README.md) invariant.

### In-process FFI: embedders

For embedders, the C ABI (`irregex_open` / `irregex_search` /
`irregex_close`) streams match records from the same error-returning resident
engine. Python uses it when the shared library and optional cffi are available,
then falls open to UDS or subprocess. It is another route to the same matcher,
not a second implementation.

The cross-face request and transport contract is
[`contract/search_api.toml`](../../../contract/search_api.toml).

## The two indexes do different jobs

I use two indexes because they answer different questions. The ordinary trigram
index is a **candidate filter**. It is small, mmap-backed, and fast, but every
candidate still needs its current bytes checked. This is the index behind
normal regex search. Riding beside it is the **crest sidecar**: sixteen bytes
per file recording its longest run in each byte-class, which prunes the
literal-free class repetitions (`[0-9a-f]{12}`, `[0-9]{6}`) that extract no
trigram at all. That one is my own math — a sound forced-run necessary
condition, proof and measurements in
[`research/crest/`](../../../research/crest/PROOF.md). Both filters only ever
skip reads; caseless queries, changed files, and a missing sidecar all fall
back to reading.

The codex shelf is a **compressed self-index** for exact literal questions. It
can count in O(pattern length), locate occurrences, recover the indexed corpus,
and answer without opening source files. `gist codex count` is a proof of
absence only when the shelf's freshness report is clean; the command reports
files changed since the shelf was built rather than hiding that qualification.
See [`index/codex`](../../index/codex/README.md).

## Ranked search

Sometimes I need the best hit, not every hit. `--rank[=N]` keeps the same
pattern and path semantics but changes the answer shape. Weighted Reciprocal
Rank Fusion combines lexical density, graded declaration confidence,
match-shape rarity, shallow-path preference, and generated/mirrored-file
demotion; embedders may add graph rank. The default top K is 20:

```text
1. path:line  [def|use|gen|mirror]  ×count  source line
```

This is heuristic text ranking, not name resolution or semantic code
intelligence. It works from the persisted index when possible and has a live
walk fallback; `--rank` is limited to the linear engine.

## Evidence

The idea is mine; the expected answers are not. The ripgrep muscle-memory
promise is why I compare gist with a live `rg` oracle instead of writing
expectations by hand. The gates cover parallel and serial walks, indexed versus
`--no-index`, freshness, line framing, Unicode, multiline and PCRE2 modes,
ordering/ignore flags, encodings, preprocessing, compressed input, binary
handling, streams, and resident-versus-cold answers.

The tracked ripgrep 15.1.0 snapshot contains 441 invocations per walk engine:

- **Mined upstream suite:** 391 PASS, 0 ORDER, 14 FAIL, 16 NA, and 20 SKIP.
  Supported-surface parity is **391/405 = 96.5%**, not 100%; every known
  divergence remains visible and assigned.
- **Multiline:** 30/30 adversarial cases pass for stdout, exit code, and
  indexed-versus-`--no-index` equality.
- **PCRE2:** 30/30 adversarial cases pass the same three-way oracle, including
  lookaround, backreferences, Unicode toggles, and resource-limit failures.
- **Walk and ignore flags:** 26/26 cases pass on each engine. The fixtures make
  path/time ordering, last-wins negations, worker counts, device boundaries,
  and global git-ignore state observable.
- **Content transforms:** 22/22 cases pass on each engine across preprocessing,
  binary input, legacy encodings, and the available gzip, bzip2, xz, zstd, lz4,
  and Brotli decoders.

Parallel and serial results are reported separately because they share a
contract but not an implementation path; they are not added together to
inflate the case count. NA is a deliberate product boundary. SKIP is an
accounted companion, boundary, or irreplayable obligation. Neither is called a
pass, and `--allow-fail` never converts the 14 known failures into success.

Reproduce the cited results from
[`bench/rgsuite`](../../../bench/rgsuite/README.md):

```bash
python3 run.py
python3 modes.py run --mode multiline
python3 modes.py run --mode pcre
python3 flags.py run
python3 transforms.py run
```

The permanent integration order is documented in
[`bench/gates`](../../../bench/gates/README.md): correctness gates run before
performance gates, so a faster wrong answer cannot earn a benchmark win.

Performance claims come from the committed fail-closed certificate: fresh
processes, 20 measured runs after three warmups, bootstrap 95% confidence
intervals on medians, and a Mann–Whitney test. A win requires both a lower
median and p < 0.05. On its recorded 17,739-file / 166.1 MiB corpus, gist beat
ripgrep in all 12 query classes by 1.97×–23.57×. Those are measurements from
the **macroscopic end-to-end layer**, not universal constants. The certificate's
microscopic cycles/byte and lower-bound layers use a separate ~22.8k-file /
~223.8 MiB in-memory corpus; their corpus size must not be attached to the
end-to-end speedups.

![gist fail-closed statistical certificate forest plot](../../../assets/gist-certify-forest.png)

The full data, machine description, losses against other indexed tools, and
rerun procedure live in
[`bench/certify/artifact/CERTIFICATE.md`](../../../bench/certify/artifact/CERTIFICATE.md)
and [`bench/README.md`](../../../bench/README.md).

## Research claim and prior art

Most of the pieces are borrowed and cited. I joined them for one specific job:
searching a local, constantly changing tree over and over for coding agents.
The positive product case and precise composition claim live in
[`CLAIM.md`](../../../research/gist/CLAIM.md). The contribution is that
measured composition, the contract around it—and one genuinely new piece of
math where the field had a hole (the Crest sieve, below).

### Candidate indexing

The direct ancestor is Russ Cox's
[Regular Expression Matching with a Trigram Index](https://swtch.com/~rsc/regexp/regexp4.html)
and [Google Code Search](https://github.com/google/codesearch): extract required
trigrams, intersect postings to obtain a sound candidate superset, then verify
the actual regex against candidate bytes. Gist uses that index only for
read-elision; the live walk and freshness overlay remain authoritative.

The whole trigram family shares one blind spot: a pattern with no required
literal — `[0-9a-f]{12}` and its class-repetition kin — yields no trigrams and
degenerates to a full scan. The crest sieve is my answer, and it is the one
place in gist where the math is new rather than borrowed: a per-file
longest-run-per-class signature paired with a forced-run lower bound derived
from the regex itself. Theorem, calculus, refereed prior-art review, and the
fail-closed corpus proof live in
[`research/crest/`](../../../research/crest/PROOF.md).

[Zoekt](https://github.com/sourcegraph/zoekt) is the closest production indexed
code-search comparison: positional trigrams, regex planning, ranking, mmapable
shards, and a serving layer. GitHub's
[Blackbird](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/)
extends the same family with sparse variable-length n-grams and global-scale
sharding. Gist claims neither distributed search nor organization-wide
repository synchronization.

[Microsoft tgrep](https://github.com/microsoft/tgrep) is the nearest public
local-agent shape: a persistent trigram index, file watching, client/server
operation, and a grep-like CLI. Gist's distinguishing contract is narrower:
accelerators may decline, while a current-tree subprocess remains capable of
answering every supported request.

### Matching engines

The linear lane descends from Thompson's
[Regular Expression Search Algorithm](https://doi.org/10.1145/363347.363387)
(CACM 1968), the Pike VM, Cox's
[Regular Expression Matching Can Be Simple And Fast](https://swtch.com/~rsc/regexp/regexp1.html),
and [RE2](https://github.com/google/re2). Unicode range compilation follows
the Thompson/Cox UTF-8 decomposition used by RE2 and rust-regex.

Complex constructs use the vendored
[PCRE2](https://www.pcre.org/current/doc/html/) 10.47 engine with JIT and
resource caps. Gist does not claim to make backtracking expressions linear;
`-P` deliberately selects PCRE2 semantics, while `--engine auto` keeps the
linear engine whenever it can express the pattern.

### Ranking

The bounded result view uses weighted Reciprocal Rank Fusion from Cormack,
Clarke, and Büttcher,
[Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning
Methods](https://doi.org/10.1145/1571941.1572114) (SIGIR 2009). Its inputs are
language-agnostic text and path signals. A declaration-shaped boost is not a
symbol table: gist does not resolve types, references, overloads, or call
graphs, and it is not an LSP, SCIP, or semantic-retrieval engine.

### The codex subcommand

`gist codex` is a thin lifecycle face over the shared compressed self-index
(`count` / `find` / shelf status). The Shannon–Manzini / FM-index bibliography
and novelty framing live with `relate` —
[`research/relate/PRIOR_ART.md`](../../../research/relate/PRIOR_ART.md) §
Corpus quotation — and [`index/codex`](../../index/codex/README.md).

### Outside the claim

I keep the boundary sharp. Gist is not structural search (Semgrep, ast-grep,
Comby), a format-preserving
transformation system (OpenRewrite), semantic code intelligence (LSP/SCIP), or
a hosted multi-repository platform (Sourcegraph/GitHub Code Search). It is the
exact/regex leg those systems and agents can compose with.

The full landscape—unindexed peers, indexed neighbors, matcher/ranking
ancestry, and semantic/structural systems—lives in
[`PRIOR_ART.md`](../../../research/gist/PRIOR_ART.md). The positive product
thesis lives in [`CLAIM.md`](../../../research/gist/CLAIM.md); the exact
evidence inventory and known losses live in
[`TESTING.md`](../../../research/gist/TESTING.md). Codex /
Shannon–Manzini literature stays with Relate in
[`research/relate/PRIOR_ART.md`](../../../research/relate/PRIOR_ART.md).
Where prose lags implementation, `gist --schema`, the live differential
harness, and the committed certificate are authoritative.

## Package map

- [`main.zig`](main.zig) dispatches the bare search and lifecycle verbs; the
  authoritative search implementation lives in
  [`runtime/cold/`](../../runtime/cold/).
- [`daemon/`](daemon) owns UDS serving, client routing, auto-spawn, and cold
  fallback.
- [`lifecycle/`](lifecycle) owns trigram-index and codex lifecycle commands.
- [`status/`](status) owns read-only index introspection.
- [`schema/`](schema) renders the capability manifest from the flag catalog.

This `main.zig` is only the dispatch shell. The kernel-level map is in
[`src/README.md`](../../README.md), and the freshly built CLI can be run with
`zig build cli -- <args>`.
