The repository had a license, a NOTICE, and eight workflow jobs across two
lanes, and nothing that told an outsider how to participate in any of it. The
single most load-bearing fact about building this package - that it cannot
build from its own clone, because `build.zig.zon` and all three bindings
path-depend on a sibling `../irregex` checkout - was written down only in a
comment at the top of a CI file.

Six files now say it out loud.

**`CONTRIBUTING.md`** is the practical half: the sibling-checkout layout and
why CI is shaped around it, the pinned toolchains, the test loop that matters
(`-Dtest-filter`, `-Dtest-shards=1`, `BRIGADE_TIMES=1`, since the long-pole
differential fuzz dominates an unfiltered run), the four suites that are not
`zig build test` - the `-t` union parity gate, `shell/check.sh`, the plugin's
headless suite in both editors, and each binding - and what each CI job holds.
It also states parity as the product constraint it is: same flags, same file
set, same exit codes, divergence welcome only as a documented improvement, a
gate that skips has stopped gating, and `--no-index` is the oracle the
accelerated path answers to.

**`SECURITY.md`** draws the line this project actually has, which is not the
usual one. The corpus is the attacker: hostile file names, a committed
`.irregex.toml` whose reach is ceilinged at corpus and must never change what
matches, a planted index, terminal escape sequences on their way to a real
terminal, and the daemon's same-user socket. An accelerator that changes an
answer is a security bug here, because "the tree tells the truth" is the promise
the whole design rests on. PCRE2 going exponential behind `-P` is the documented
trade you opt into, and a big tree taking longer than a small one is arithmetic.

**`CODE_OF_CONDUCT.md`** is Contributor Covenant 3.0 with the reporting and
enforcement sections filled in rather than left as the template's bracketed
notes. Its "failing to credit sources" clause is not decoration in a project
that benchmarks against ripgrep, csearch, and zoekt on every release: describing
a competitor accurately, and crediting an idea we took, is part of the work.

**`.editorconfig`** carries no second opinion - every value is the one the
formatter that gates the file already emits, so an editor save and `zig fmt
--check` cannot disagree. Vim's help file is exempt, because its tag columns are
load-bearing and an editor that trims them breaks `:help gist`.

**`.gitattributes`** normalizes line endings (the parity suite compares bytes
against ripgrep's, so a CRLF checkout would fail the comparison for a reason
that has nothing to do with either tool), marks the figures binary, collapses
Vim's generated help index, and binds git's hunk-header drivers. It deliberately
does not use `export-ignore`: that would change the bytes of the tarball GitHub
generates for a tag, which is exactly what a downstream `zig fetch` pin is a
hash of.

**`.mailmap`** collapses seven author spellings into the three people who wrote
them.

Alongside them, `.github/` gains a CODEOWNERS routing table, a Dependabot
configuration whose omissions are the interesting part (the bindings resolve the
engine through a sibling path Dependabot's sandbox cannot see, so a `cargo` or
`uv` entry here would produce a recurring resolution error against a manifest
that is correct - leaving the one thing nothing else watches, the actions
themselves), a pull-request template with parity as its own section, and three
issue forms. The first is the one this project needs most: a parity-gap report
that asks for both command lines, both outputs, and the single most diagnostic
question available - whether `--no-index` changes the answer.
