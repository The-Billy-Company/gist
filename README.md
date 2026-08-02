# gist: Indexed Regex Search for a Live Working Tree

> [!NOTE]
> The tree tells the truth. The persisted index and the resident daemon can save
> work, but they cannot invent a file set or return stale content.
>
> If an accelerator cannot prove its answer is safe, gist walks the live tree.

- [Overview](#overview)
- [Should I Be Using This?](#should-i-be-using-this)
- [Support](#support)
- [Quickstart](#quickstart)
- [Keeping the Reflex](#keeping-the-reflex)
  - [The Default Move](#the-default-move)
  - [Docs, Code, and Data](#docs-code-and-data)
  - [Choices That Prevent a Wrong Search](#choices-that-prevent-a-wrong-search)
- [The Search Contract](#the-search-contract)
- [Improvements](#improvements)
  - [Binary Files](#binary-files)
  - [Indexed PCRE](#indexed-pcre)
  - [Compressed Input](#compressed-input)
  - [Sorted Output](#sorted-output)
  - [The Type Registry](#the-type-registry)
  - [Hyperlinks](#hyperlinks)
  - [Line Buffering](#line-buffering)
  - [Block Buffering](#block-buffering)
  - [Adjacent Product Choices](#adjacent-product-choices)
- [Three Execution Paths](#three-execution-paths)
  - [The Cold Subprocess](#the-cold-subprocess)
  - [The Resident Session](#the-resident-session)
  - [The In-Process ABI](#the-in-process-abi)
- [The Two Indexes](#the-two-indexes)
- [Ranked Search](#ranked-search)
- [Evidence](#evidence)
- [Prior Art](#prior-art)
  - [Indexed Neighbors](#indexed-neighbors)
  - [Matching Engines](#matching-engines)
  - [Ranking](#ranking)
  - [The Codex Subcommand](#the-codex-subcommand)
  - [Outside the Claim](#outside-the-claim)
- [Package Map](#package-map)
- [Build and Test](#build-and-test)
  - [Running One Test](#running-one-test)
- [Provenance](#provenance)

## Overview

gist is where our bit-level idea became a tool.

Text is bits, and a required trigram is a small proof that most files cannot match.

Instead of reading them all, gist rules those files out, then checks every
survivor against current bytes.

We kept ripgrep's useful mental model because that muscle memory is already
embedded in how agents search: pattern, paths, familiar flags, stdout results,
and 0/1/2 exit codes. Preserving that familiarity is why we treated parity as a
product constraint rather than a loose resemblance.

Then we added three things for the agent loop:

 1. a persisted candidate index that can prove most files are irrelevant, from
 required trigrams plus a crest sidecar for the class-repetition patterns
 trigrams cannot see;
 2. a fail-open resident session that avoids cold startup when the request is
 eligible; and
 3. a bounded, definition-biased ranked view for questions where the best hit
 matters more than every hit.

gist is powered by [`irregex`][irregex], the engine we built this tool on. The
regex engines, the trigram index and the crest sieve beside it, the corpus walk,
the freshness law, and the ranking math all come from there.

What this repository adds is everything with an opinion about a product: the
argv grammar, the resident daemon, distribution, and the parity contract. Read
the engine for why it is shaped the way it is; read this for what the binary
promises.

That product thesis, the competitive ancestry behind it, and the gates that try
to falsify it are separated into [`CLAIM.md`](research/gist/CLAIM.md),
[`PRIOR_ART.md`](research/gist/PRIOR_ART.md), and
[`TESTING.md`](research/gist/TESTING.md). This README explains the shipped
instrument; the dossier explains why its claims deserve belief.

## Should I Be Using This?

- **To search a repository from a terminal, with the flags you already know** –
 here. Type `gist` where you typed `rg`, and start at [Quickstart](#quickstart).
- **For similarity, repetition, or "what is this file like"** – `relate`, a
 separate package. Compression kinship is not a pattern question and this binary
 does not answer it.
- **For the blast radius of a symbol, or where a pasted snippet came from** –
 `blast`, also a separate package. Both of those need current bytes from two
 engines at once.
- **For a linear-time regex to call from Python, Rust, Go, or C** –
 [`irregex`](https://github.com/The-Billy-Company/irregex), which ships the
 bindings and the header. You want the engine, not a command-line tool wrapped
 around one.
- **To embed the search engine itself in a host process** – the
 [C ABI](#the-in-process-abi) here, which streams match records from the same
 resident engine the daemon holds.
- **For structural, semantic, or hosted multi-repository search** – not here at
 all. See [Outside the Claim](#outside-the-claim) for who does answer that.

The dividing line is whether your question is an *exact* one. gist finds the
bytes you can name, quickly, over a tree that is changing underneath it.

Everything it does to go fast is an accelerator that is allowed to decline, and
nothing it returns was decided by anything other than the file's current bytes.

## Support

- Bugs and feature requests go through the
 [issue templates](.github/ISSUE_TEMPLATE), which ask for the pattern, the tree,
 the exact command line, and whether an index or a resident session was warm. A
 search bug without its corpus is a bug nobody can reproduce.
- A place where gist and ripgrep disagree has its own template, `parity_gap`.
 Divergence outside the [improvements](#improvements) bucket is a defect by
 definition, so report it as one rather than as a feature request.
- Security vulnerabilities never go in a public issue. See
 [`SECURITY.md`](SECURITY.md), which also explains why the threat model here
 treats the corpus as the attacker.
- `irregex`, `relate`, and `blast` are separate repositories with their own
 trackers. A wrong match or a wrong file set usually belongs to the engine; the
 argv grammar, the daemon, and the parity contract belong here.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) is the entry point for a change, and
 [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) governs the conversation around it.

## Quickstart

One command builds the binaries, links them onto `PATH`, and writes the trigram
index:

```bash
zig build                    # ReleaseFast binaries, PATH link, trigram index
```

From there the canonical form is the one you already type, with no verb and no
setup:

```bash
gist 'SearchRequest'                 # search from the current directory
gist 'SearchRequest' services -n     # explicit scope, line numbers
gist 'SearchRequest' -l              # matching paths only
gist 'SearchRequest' --rank          # best definitions and uses, default top 20
gist 'foo(?=bar)' -P                 # vendored PCRE2: lookaround/backreferences
gist 'foo(?=bar)' --engine auto      # linear first, PCRE2 only if required
gist 'begin.*end' -U                 # multiline mode
gist 'needle' --no-index             # force a pure live walk
```

Three lifecycle verbs inspect and refresh what the accelerators hold:

```bash
gist status --json                  # versioned index/freshness snapshot
gist index                          # rebuild the persisted candidate index
gist serve [ROOT...]                # run the resident UDS service explicitly
```

The codex is a separate shelf, for exact literal questions answered without
opening source files:

```bash
gist codex build
gist codex count 'literal'           # exact corpus-wide occurrence count
gist codex tally 'literal' --top 20  # per-file counts, heaviest first
gist codex status
```

Everything the binary supports can be asked of the binary rather than of this
document:

```bash
gist --help
gist --schema                        # machine-readable flags and compatibility
gist --generate man                  # gist(1); also complete-{bash,zsh,fish,powershell}
```

No index is required. Without one, `gist` scans the live tree; with a covering
index, it automatically skips files that cannot contain the query's required
trigrams and verifies every candidate against current bytes.

`gist rg …` and `gist search …` are aliases for the same search engine. The
canonical form is intentionally verbless.

`zig build` also links the [Vim/Neovim plugin](editor/vim/README.md) into any
editor already installed, so `:grep` becomes gist and `--vimgrep` output streams
into the quickfix list while the search is still running.

The plugin is a client of this CLI and nothing more. It discovers flags from
`--schema`, file types from `--type-list`, and index state from
`gist status --json`, so a binary upgrade reaches the editor without a plugin
release.

The same install places [`gist(1)` and the shell completions](shell/README.md),
rendered by [`cli/primer/`](src/surface/cli/primer/README.md) from this face's
own flag catalog. `man gist` answers, and `gist -<TAB>` offers a menu captioned
by what each flag changes.

Every closed value set is baked in, so no tab ever forks a process: 241 file
types with their globs, 233 encodings, the engines, sort keys, color postures,
and hyperlink aliases.

## Keeping the Reflex

Gist has two ergonomic lanes, and the first one is the reflex you already have.
The **muscle-memory lane** lets a person or agent replace `rg` with `gist`
without stopping to translate the search.

The **native lane** is for an intent ripgrep does not name: rank the best code
hit, force the differential oracle, reuse a warm corpus, or query the compressed
codex.

Start in the first lane, and cross over only when the question changes.

- **Find matching lines** – `gist PATTERN [PATH...]`, exactly where you would
 have typed `rg PATTERN [PATH...]`.
- **Narrow the corpus** – the same `-t`, `-T`, `-g`, `--iglob`, and explicit
 positional paths, spelled the same way.
- **Read only the paper trail, or only the source** – `--docs`, `--code`, and
 `--data`, plus their `--no-` complements, where ripgrep leaves you
 hand-assembling a dozen `-t` names.
- **Shape familiar output** – `-n`, `-l`, `-c`, `-o`, `-A/-B/-C`, and `--json`,
 on the same output contract.
- **Find the best definition or use** – `--rank[=N]`, rather than inspecting
 ordinary grep output and deciding for yourself.
- **Use lookaround or backreferences** – `-P`, or `--engine auto` to escalate
 only when the pattern needs it.
- **Prove acceleration changed nothing** – `--no-index`, whose answer is the
 oracle for the indexed path, rather than running another scanner.
- **Avoid repeated startup** – nothing at all, since eligible searches
 transparently use the resident session where rg needs an external wrapper or a
 server.
- **Count an exact literal without source-file I/O** – `gist codex count
 LITERAL` on a clean shelf, rather than scanning the tree.
- **Ask what this binary supports** – `gist --schema`, generated from the live
 flag catalog, rather than prose or remembered flags.
- **Read the manual, or tab-complete a flag** – `gist --generate …`, rendered
 from that same catalog, where rg offers `man rg` and hand-written completions.

### The Default Move

For both humans and coding agents, the shortest correct sequence is six steps.

 1. Type the search you already know: `gist PATTERN [PATH...]`.
 2. Scope early when you know the neighborhood, since a positional path,
 `-t TYPE`, or `-g GLOB` saves output as well as work.
 3. Choose the smallest answer that serves the next step: `-q` for existence,
 `-l` for files, `-c` for per-file counts, ordinary lines for reading, and
 `--rank` when one strong code location matters more than completeness.
 4. Stay on the linear engine by default. Use `--engine auto` when a pattern may
 need PCRE2, and `-P` when PCRE2 semantics are the requirement.
 5. Let Gist choose acceleration. Reach for `--no-index` only to debug or prove
 parity, `gist status` to inspect freshness, and `gist index` after a large tree
 change when you want to re-anchor performance.
 6. Read stderr after a miss. Suggestions and budget notices never contaminate
 stdout, so a person can learn from them while a pipeline keeps rg-shaped bytes.

The aliases `gist rg` and `gist search` exist for callers that require a verb,
not because they unlock a different engine.

Agents should emit the bare form. It is shorter, canonical, and leaves the
pattern in the same argv position as ripgrep.

### Docs, Code, and Data

`-t` answers "which language is this?", and that is the wrong grain for the
question anyone actually asks. Nobody wonders whether a file is
reStructuredText; they wonder **"am I reading the paper trail, or am I reading
the implementation?"**

So that is its own corpus axis:

```bash
gist 'SessionStore' --docs      # only prose: what was written ABOUT it
gist 'SessionStore' --no-docs   # only the implementation and its payload
gist 'retry_budget' --data      # only config: json, yaml, toml, lockfiles
gist 'TODO' --code --no-index   # implementation only, no acceleration
```

Three genera (`docs`, `code`, `data`) are total and disjoint over every path, so
`--docs` and `--no-docs` are exact complements and no file can fall through the
partition. Repeats union, so `--docs --data` is either.

Each name is also a type name, so `-t docs` and `-T code` mean the same thing
and compose with `--type-add`. The aliases `prose`, `doc`, and `source` resolve
too, because a name you guess correctly beats one you have to learn.

`code` is the leftover, never a recognized set. An unfamiliar extension, a
generated blob, or a file with no extension at all lands in `code`, so the worst
a gap in the table can do is show `--code` one line too many.

A fourth `unknown` genus excluded from `--code` would turn that same gap into a
*silent miss* instead. Classification is spelling first and location second,
which is why `docs/conf.py` stays code and `CMakeLists.txt` is a build recipe
rather than prose.

That decision is powered by irregex's [genus classifier][ir-genus] and the
totality argument beneath it. What this repository adds is the flag family and
the gates below.

<!-- The path above is an illustrative shape of the rule, not a file here. -->

A genus **narrows** what the walk produced and never un-hides. Unlike `-t` and
`-g` it will not pull a dotfile or a gitignored leaf back in, because `code` is
the default and an un-hiding genus would surface all of `.git/`.

The whole thing is daemon-eligible. The selection rides the `query_ext` frame as
a two-byte trailer, so a `--docs` query answers from the resident session at
warm speed, byte-identical to the cold run.

Extend it with `--type-add 'docs:notes/**'` for one run, or
`types = ["docs:notes/**"]` in `.irregex.toml` for the whole tree.

No grep-class tool ships this axis. ripgrep has prose-adjacent types and no
aggregate over them, and its type globs are basename-only, so a `docs/` rule is
not expressible there even by hand ([ripgrep#3339][rg3339], open).

The rival is therefore what a person types instead: one `-t` per prose type,
hand-assembled, every time. Against that union, derived at run time from
`gist --type-list --docs ∩ rg --type-list` so it can be neither strawmanned nor
left to drift, `--docs` runs **2.9× faster cold and 21× warm** (geomean over the
needle slate, with the warm arm running with the answer keep disabled, so it is
a search and not a memoized recall).

Speed is the smaller half. A basename glob and a genus **disagree about what is
prose**, and the disagreement is proven on a hermetic tree rather than on this
repository, so the numbers are the same on your machine.

The union calls three `CMakeLists.txt` build recipes prose, because `*.txt` has
no way to say "except this one", and it cannot name two extensionless documents
that gist promotes by location and by name.

Over this repository's tracked corpus the two rosters land within one file of
each other. That is expected, since the rival is derived from gist's own docs
types, and it is why the mechanism is measured where it cannot drift.

Both halves are gated permanently.
[`partition_parity.sh`](bench/conformance/gates/parity/partition_parity.sh)
proves the set identities over the live tree on every `zig build test`, and
[`bench/dominance/partition/`](bench/dominance/partition/README.md) holds the
speed floors and the classification contract.

The taxonomy is [GitHub Linguist's][linguist]; the [classifier][ir-genus] names
the two deliberate divergences.

[rg3339]: https://github.com/BurntSushi/ripgrep/issues/3339
[linguist]: https://github.com/github-linguist/linguist/blob/master/lib/linguist/documentation.yml

### Choices That Prevent a Wrong Search

This section teaches selection, not a second flag registry. The checked-in
`flag_catalog` and `gist --schema` remain the exhaustive, versioned answer.

- **Case and character semantics** – `-i`, `-s`, and `-S` are last-wins.
 Unicode folding, classes, properties, and word boundaries are the default, and
 `--no-unicode` or a leading `(?-u)` deliberately selects byte/ASCII semantics.
 The fold is **simple** (`C+S`), matching ripgrep exactly, so `ß` is not `SS` on
 either tool. Under PCRE2, `--pcre2-unicode` and `--no-pcre2-unicode` control
 that backend separately.
- **Literal, word, line, and inverse matching** – use `-F` when punctuation
 should not become regex, `-w` for a whole Unicode word, `-x` for a whole line,
 and `-v` for non-matching lines. Multiple intents use repeated `-e` or a
 pattern file with `-f`.
- **Hidden and ignored files** – `-u`, `-uu`, and `-uuu` progressively disable
 ignores, add hidden paths, and include binary data. An explicit `-g` or
 `--iglob` include can whitelist an ignored path; a type filter can unhide a
 matching dotfile but does not override gitignore.
- **The `-rn` trap** – recursion is already the default, and ripgrep semantics
 parse bundled `-r` as replacement. `gist -rn PATTERN` therefore means
 `--replace=n`, not "recursive with line numbers". Spell `-n` alone; Gist
 preserves the behavior for parity but emits a diagnostic.
- **Zero is sometimes a real value** – explicit `-m0` means match nothing and
 exits 1, where omitting `-m` means unlimited. Likewise `-M0` explicitly
 disables the long-line cap.
- **Stable ordering** – the default streams in fast parallel discovery order.
 Use `--sort path|modified|accessed|created` or `--sortr` only when stable
 global order is part of the consumer's contract.
- **Unusual input** – `-z` searches compressed files, and `--pre CMD` searches
 a preprocessor's stdout and takes precedence over `-z`, with the command
 receiving the path as `argv[1]` and the file's bytes on stdin, ripgrep's exact
 contract. `-E/--encoding` accepts `auto`, `none`, or the checked-in WHATWG
 label set. Unknown labels and failing preprocessors exit 2 rather than looking
 like empty searches.
- **Binary intent** – `-a` treats input as text, while `--binary` and `-uuu`
 search a binary file in full and print every matching line, an improvement over
 ripgrep's one-line binary summary for a code locator (see
 [Binary Files](#binary-files)).
- **Machine output** – use `--json` for typed records, `-0` for NUL-delimited
 paths, `--null-data` for NUL-delimited input records, and explicit sorting when
 downstream comparison requires deterministic file order.
- **Who is reading** – most of the human posture is already the default a
 terminal gets, with matches grouped under a filename title and the rows
 numbered beneath it, exactly as ripgrep lays them out, while a pipe keeps the
 `path:line:` prefix and ripgrep's bytes. `-p`/`--pretty` adds the remaining
 piece (color, unconditionally) and `--plain` is the opposite pole, the piped
 posture forced onto a terminal, so an interactive run reproduces the bytes a
 script would see. Decline either half on its own with `--no-heading` / `-N`, or
 request it into a pipe with `--heading` / `-n`.
- **How fast it arrives** – delivery cadence is separate from all of that.
 `--line-buffered` is for a consumer that reacts per line, `--block-buffered`
 (with `--buffer-size`) for one that only wants the bytes cheaply, and
 `--buffer-size=0` when nothing may be held at all. Left alone, a pipe blocks
 and a terminal streams by line, which is almost always right.
- **Agent budgets** – prefer `--rank`, `-l`, `-c`, a narrower path, or `-m N`
 before lifting the soft output guard. `--uncap` or `GIST_UNCAP=1` is the
 deliberate escape hatch, and `GIST_HINTS=0` mutes guidance without changing
 results.
- **Warm and codex paths** – the resident session is an invisible, fail-open
 accelerator, and unsupported shapes simply stay cold. The codex is different:
 use it only for exact literal `count`/`tally` questions, and treat absence as
 proven only when `gist codex status` reports a clean shelf.
- **Persisted defaults** – a committed `.irregex.toml` at the tree root
 declares the corpus (`roots`, `skip`, `types`), while a machine-local
 `$XDG_CONFIG_HOME/gist/preferences` (on Windows,
 `%LOCALAPPDATA%\gist\preferences`, never the roaming `%APPDATA%`) holds flag
 lines and applies **only when stdout is an interactive terminal**. A pipe, a
 script, `--json`, and the daemon never inherit them, nor do they open the file,
 so a typo in one person's preferences cannot fail anybody else's run.
 `gist config` reports the resolved stack, `gist config check` validates both
 layers without searching, and `gist config init` writes a charter prefilled
 from this machine's `GIST_ROOTS` / `skips.list`. `--no-config` /
 `GIST_NO_CONFIG=1` ignores both.

## The Search Contract

The cold runtime's [`flag_catalog`][ir-catalog] is the source of truth for both
argv handling and `gist --schema`. It separates the public surface into four
buckets: exact support, **improvements** (identical-or-superset results that are
strictly better, whether faster, more robust, or better for code search, and
never a regression), accepted no-ops, and unknown flags that fail with exit 2.

Where gist differs from ripgrep it is an improvement, or it is a bug; there is
no third category. We do **not** claim every option ripgrep ever shipped.

That claim is measured rather than asserted, against a denominator ripgrep owns.
[`surface.py`](bench/conformance/rgsuite/surface.py) reads rg's documented flag
surface at run time (longs from `rg --generate complete-bash`, shorts and value
grammar from its man page) and compares both binaries byte-for-byte on stdout
and exit code.

Measured that way, **186 of 186 documented flags conform**: 176 are
byte-identical and 10 differ only at a declared boundary whose residual check is
re-verified on every run, with 0 rejected and 0 undeclared divergences.

Alongside that sit **411/411** of ripgrep's mined integration cases and 27/27
adverse undo pairs, where a negation must actually undo, on a fixture where the
two answers differ.

Both of those denominators are ripgrep's own, which is their ceiling as well as
their authority. So a third lane,
[`fuzz.py`](bench/conformance/rgsuite/fuzz.py), generates what nobody curated: a
random pattern × flag set × a hostile corpus (invalid UTF-8, NUL bytes, a 4 MiB
line, a symlink cycle, an unreadable file, catastrophic-backtracking patterns),
demanding byte-identical agreement while measuring crash, hang, and peak RSS.

It is the only lane that still finds anything, and it does: a low-single-digit
tail per 6,000 iterations, in corners where ripgrep's own three printers do not
agree with each other. An empty match at the end of a file with no final newline
is counted by `--count-matches`, dropped by `-o --json`, and rendered as the
whole line by `-o`.

That tail is **published, not excluded**. It is classified by root cause in
`fuzz_baseline.json` and in Layer I of the certificate, ratcheted shrink-only,
and a missing fuzz record refuses the mint outright.

The implemented surface includes:

- regular, fixed (`-F`), smart-case (`-S`), case-insensitive (`-i`), whole-word
 (`-w`), inverted (`-v`), and multiple (`-e`/`-f`) patterns;
- Unicode-by-default case folding, character classes, properties, and word
 boundaries, with `(?-u)` or `--no-unicode` for byte/ASCII semantics. The fold
 is **simple** (Unicode `C+S`), which is ripgrep's posture rather than a
 shortfall against it: `café` ⇄ `CAFÉ` matches on both and `ß` ⇄ `SS` on
 neither, because full (`F`) folding is one-to-many and neither engine performs
 it;
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
no-match suggestions go to stderr, and `GIST_HINTS=0` disables suggestions
without touching results.

Search exit codes follow ripgrep:

- `0` – at least one match;
- `1` – a clean search with no match;
- `2` – invalid argv, unsupported syntax, an unreadable path, or another search
 error.

An unknown flag or a pattern rejected by the selected engine is therefore an
error, never a convincing empty result.

## Improvements

Eight flag groups are not bit-identical to ripgrep, and every one of them is an
**improvement**: identical-or-superset results that are strictly better in
behavior, performance, or robustness, never a regression.

This is the *only* category of divergence. If gist ever disagrees with ripgrep
outside this list it is a bug, not a design choice, and `gist --schema` reports
the whole set under the `improvements` bucket.

For an exact, versioned answer about a flag, inspect `gist --schema` rather than
relying on a prose list.

### Binary Files

`--binary` (and `-uuu`) searches a NUL-bearing file in full. ripgrep prints one
opaque line, `binary file matches (found "\0" byte around offset N)`, and stops.

A code locator wants the matches, not a shrug, so gist searches past the NUL and
prints every matching line, exactly as `-a/--text` does.

For the source artifacts that carry a stray NUL, such as minified bundles,
checked-in fixtures, and mixed-content files, this is strictly more information.

### Indexed PCRE

`-P` / `--pcre2` is the only *indexed* PCRE search. The vendored PCRE2 JIT
backend returns ripgrep's exact `-P` match set, including lookaround,
backreferences, and Unicode properties.

It rides the same trigram prefilter as the linear engine, so PCRE queries skip
provable non-candidate files instead of scanning the whole tree. Same answers,
fewer bytes read.

The gist-native `--rank` is linear-only.

### Compressed Input

`-z` / `--search-zip` decompresses in-process. Results are identical to ripgrep
across every codec, verified byte-for-byte in
[`bench/conformance/rgsuite`](bench/conformance/rgsuite), but gzip, zlib, zstd,
and xz decode *in-process* via `std.compress`.

That means no `gzip -dc` fork per file, the single biggest speed edge on
compressed corpora. bzip2, lz4, Brotli, lzma, and `.Z` shell the standard
external tool exactly as ripgrep does.

### Sorted Output

`--sort` / `--sortr` reads in parallel and orders after. The final
`path`/`modified`/`accessed`/`created` order is identical to ripgrep's, which
single-threads a sorted run.

`created` additionally falls back to ctime where the platform has no birth time,
so a sort ripgrep cannot perform still succeeds.

### The Type Registry

`--type-list` is a strict superset of ripgrep's. It is sorted and framed exactly
like ripgrep's, with ripgrep's rows byte-identical, plus richer definitions and
gist-only types.

A caller parsing ripgrep's format parses gist's; it just sees more.

### Hyperlinks

`--hyperlink` / `--hyperlink-format` makes results clickable when they should
be. One axis has three spellings:
`--hyperlink[=auto|always|never|<alias>|<format>]`, `--no-hyperlink`, and
ripgrep's `--hyperlink-format`.

The default is `auto`, so links appear when a person is reading in a terminal
known to render OSC-8 and vanish the moment the bytes are going somewhere else,
where ripgrep defaults to none.

The deeper difference is that **ripgrep's links are a property of its color
layer**. By its own help, "hyperlinks are only written when a path is also in
the output and colors are enabled".

So a link into a pipe costs `--color=always`, which also forces color into that
pipe, and rg's documented escape hatch (`--colors path:none --colors line:none
…`) still wraps every field in `ESC[0m` resets. There is no rg invocation that
yields clean text plus links, and `gist --hyperlink=always` is that invocation.

Nor does gist need a path in the output to have something to click. Where rg
drops the link entirely when the filename is not printed, as with one explicit
file argument, gist anchors the line number instead.

A link is navigation, not paint, and `NO_COLOR` has no opinion about it. Naming
a destination on the command line turns links on, because typing
`--hyperlink=vscode` and getting silence is the mystery this flag exists to
prevent.

The standing-preference spelling is `GIST_HYPERLINK`, which may carry a
destination alone, leaving the probe to decide, or a `WHEN,WHERE` pair like
`always,vscode`.

The format grammar is ripgrep's, so a format rg accepts gist accepts and one it
rejects gist rejects with the same reason, plus aliases rg lacks (zed, windsurf,
vscode-remote, cursor-remote).

A `link` trace lens says on one line why a run linked or didn't, and always says
it, naming the posture (`turned off`), the reader (`output is a byte protocol`,
`machine-shaped output`), or the terminal (`stdout is not a terminal`,
`terminal does not advertise OSC-8`), because a diagnostic that goes quiet reads
as "nothing to report". Lighting the lens is enough to keep a run off the warm
path, which has no beacon to explain.

Paths fold lexically rather than through a `realpath(2)` per file, so a click
lands in the tree you searched. From `/tmp/x` gist emits `file:///tmp/x` where
rg emits `/private/tmp/x`, which resolves outside the workspace folder your
editor has open.

Every shape that prints a filename is clickable: match rows, headings,
`-l`/`--files` lists sorted or not, `-c` counts, the binary notice, and the
`--rank` view, whose whole point is that its top row is the one to open.

Two shapes refuse every posture, including `always`: `--json` records and
NUL-framed `-0` lists, where the filename's bytes *are* the payload. So does a
filename carrying a control byte, where you cannot see where the click target
starts and stops, since a newline in a name splits the anchor across two
terminal lines outright.

The URL stays exact either way; it is the text between the escapes that is
refused, where rg frames those and emits the two-line link.

Linking 93k matches costs ~5 ms (≈60 ns each), because the URL is split once per
file into a prebuilt `Waypoint` and a row only writes the digits. The output cap
counts results rather than escapes, so turning links on never costs you a row.

### Line Buffering

`--line-buffered` keeps the same promise for a fraction of the syscalls. Neither
implementation ever holds a finished line, and ripgrep's `LineWriter` also never
writes more than one at a time, while gist emits every finished line already in
hand in a single `write(2)`.

`-n std src/` here is 1.04 MB of results and the same bytes either way:
`rg -j1 --line-buffered` makes 15,782 writes, and gist makes 342.

The boundary is the run's real terminator, so `--null-data` records flush on
NUL, where rg's line writer only knows `\n` and holds NUL-delimited output until
its buffer fills.

### Block Buffering

`--block-buffered` ramps the block, and the ceiling is one you can name. The
first fragment leaves immediately and the threshold then doubles to the ceiling,
so `| head -1` answers instantly and a closed pipe is discovered within a
kilobyte, while a full dump settles into whole-buffer writes.

On the same run ripgrep makes 342 writes, from its 8 KiB `BufWriter` that holds
the first byte as long as the last, and gist makes 23, or 11 at
`--buffer-size=1M`, a knob ripgrep does not have.

This is gist's default posture into a pipe, and it reaches the reader sooner as
well as less often: 5 ms to first byte against ripgrep's 9.

### Adjacent Product Choices

Three more choices are *not* rg-flag divergences, and it is worth saying so.

`--mmap`, `--no-mmap`, `--dfa-size-limit`, and `--regex-size-limit` are accepted
compatibility no-ops.

Agent-facing output has a soft budget of roughly 25k tokens / 100 KiB and a hard
256 MiB ceiling that `--uncap` or `GIST_UNCAP=1` lifts.

`--colors` restyles one element at a time, in ripgrep's own spec grammar
(`{type}:none` or `{type}:{fg|bg|style}:{value}`, over path/line/column/match,
with named colors, 0-255, and `r,g,b`). A spec merges into gist's palette the
way rg's merge into its own, so naming a hue keeps the default's bold, and
`match:none` unstyles matches while leaving path color alone, the thing
`--color=never` cannot say since it is all-or-nothing. gist renders one SGR
sequence per element where rg emits a separate escape per attribute, and paints
column numbers only when a spec asks it to; a malformed spec exits 2, as it does
under rg.

## Three Execution Paths

There are three ways into the matcher, and they are required to give one answer.

### The Cold Subprocess

We keep the normal process as the path that can answer every request:

```text
argv → parse → compile → walk → index read-elision → verify → emit
```

The walk chooses the files, and the index only removes provable non-candidates.

Files changed since the index anchor are read live, and missing coverage simply
reduces acceleration. `--no-index` is the differential oracle for this
invariant.

### The Resident Session

To stop paying startup costs, `gist serve` holds corpus bytes and a trigram
index behind a per-repository Unix socket. The CLI may auto-spawn it after an
eligible cold miss.

The request classifier deliberately keeps the warm surface small.
[`client.zig`](src/exec/session/daemon/client/client.zig) remains the executable
authority; what follows is a readable snapshot.

Warm-eligible shapes are rootless line output (`-n` / `-N` allowed), rootless
`-l` / `--files-with-matches`, rootless `--rank[=N]`, the `-F`, `-i` / `-s` /
`-S`, and `-w` modifiers, and existence or caps via `-q` and `-m N`.

Authoritative-cold shapes are any explicit path including `.`, stdin or TTY
stdout, context, JSON, replace, multiline, PCRE2, globs, invert, and any
malformed or unrepresentable flag value.

The wire contract also defines a count mode, but CLI `-c` keeps ripgrep's
per-file layout and stays cold. Warm I/O has a two-second deadline, and
`GIST_NO_AUTOSERVE=1` disables automatic session startup.

Eligibility is an optimization decision, never a support boundary.

Freshness is fail-closed. macOS kqueue or Linux inotify can narrow the work, but
a reconcile barrier decides whether resident bytes are safe.

Doubt, overflow, an index generation change, or a walk error declines the warm
answer and returns to the subprocess. The sockets and the lifecycle are this
repository's; the engine they hold hot is the [`ResidentSession`][ir-session]
invariant.

### The In-Process ABI

For embedders, the in-process FFI path is the C ABI (`gist_open` /
`gist_search` / `gist_close`), which streams match records from the same
error-returning resident engine.

Python uses it when the shared library and optional cffi are available, then
falls open to UDS or subprocess. It is another route to the same matcher, not a
second implementation.

The request options are the engine's, in [`contract/engine.toml`][ir-engine],
while transports and session rules are this repository's, in
[`contract/surface.toml`](contract/surface.toml).

## The Two Indexes

We use two indexes because they answer different questions. The ordinary
trigram index is a **candidate filter**: small, mmap-backed, fast, and never
authoritative, because every candidate it admits still gets its current bytes
checked.

That is the index behind normal regex search. Riding beside it is the **crest
sidecar**, which prunes the literal-free class repetitions (`[0-9a-f]{12}`,
`[0-9]{6}`) that extract no trigram at all and that every index in this family
therefore concedes whole.

Both filters only ever skip reads, and caseless queries, changed files, and a
missing sidecar all fall back to reading. Both are powered by irregex: the
[persisted index family][ir-index], and the [forced-run theorem][ir-crest] the
sidecar is sound by.

The codex shelf is a **compressed self-index** for exact literal questions. It
can count in O(pattern length), locate occurrences, recover the indexed corpus,
and answer without opening source files.

`gist codex count` is a proof of absence only when the shelf's freshness report
is clean, and the command reports files changed since the shelf was built rather
than hiding that qualification. See `relate/src/kernel/codex` (math) and
`relate/src/corpus/index/shelf` (persisted SHLF).

## Ranked Search

Sometimes we need the best hit, not every hit. `--rank[=N]` keeps the same
pattern and path semantics and changes only the shape of the answer: the
definition outranks its two hundred call sites, and generated files sink below
authored ones.

The view is powered by irregex's [rank fusion][ir-rank] and the signals it
fuses. What this repository adds is the flag, a default top K of 20, and the
row:

```text
1. path:line  [def|use|gen|mirror]  ×count  source line
```

This is heuristic text ranking, not name resolution or semantic code
intelligence. It works from the persisted index when possible and has a live
walk fallback, and `--rank` is limited to the linear engine.

## Evidence

The idea is ours; the expected answers are not. The ripgrep muscle-memory
promise is why we compare gist with a live `rg` oracle instead of writing
expectations by hand.

The gates cover parallel and serial walks, indexed versus `--no-index`,
freshness, line framing, Unicode, multiline and PCRE2 modes, ordering and ignore
flags, encodings, preprocessing, compressed input, binary handling, streams, and
resident-versus-cold answers.

The tracked ripgrep 15.2.0 snapshot contains 446 invocations per walk engine:

- **Mined upstream suite** – 411 PASS, 0 ORDER, 0 FAIL, 14 NA, and 21 SKIP.
 Supported-surface parity is **411/411 = 100%**, so every supported-surface case
 matches ripgrep, with zero deferred divergences.
- **Multiline** – 30/30 adversarial cases pass for stdout, exit code, and
 indexed-versus-`--no-index` equality.
- **PCRE2** – 30/30 adversarial cases pass the same three-way oracle, including
 lookaround, backreferences, Unicode toggles, and resource-limit failures.
- **Walk, ignore, and message flags** – 39/39 cases pass on each engine. The
 fixtures make path/time ordering, last-wins negations, worker counts, device
 boundaries, and global git-ignore state observable. The `--no-messages` /
 `--no-ignore-messages` cases live here rather than in the mined suite because
 rg's own `--no-messages` tests assert on the exit code, which a gist that
 merely *rejected* the flag would also satisfy; these assert the real property,
 that stderr goes empty while stdout and the exit class do not move, and pin the
 nesting asymmetry with both lanes firing at once.
- **Content transforms** – 22/22 cases pass on each engine across
 preprocessing, binary input, legacy encodings, and the available gzip, bzip2,
 xz, zstd, lz4, and Brotli decoders.

Every count above shares one denominator ripgrep chose, the tests it wrote and
the flags it documents, so each of those 100%s is scoped to cases someone
already thought of.

The differential fuzzer is the lane with no such ceiling. It generates
invocations nobody wrote down, over corpora built to be hostile, and it is the
only one that still finds anything.

It does, a handful per 6,000 iterations, and that tail is published per
root-cause class in `fuzz_baseline.json` and in Layer I of the certificate
rather than left out of the scoreboard. A missing fuzz record refuses the mint
outright, and the tail is ratcheted shrink-only, so it can fall but never
quietly grow.

Parallel and serial results are reported separately because they share a
contract but not an implementation path; they are not added together to inflate
the case count.

NA is a deliberate product boundary. SKIP is an accounted companion, boundary,
or irreplayable obligation. Neither is called a pass, and with zero FAIL rows
the strict `check_results.py` gate is green without `--allow-fail`.

Reproduce the cited results from
[`bench/conformance/rgsuite`](bench/conformance/rgsuite):

```bash
python3 run.py
python3 modes.py run --mode multiline
python3 modes.py run --mode pcre
python3 flags.py run
python3 transforms.py run
python3 fuzz.py --iterations 6000 --seed 20260727   # the residual lane
```

The permanent integration order is documented in
[`bench/conformance/gates`](bench/conformance/gates): correctness gates run
before performance gates, so a faster wrong answer cannot earn a benchmark win.

Performance claims come from the committed fail-closed certificate: fresh
processes, 20 measured runs after three warmups, bootstrap 95% confidence
intervals on medians, and a Mann–Whitney test. A win requires both a lower
median and p < 0.05.

On its recorded 20,492-file / 195.8 MiB corpus, gist beat ripgrep in all 12
query classes by 2.10×–7.76×. Those are measurements from the **macroscopic
end-to-end layer**, not universal constants.

The separately minted lower-bound layer covers a 20,696-file / 199.6 MiB corpus,
and those single-thread kernel numbers must not be attached to the end-to-end
speedups.

![gist fail-closed statistical certificate forest plot](assets/gist-certify-forest.png)

The full data, machine description, losses against other indexed tools, and
rerun procedure live with the published receipts in
[`bench/certificate/artifact/`](bench/certificate/artifact/README.md).

The layers that bound the *engine* rather than the product, meaning the µarch
budget, the memory roof, the candidate-byte floor, and the crest rung, are
minted in [irregex's own harness][ir-bench].

## Prior Art

Most of the pieces are borrowed and cited. We joined them for one specific job:
searching a local, constantly changing tree over and over for coding agents.

The positive product case and precise composition claim live in
[`CLAIM.md`](research/gist/CLAIM.md). The contribution is that measured
composition and the contract around it.

The ancestry of the machinery is documented where the machinery lives. Kleene
and Thompson through the Pike VM and RE2, PCRE2 for what the linear lane cannot
express, Cox's trigram index and the crest sieve that closes its one blind spot,
and the Reciprocal Rank Fusion the ranked view is built from are the lineage of
the engine gist is powered by, and that lineage is argued in
[`irregex`][irregex].

What follows is the ancestry of the *product*: the tools somebody would reach
for instead of this one.

### Indexed Neighbors

[Zoekt](https://github.com/sourcegraph/zoekt) is the closest production indexed
code-search comparison, with positional trigrams, regex planning, ranking,
mmapable shards, and a serving layer.

GitHub's
[Blackbird](https://github.blog/engineering/architecture-optimization/the-technology-behind-githubs-new-code-search/)
extends the same family with sparse variable-length n-grams and global-scale
sharding. Gist claims neither distributed search nor organization-wide
repository synchronization.

[Microsoft tgrep](https://github.com/microsoft/tgrep) is the nearest public
local-agent shape: a persistent trigram index, file watching, client/server
operation, and a grep-like CLI.

Gist's distinguishing contract is narrower. Accelerators may decline, while a
current-tree subprocess remains capable of answering every supported request.

### Matching Engines

The linear lane descends from Thompson's
[Regular Expression Search Algorithm](https://doi.org/10.1145/363347.363387)
(CACM 1968), the Pike VM, Cox's
[Regular Expression Matching Can Be Simple And Fast](https://swtch.com/~rsc/regexp/regexp1.html),
and [RE2](https://github.com/google/re2). Unicode range compilation follows the
Thompson/Cox UTF-8 decomposition used by RE2 and rust-regex.

Complex constructs use the vendored
[PCRE2](https://www.pcre.org/current/doc/html/) 10.47 engine with JIT and
resource caps.

Gist does not claim to make backtracking expressions linear. `-P` deliberately
selects PCRE2 semantics, while `--engine auto` keeps the linear engine whenever
it can express the pattern.

### Ranking

The bounded result view uses weighted Reciprocal Rank Fusion from Cormack,
Clarke, and Büttcher,
[Reciprocal Rank Fusion Outperforms Condorcet and Individual Rank Learning
Methods](https://doi.org/10.1145/1571941.1572114) (SIGIR 2009). Its inputs are
language-agnostic text and path signals.

A declaration-shaped boost is not a symbol table. gist does not resolve types,
references, overloads, or call graphs, and it is not an LSP, SCIP, or
semantic-retrieval engine.

### The Codex Subcommand

`gist codex` is a thin lifecycle face over the shared compressed self-index
(`count` / `find` / shelf status).

The Shannon–Manzini / FM-index bibliography and novelty framing live with
`relate`, in `relate/research/relate/PRIOR_ART.md` § Corpus quotation, and in
`relate/src/kernel/codex` / `relate/src/corpus/index/shelf`.

### Outside the Claim

We keep the boundary sharp. Gist is not structural search (Semgrep, ast-grep,
Comby), a format-preserving transformation system (OpenRewrite), semantic code
intelligence (LSP/SCIP), or a hosted multi-repository platform
(Sourcegraph/GitHub Code Search).

It is the exact/regex leg those systems and agents can compose with.

The full landscape, covering unindexed peers, indexed neighbors,
matcher/ranking ancestry, and semantic/structural systems, lives in
[`PRIOR_ART.md`](research/gist/PRIOR_ART.md). The positive product thesis lives
in [`CLAIM.md`](research/gist/CLAIM.md), and the exact evidence inventory and
known losses live in [`TESTING.md`](research/gist/TESTING.md).

Codex / Shannon–Manzini literature stays with Relate in
`relate/research/relate/PRIOR_ART.md`. Where prose lags implementation,
`gist --schema`, the live differential harness, and the committed certificate
are authoritative.

## Package Map

This repository is the product chassis, and it ships the binary. `gist` is the
indexed, rg-parity search, powered by [`irregex`][irregex], where the engines,
the index, the corpus walk, the flag grammar, and the warm resident core live.

What is here is everything with an opinion about the product:

- [`src/exec/session/conduit/`](src/exec/session/conduit/) – the daemon wire:
 protocol, spawn, vigil.
- [`src/exec/session/daemon/`](src/exec/session/daemon/) – the resident session
 proper: the socket server, request routing, and the client. The answer keep it
 serves lives in the library's warm core.
- [`src/exec/session/warden/`](src/exec/session/warden/) – rationing and
 standdown, so the daemon never taxes the machine it serves.
- [`src/surface/cli/`](src/surface/cli/) – the product vocabulary: flag
 surfaces, grades, the `--schema`/`--generate` manifest driver, the primer, and
 reprise.
- [`src/surface/face/gist/`](src/surface/face/gist/) – the binary face itself.
- [`src/surface/ffi/`](src/surface/ffi/) + [`include/`](include/) – the session
 C ABI (`libirgx.{a,dylib,so}`, `irgx.h`).
- [`bindings/`](bindings/) – Go (cgo), Python (cffi), and Rust consumers of
 that ABI.
- [`editor/vim/`](editor/vim/) – the Vim/Neovim plugin (`:grep`-as-gist,
 streamed quickfix, `:GistRank`, `:GistBlast`).
- [`shell/`](shell/) – the generated man page and bash/zsh/fish/pwsh
 completions, minted from the same flag table argv is parsed with.
- [`bench/`](bench/) – the vs-ripgrep dominance certificate and the ratio gates
 that keep it honest.

## Build and Test

Four steps cover everything the package builds:

```bash
zig build             # gist binary + libirgx → zig-out/
zig build test        # the unit suite
zig build check       # compile-only
zig build coverage    # per-function coverage
```

The binaries default to ReleaseFast regardless of the build's own optimize mode,
which `-Dcli-optimize` overrides. The test binary stays ReleaseSafe, so the
suite that tries to break the checks keeps them.

Dev model is sibling checkouts. `build.zig.zon` path-deps on `../irregex` and
`../relate`, and releases pin url + hash; a consuming monorepo may wrap
`zig build` to symlink the binaries onto PATH.

### Running One Test

`-Dtest-filter=<substring>` narrows the suite and `-Dtest-shards=1` puts it back
into one process. The harness is `brigade.zig`, which this package takes from
the irregex dependency rather than owning, so the trap below is the same one
that repository documents at more length. It is restated here because you will
hit it here, running these tests.

The trap is that `zig build test` caches the test run, and the environment is
part of the cache key.

The filter reaches the harness as `BRIGADE_FILTER`, an environment variable set
on the run step, and Zig hashes a run step's environment along with its argv.

First run under a given environment executes. Every later run under an
environment already used is served from cache, so the step is skipped, nothing
executes, and it exits 0 in about the time a no-op build takes (~0.3 s here).

A cache hit still reports a test count, which is what makes it dangerous.
`--summary all` prints `1/1 tests passed` either way, and the only token that
distinguishes them is `cached` against `success <n>ms`:

```text
+- test shard 0/1 success 3ms     # ran
+- test shard 0/1 cached          # did NOT run, still "1/1 tests passed"
```

So `zig build test` cannot answer whether the tree is sensitive to an
environment variable. The natural probe runs with the variable, then without it
to confirm, and the confirming leg revisits an environment it has already seen,
making it a replay that is green by construction.

To probe an environment variable, drive the compiled binary directly, since it
has no build-cache layer and executes every time:

```bash
env FORCE=$RANDOM zig build test -Dtest-filter='<name>' -Dtest-shards=1 --verbose
#   ... BRIGADE_SHARD=0/1 BRIGADE_FILTER=<name> ./.zig-cache/o/<hash>/test

BRIGADE_SHARD=0/1 BRIGADE_FILTER='<name>' BRIGADE_TIMES=1 \
  ./.zig-cache/o/<hash>/test
```

`BRIGADE_TIMES=1` prints one line per test, which is the evidence a run
happened. A filter matching nothing fails loudly rather than passing empty, so a
stale filter cannot read as a clean run.

## Provenance

Extracted from a private monorepo kernel package, cut at ce430bbaab.

The cut line is ripgrep's. What `rg`-the-binary owns, meaning the daemon, the
product vocabulary, distribution, and the certificate, lives here; what the
`grep-*` crates own, meaning engines, walker, index, and argv, lives in the
library.

Architecture is machine-checked by [`contract/gist.ward`](contract/gist.ward).
Apache-2.0; nothing third-party is bundled here, and the certificate measures
competitors by invoking installed binaries.

[irregex]: https://github.com/The-Billy-Company/irregex
[ir-catalog]: https://github.com/The-Billy-Company/irregex/blob/main/src/exec/cold/argv/catalog.zig
[ir-session]: https://github.com/The-Billy-Company/irregex/blob/main/src/exec/session/README.md
[ir-engine]: https://github.com/The-Billy-Company/irregex/blob/main/contract/engine.toml
[ir-index]: https://github.com/The-Billy-Company/irregex/blob/main/src/corpus/index/README.md
[ir-crest]: https://github.com/The-Billy-Company/irregex/blob/main/research/crest/PROOF.md
[ir-rank]: https://github.com/The-Billy-Company/irregex/blob/main/src/kernel/rank/README.md
[ir-genus]: https://github.com/The-Billy-Company/irregex/blob/main/src/corpus/scope/genus.zig
[ir-bench]: https://github.com/The-Billy-Company/irregex/blob/main/bench/README.md
