# bench/dominance

**Measured product performance in the world** — gist against the real
competitor field, and the operational envelope where those numbers hold. A
result here is always a _statistic_ (bootstrap-CI median + Mann-Whitney), never
a single mean.

| Folder                            | What                                                                                                                                                                                                                                                                 |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`races/`](races/README.md)       | the competitor field and the per-rival head-to-heads — `field.sh` defines the roster and the shared timing harness every other race sources; `cold.sh`, `warm.sh`, `regex.sh`, `pcre.sh`, `scanner.sh`, `searchzip.sh`, `relate.sh`, `multipattern.sh` are the lanes |
| [`session/`](session/README.md)   | the warm resident-daemon tier — where the "warm is Nx faster" claim is measured and gated                                                                                                                                                                            |
| [`partition/`](partition/README.md) | the corpus-partition lane — `--docs` against the `-t` union a human hand-assembles, the one question no rival tool has a flag for, gated on population as well as latency                                                                                          |
| [`evaluate/`](evaluate/README.md) | the operational envelope — which regimes the dominance claim is certified over, with its own freshness contract                                                                                                                                                      |

`races/field.sh` names the rival roster and each rival's fastest honest
invocation; the apparatus beneath it — `KERNEL` (this checkout), `CORPUS` (the
tree measured), the rival indexes, and the timing
primitives — is the vendored floor at `bench/apparatus/field.sh`, which it
sources. Gates in `conformance/` and lanes in `certificate/mint/` source
it rather than re-deriving the field.

## The Field — Who Gist Races

`races/`, `../conformance/gates/`, and `../certificate/` all race `gist` against
the same **seven** code searchers, split by whether they keep an index. The
registry, fairness scoping, and per-tool invocations live in
[`races/field.sh`](races/field.sh) (sourced by every script except
`equality.sh`), which itself sources the vendored, cross-package
`bench/apparatus/field.sh` for the corpus-scoping and hyperfine-timing rules
every package's races share; columns auto-skip when a binary is not installed.

- **gist** — indexed, our product — resident RAM index (warm) or instant
  cold-load (cold).
- **csearch** — indexed, Google Code Search (Russ Cox) — gist's direct trigram
  ancestor, the apples-to-apples rival.
- **zoekt** — indexed, Sourcegraph's production indexed search (trigram +
  ctags symbols).
- **rg** — unindexed, ripgrep — the gold-standard parallel scanner.
- **ugrep** — unindexed, claims-fastest grep — SIMD + PCRE2-JIT.
- **ag** — unindexed, the_silver_searcher.
- **ggrep** — unindexed, GNU grep (`ggrep` on macOS) — the classic baseline.
- **git grep** — unindexed, the in-repo dev-workflow default.

Install the optional ones: `brew install ugrep grep` ·
`go install github.com/google/codesearch/cmd/{cindex,csearch}@latest` ·
`go install github.com/sourcegraph/zoekt/cmd/{zoekt-index,zoekt}@latest`.

### Which Rival, Exactly — the Identity a Mint Records

`@latest` names no version, so the roster above does not pin itself: the rival
is whatever the machine happened to have. Every mint therefore writes each
tool's identity to **`tool-versions.txt`** beside the receipts — the version
the tool reports of itself **and** the sha256 of the executable that resolved.
Both, because either alone degrades quietly.

A **digest alone** can name the wrong file. Under a version manager
`command -v csearch` resolves to the multiplexer, not the rival — a `mise` shim
is a symlink to `mise` — so shimmed tools hash to one launcher while still
reading as exact pins. Measured: `csearch`, `zoekt`, and `zig` all recorded the
single digest `20d3bc06…`, which is `mise`. `guard/artifacts.py` now fails
closed when two tool ids share a digest, and identity resolution walks `PATH`
for a candidate whose name survives symlink resolution (a multiplexer renames
itself; a real install does not), so the digest names the rival rather than the
launcher.

A **version alone** cannot distinguish two local builds of one release. Both
csearch copies on this box are module `v1.2.0` compiled by different Go
toolchains, and only the digest separates them.

csearch and zoekt carry **no version flag at all**, so their pin is the
embedded Go module version, read from build metadata rather than by running
them — `csearch version` treats `version` as the _regexp_ and prints a matching
corpus line, which scraped a bogus `26.3.0` into an identity before the probe
order was fixed. Expect `github.com/google/codesearch v1.2.0` and a
`github.com/sourcegraph/zoekt` commit pseudo-version.

## Fairness — Stated, Not Hand-Waved

Every tool is scoped to the same source roots (`$GIST_ROOTS` when set, else the
tree's own roots — `field.sh` resolves them once, mirroring
`corpus.resolveRoots`) and given its honest fastest path.

- **rg / git grep** honor `.gitignore` natively (skip the gitignored ~99 GB of
  build artifacts). **ag** is handed `--path-to-ignore .gitignore` (the root
  ignore set `rg` reads for free). **ugrep / GNU grep** have no per-file
  gitignore, so they get the heavy dir-exclude set (`$XDIRS`) — they still scan
  a slightly _larger_ file set (gitignored individual files `rg` skips), which
  only makes them do **more** work, so gist's win over them is conservative.
- **gist / rg** additionally run under `--no-ignore-vcs` plus the root
  `.gitignore`, so a multi-root race can't hit ripgrep's nondeterministic
  parent-ignore re-anchoring. That also discards every _nested_ `.gitignore`,
  which is why `field.sh` re-applies the build-output exclusions as globs
  (`$SCOPE`): without them these two alone walk build artifacts the root ignore
  never names — Elixir `_build`/`deps`/`cover`, Electron `out/` — that
  `gist index` prunes and csearch therefore never indexes. Not the whole of
  `$XDIRS`, because `vendor` holds tracked source; mix output is anchored per
  `mix.exs` root for the same reason rule-of-five anchors it.
- **csearch** indexes gist's **exact corpus file list** (the persisted
  `paths.list` doc→path table) → byte-for-byte the same files → result sets ≈
  `rg`'s. It is the faithful indexed twin (the small delta is the few files
  csearch's own binary heuristic drops: 16,696 of 17,112).
- **zoekt** has no file-list input, so it indexes the roots tree under the same
  heavy ignore set; its corpus is a documented superset (no per-file gitignore
  plus ctags symbol indexing). Quoted-literal counts still match `rg` on
  selective needles — treat it as a production-grade **timing reference**, not
  a correctness oracle (`rg` plus `csearch` are).
- Timing is `hyperfine` mean, warm page cache, fresh process. Every command's
  output is drained (`… | wc -l`) so ugrep's lazy multithreaded `-l` actually
  scans (it short-circuits when a harness discards its stdout) and a needle
  _miss_ (grep exits 1) doesn't abort the run. **Ratios** are the headline
  number — robust to this shared dev box's load because each query's tools run
  back-to-back under the same conditions.
