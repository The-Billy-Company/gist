# Contributing

Thanks for looking. This page is the practical half - what to install, what to
run, and what a reviewable change looks like here. The design half is
[`README.md`](README.md) for what the binary promises, and
[`research/gist/`](research/gist/CLAIM.md) for the product thesis, the
competitive ancestry, and the gates that try to falsify it.

Two other files bound this one. Report a vulnerability privately, never in an
issue: [`SECURITY.md`](SECURITY.md). How we treat each other:
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## What this repository is, and what it is not

`gist` is the product: the argv grammar, the resident daemon, the ranked view,
distribution, the editor plugin, the generated manual and completions, and the
parity contract with ripgrep. The **engine** is [`irregex`][irregex] - the regex
engines, the corpus walk, the trigram index and the crest sieve, the freshness
law, and the ranking math all live there.

That split decides where an issue goes. "This flag does the wrong thing", "the
daemon returned something stale", "the ranked view buried the definition", "the
Windows path came back wrong" - all here. "This pattern matches the wrong span"
is the engine's, even though you found it through this binary. File it wherever
you like; we move it rather than bounce you.

**You need both checkouts.** This package cannot build from its own clone: its
`build.zig.zon` path-depends on `../irregex`, and so do all three bindings
independently. Clone them as siblings:

```text
Billy-Company/
├── irregex/     ← the engine, required to build this
├── gist/        ← you are here
├── relate/
└── blast/
```

This is why CI checks out two repositories into subdirectories of one
workspace: `actions/checkout` refuses a path outside the workspace, and nothing
in the package is patched for CI on purpose. What builds there is the layout you
actually clone.

## Setup

| For | Install | Pinned by |
| --- | --- | --- |
| the binary | Zig **0.16.0** | `minimum_zig_version` in [`build.zig.zon`](build.zig.zon), `ZIG_VERSION` in CI |
| parity work | ripgrep on PATH | it is the oracle, not a convenience |
| the Python binding | [uv](https://docs.astral.sh/uv/) | `requires-python` floor 3.12 |
| the Rust binding | rustup | `bindings/rust/rust-toolchain.toml` |
| the Go binding | Go | `bindings/go/go.mod` |
| the discipline gate | markdownlint-cli2, typos, shellcheck, golangci-lint | the actions in [`ci.yml`](.github/workflows/ci.yml), mirrored into `.mise.toml` |
| the topology gate | [zoning](https://github.com/The-Billy-Company/zoning) **0.1.1** | the `topology` job in [`ci.yml`](.github/workflows/ci.yml), mirrored into `.mise.toml` |

If you run [mise](https://mise.jdx.dev), that whole table is one command:

```bash
mise install
```

`.mise.toml` pins every row at the version CI uses and `mise.lock` carries the
checksums for all four release platforms. The pins are mirrors of the files in
the third column and never the authority, so bumping one means bumping the
other in the same commit.

ripgrep is pinned there too, though not because the parity result turns on
which release you have - it does not, and the CI step that installs it says so.
It is pinned because the conformance gate exits 1 without an oracle rather than
skipping, and a gate that fails on a laptop for want of `rg` teaches nobody
anything.

```bash
zig build                 # ReleaseFast binaries, PATH link, trigram index
zig build check           # compile only - the fastest "did I break it"
zig build check --watch   # ... and again on every save
zig build test            # the suite
zig build cli -- --help   # drive the CLI through the build graph
```

## The test loop

The suite is sharded and filterable, and using that is the difference between a
0.1-second loop and a coffee break - the long-pole differential fuzz dominates
an unfiltered run by design:

```bash
zig build test -Dtest-filter='<substring>'   # just the tests you touched
zig build test -Dtest-shards=1               # one process, for a debugger
BRIGADE_TIMES=1 zig build test               # per-test milliseconds
```

A filter matching nothing **fails** rather than passing empty, so a stale
filter can never read as a clean run. Run the unfiltered suite once before you
push.

Beyond the Zig suite:

```bash
./bench/conformance/gates/parity/type_union_parity.sh   # -t algebra vs ripgrep
./shell/check.sh                                        # the generated menus, judged by the shells

# The plugin's headless suite. Both editors must pass: they disagree about
# jobs, quickfix, and completion often enough that one proves nothing about
# the other.
vim  -es        -u NONE -i NONE -S editor/vim/test/gist_test.vim
nvim --headless -u NONE -i NONE -S editor/vim/test/gist_test.vim

cd bindings/python && uv run pytest -q
cd bindings/rust   && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
cd bindings/go     && go vet ./... && go test ./...
```

## Parity is a product constraint

The reason to keep ripgrep's mental model is that the muscle memory is already
embedded in how people and agents search. That makes divergence a bug by
default, and it is the standard a change is held to here:

- **Same flags, same defaults, same file set, same exit codes** (0 matches,
  1 clean no-match, 2 error). If your change moves any of those, say so in the
  PR and expect the question.
- **Divergence is welcome only as a proven improvement**, documented as one -
  never as an accident nobody noticed. `--rank`, the `--docs`/`--code`/`--data`
  genus partition, and the ranked view are divergences; each is argued for in
  the README rather than merely shipped.
- **A gate that skips has stopped gating.** The parity gates exit non-zero when
  their oracle is missing rather than quietly passing. Do not "fix" a red gate
  by giving it a skip branch.
- **`--no-index` is the oracle for the accelerated path.** If you touch
  anything about the index, the daemon, or freshness, the check that matters is
  that the accelerated answer is byte-identical to the un-accelerated one on a
  real tree. That comparison is one command; run it.

## What CI will check

Nine jobs in [`.github/workflows/ci.yml`](.github/workflows/ci.yml), split on
purpose - a Zig engine regression and a Rust clippy nit are different news and
deserve different red Xs - plus a native Windows lane in
[`.github/workflows/windows.yml`](.github/workflows/windows.yml) on x64 **and**
arm64.

| Job | What it holds |
| --- | --- |
| `engine` | `zig build check` + `zig build test` on Linux and macOS, then the `-t` union parity gate against a real ripgrep |
| `python` / `go` / `rust` | each binding's suite; Python across 3.12, 3.13, and 3.14. Each also holds its language surface: Ruff, golangci-lint, Clippy, and `cargo deny` over the crate's advisories, bans, licenses, and sources |
| `discipline` | Markdown structure and links, spelling, YAML, TOML, EditorConfig, Python, shell, Go, and GitHub Actions security |
| `fmt` | `zig fmt --check` over every tracked and untracked-not-ignored `.zig` file |
| `certificate` | the mint ledger, the release gate, and the report post-processors - hermetic, and every module must still import |
| `version` | every package-version mirror still agrees with `build.zig.zon` |
| `changelog` | every fragment in `changelog.d/` is one towncrier recognizes |
| `windows` | the real thing on a real kernel: `NtCreateFile` descending NTFS, path spellings round-tripping, exit codes surviving a console |

Run the formatter before you push - `zig fmt` reflows column-aligned literals,
so a rename that shrinks the widest cell leaves rows you never touched one space
too wide:

```bash
zig fmt .
```

## Benchmarks are evidence, and the bar is absolute

There is no case where an incumbent is allowed to win. If ripgrep, csearch, or
zoekt beats us at something, that is a gap to close, not a caveat to write down.

- Numbers come from a harness in [`bench/`](bench/README.md), on a quiet
  machine, against the rung being claimed - not from a stopwatch and a hunch.
- Profile the function you changed rather than re-running the whole slate and
  squinting at the total.
- If output is supposed to be byte-identical, prove that it is.
- Competitors are measured by invoking the binaries you have installed, never
  by vendoring a copy we chose. Say which versions you measured.
- **Do not publish a certificate minted over a private corpus.** The bundles
  carry absolute paths, a file roster, and commit SHAs from whatever tree they
  were minted on; that is why the artifact directory is gitignored. Re-mint over
  a public corpus before any of it ships.

## Every change carries its own news

Write a towncrier fragment in the **same PR**:

```bash
towncrier create '+<slug>.<type>.md'    # types: added changed deprecated removed fixed security
```

Fragment names read like the sentence they are:
`+the-substrate-answers-to-irgx.changed.md`. The leading `+` tells towncrier
there is no issue number attached. The body is prose for a person reading
release notes - what changed and what it means for them, not a restatement of
the diff.

Skip it only for comment-only, format-only, or genuinely invisible internal
work. When unsure, write it. A malformed filename is a CI failure by design
(`ignore` in [`towncrier.toml`](towncrier.toml) turns towncrier's silent skip
into an error), so a typo cannot quietly drop your entry from a release.

## The version is written once

You will not edit a version by hand, and you should not try. `build.zig.zon`'s
`.version` is the only place this package's number is written:

- **Zig** reads it through a build option, which is what `gist --version` and
  the `--schema` manifest answer with;
- **Rust** reads `CARGO_PKG_VERSION`;
- **Python** reads its installed distribution metadata.

That leaves `Cargo.toml` and `pyproject.toml`, which cannot import anything.
Both carry an `x-release-please-version` marker, `release-please-config.json`
lists them, and one merged release PR moves all three in a single commit.
`python3 tools/version_parity.py` proves they agree, and fails just as loudly on
a marked line the release config was never told about. It runs in CI.

The engine underneath is a different axis. `irregex` versions on its own
schedule and is pinned as a dependency, never mirrored here - ask it with
`gist rg --pcre2-version` or its own accessor.

**Cutting a release.** Merge the release PR that release-please opens; that tags
`vX.Y.Z` and `release.yml` publishes the wheels. towncrier owns `CHANGELOG.md`,
so run `towncrier build --version <the version the PR bumps to>` and push it
onto the release branch - the tag and the notes should land together.

This repository's tag, changelog, and publish steps are one instance of a
model shared across every Billy-Company OSS package - see
[RELEASING.md](https://github.com/The-Billy-Company/.github/blob/main/RELEASING.md)
for the lifecycle this feeds into and why it's shaped this way.

## Commits and pull requests

Commit subjects here are a conventional prefix plus a lowercase sentence that
says what changed, in the voice of the change rather than the ticket:

```text
fix: the Python binding maps one engine
feat: the harness moves in with the daemon it drives
ci: the repository gets CI, and it knows it has a sibling
```

Prefixes in use: `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci`
`chore`. Keep the subject under about 72 characters and put the reasoning in the
body, where reviewers and `git log` both find it.

For the pull request: one concern per PR, describe what would have caught the
bug if it had existed, and fill in the template. Reviews here ask three
questions more than any others - *what proves this?*, *what does it cost?*, and
*what did it replace?* Answering them in the description saves a round trip.

If you removed something that a newer path superseded, remove it completely.
Leaving the old implementation beside the new one to be safe is how a codebase
grows two spellings of the same bug.

## Architecture is machine-checked

Zig has no visibility rules between files in a package, so every boundary the
READMEs describe would be convention. [`contract/gist.zone`](contract/gist.zone)
is the machine-checkable half. If your change needs a new import edge, edit the
contract in the same commit and say why in the variance. Do not route around
it.

`mise install` puts `zoning` on your PATH, so you can run it while you edit
instead of reading its verdict in review: `zoning verify` is what the topology
job runs, `zoning map` draws the zone stack, and `zoning status --suggest`
drafts the variance a new edge would need.

The flag surface has the same property: [`contract/surface.toml`](contract/surface.toml)
is what `--schema`, the manual, and every shell completion are generated from,
which is why a flag cannot exist in the parser and be missing from a menu. Add
a flag there, not in five places.

## Licensing

This project is Apache-2.0. There is no CLA: contributions are accepted under
the same license the project already carries, per the inbound=outbound norm in
section 5 of the license itself.

If you bring in third-party code, data, or an idea from another tool, it goes in
[`NOTICE`](NOTICE) and the credit goes at the call site. We compare ourselves to
other people's work constantly; describing it accurately and crediting it is
part of the work.

## A small thing that makes diffs readable

Git ships hunk-header patterns for Go, Python, Rust, C, and Markdown, and
[`.gitattributes`](.gitattributes) already binds them. Zig has none, so teach
your own git what a Zig declaration looks like once:

```bash
git config diff.zig.xfuncname '^((pub |export |inline |noinline )*fn .*|(pub )?(const|var) [A-Za-z_].* = (struct|union|enum|opaque)\b.*)$'
```

The attribute is already in place; until you run this, it simply falls back to
git's default.

[irregex]: https://github.com/The-Billy-Company/irregex
