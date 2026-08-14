# Changelog

All notable changes to `gist` (indexed code search; also the chassis module that
`relate` and `blast` ride) are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track
`build.zig.zon`.

<!-- towncrier release notes start -->

## [1.2.0] - 2026-08-14

### Added

- A `note` fragment type, for the paragraph that frames a release rather than an
  entry in it. Towncrier renders types in declaration order and `note` is
  declared first, so it lands above `### Added` with no template fork and
  retires itself on fold like any other fragment.
- The Python binding has an import contract: `bindings/python/binding.zone`,
  governing `gist-search` the way `charter.zone` governs the Zig side.

  This is the one binding in the family with a warm path, so it is the one whose
  layering was worth writing down: the index lifecycle below, the facade and its
  `exact/` subpackage above as a single unit, tests on top. The cycle is declared
  rather than tolerated - `_native` asks `_daemon` whether a request is
  FFI-eligible, because that predicate is the daemon protocol's and should have
  exactly one definition, and it asks through a deferred in-function import so the
  load-time graph stays acyclic.

  Needs `zoning` 1.3.1, which is where the `python` dialect and root-anchored
  contracts both arrive.

### Changed

- The import contract moved to `charter.zone` at the repository root, out of the
  `contract/` drawer and out from under the package's own name.

  Two things were wrong with the old spelling. A contract governs the directory it
  sits in, so a folder holding one page bought nothing - the manifest, the
  formatter config, and the CI config all already live at the root, and this
  belongs beside them. And naming it after the package spent the filename on a
  third copy of a name that is already on the file's first line and already in the
  path, which meant every repository in the ecosystem called the same kind of
  document something different.

  `charter.zone` is that one name. Nested packages take a role name instead -
  `kernel.zone`, `service.zone` - because there the path already says which one it
  is. Identity was never in the filename: the `package` block is what every
  verdict, every `--package` filter, and every workspace lookup reads, so nothing
  downstream can tell the two spellings apart. Needs `zoning` 1.3.1, which is
  where a contract at a package root is first discovered; the pin moves with this.
- `gist index` decides whether to hold the corpus or stream it, from the machine
  rather than from a preference.

  `irregex` now offers a build that never holds the corpus: a census of paths and
  sizes, and each body read back when the pass that needs it reaches it. It costs
  4.1x less memory on llvm-project and 1.7x more wall, and neither of those is the
  interesting number on its own — which one matters depends entirely on how big
  the tree is relative to the machine looking at it.

  So the choice is made per build. `full` estimates the held peak from the corpus
  the last build published — the content shard IS that corpus concatenated, so its
  size is the answer, and erring high biases toward streaming — and holds only if
  that estimate fits in an eighth of physical memory. Above the line it streams.
  With no shard to ask, which is the first build in a fresh artifact directory, it
  streams: a build that cannot know how big the tree is should not be the one to
  discover it by holding all of it.

  An eighth is deliberate. Holding is faster, and on ordinary trees nothing about
  it is objectionable, so the line is not "is streaming cheaper" but "is this
  build about to take a rude share of a machine someone is working in". On the
  128 GiB host this was measured on, llvm-project's 1926 MiB corpus is held (8.2 s,
  2464 MiB peak) and a corpus four times larger would not be.

  `GIST_STREAM=1` and `GIST_NO_STREAM=1` pin it either way, which is what a
  benchmark comparing peak RSS against `csearch` or `zoekt` needs: the honest
  number for a shape is the one measured with that shape forced, not whichever one
  the host happened to choose.

  The streamed path falls open to the held one on any failure before publication —
  a census that cannot be taken, or a block builder that runs out of memory, costs
  a cheaper build and never the index. Past publication there is nothing to fall
  back to and both paths fail the same way.

  Two things that wanted the corpus now ride along with the pass that already has
  it. The crest sieve stops being its own phase — `GIST_TRACE=index` reports
  `trigram build + crest` as one lap on the streamed path — and the build records
  each doc's real length for the content shard's offset catalog, which is the only
  figure that catalog can honestly be built from once the sizes came from an
  earlier walk.

  PROVEN IDENTICAL: over llvm-project, a held and a streamed build publish the same
  `index.gist` (161,773,006 bytes), `crest.bin` (8,405,376) and `paths.list`
  (9,107,770), byte for byte. `content.shard` (2,030,371,064) and `tree.map` agree
  on every byte of catalog, paths, and bodies, differing only in the 8-byte anchor
  and the 32-byte seal over it — the same two fields that differ between two runs
  of one binary.

### Fixed

- Both published packages declared Apache-2.0 and carried none of it. The license
  text and the NOTICE live at the repository root, and neither a `.crate` tarball nor
  a wheel can reach above its own project directory - so the crate shipped an SPDX
  string and no license, and the wheel shipped the same. Section 4 of that license
  asks a redistributor for exactly those two files, which made this the one packaging
  defect that was not cosmetic. It mattered a little more here than elsewhere: this
  NOTICE is where the ripgrep interface conventions the package is a drop-in for are
  credited, so shipping without it dropped the attribution too.

  `LICENSE` and `NOTICE` are now committed beside both manifests, byte-identical to
  the root pair. The wheel names them in `license-files`, so they land in
  `.dist-info/licenses/` rather than only inside the sdist, where nobody installing
  the wheel would ever see them.

  `rust-toolchain.toml` stops shipping in the crate on the same pass. It pins 1.97.1
  so this repository's contributors lint identically - no business of anyone building
  the extracted crate, and it would have quietly overridden the 1.85 `rust-version`
  the sources actually ask for. The crate had no `exclude` list at all until now, so
  this is also the first thing standing between the tarball and whatever lands beside
  the manifest next.
- The GitHub Release page now carries the changelog section it names. Two
  changelogs were produced per release and only one of them was towncrier's:
  `skip-changelog` hands `CHANGELOG.md` to the fragments, but that key governs
  the *file*, and composing the release **body** is a separate path inside
  release-please that kept running off conventional-commit subjects. So the page
  people land on was assembled from commit subjects while the notes someone
  wrote sat in the changelog - irregex v2.1.1 published two lines against a
  folded section of a hundred and ten, because eleven of its thirteen commits
  were `ci:` or `docs:` and both are hidden. A `notes` job now posts the folded
  `## [X.Y.Z]` section over that body on tag, waiting for the release to exist
  rather than assuming it already does, and truncating at a whole bullet under
  GitHub's 125,000-character body ceiling rather than failing on a tag that is
  already immutable.
- The engine's CREST sidecar went to v6, and its rows widened from a 48-lane q=1
  vector to a 192-lane q=4 spectrum. This package is what writes those rows - both
  build paths do, the held one and the streamed one - so `gist` stopped compiling
  against the sibling the moment that landed; `persistIndexAndPaths` takes
  `?[]const crest.Spectrum` now.

  The held path was reaching for the right function's neighbor: `sidecar.build` is
  the q=1 table the resident session keeps for live documents, and
  `sidecar.buildSpectra` is the parallel q=4 pass the persisted artifact wants. The
  streamed path summarizes each doc inline while the trigram pass still has its
  bytes, and it asks for `crest.spectrum(bytes, max_rank)` rather than
  `crest.crest(bytes)`.

  Both paths have to agree on the rank, and that is the part worth saying out loud:
  the sidecar header records ONE q for the whole file, and `persist` stamps
  `max_rank` unconditionally. A streamed index carrying rank-zero-only rows under a
  q=4 header would meet a rank-1 demand with a zero, fall short of it, and prune a
  document that matches. That is a wrong answer, not a slow one, which is why the
  streamed path summarizes at the same rank the held path does rather than at the
  cheaper default.

  No new guard: this package's build jobs already check out `irregex` at its
  default branch, so the sibling's main is what every push here compiles against.
- The socket lives in the artifact home, and the artifact home is now one per
  checkout rather than one per directory. That is what lets a search from
  `services/ai` reach the tree's index - and it also means every subdirectory of
  one tree dials the same rendezvous. A session that went resident in the subtree
  was therefore handed queries from the tree root, and it answered them: real
  rows, correctly rendered, from a walk that had only ever seen a fraction of the
  tree. Nothing in the output looks wrong. You just get less of it.

  What the two sides were proving to each other was the tree, which used to be the
  same fact as the directory and no longer is. A persisted artifact and a resident
  session are bound to different things: an index is written in checkout
  coordinates so any directory under the checkout may ride it, while a mirror is a
  corpus walked from wherever the daemon started, and its answers are that walk's
  output. So the daemon publishes its STANDING beside its socket now - the working
  directory, resolved - and the client and the answer keep both prove that instead.
  A client standing elsewhere reads the rendezvous as not its own and answers cold,
  which is correct and merely slower.

  `station_parity.sh` is the permanent guard, and it earns the name by failing:
  with the old binding restored it reports the tree-root query routing warm and
  coming back empty over a tree holding two matches. It asserts the routing tier
  by name rather than only diffing bytes, because a daemon that quietly declined
  would make a warm-versus-cold comparison green without either arm ever being
  warm. Its corpus is deliberately large for the same reason - the elide oracle
  loads concurrently with the walk, and over a few dozen files the walk always
  wins, so a small corpus proves only that the live read works and passes just as
  happily with the rebase deleted.
- Three bugs in the release machinery, each of which alone was enough to stop a
  release, and together they are why main has said 1.2.0 since August with `v1.1.0`
  still the newest tag.

  `release-please-config.json` named the package. With `include-component-in-tag`
  off, release-please writes a standalone release PR's body with no component in it,
  and names the branch `release-please--branches--main` with no component either.
  Then, on merge, before it will tag anything, it compares that empty component
  against `component || package-name` - so a `package-name` here makes the two
  halves of its own bookkeeping disagree permanently. Every merge logged
  `PR component: undefined does not match configured component: gist-search` and
  returned without creating the tag or the release. That is worse than a missed
  release, because it wedges: an untagged merged release PR makes the *next* run
  abort before it opens anything, so the queue stops until someone relabels the old
  PR by hand.

  The fold's guard read the wrong side of the index. towncrier stages its own
  edits; it writes the newsfile and retires each fragment through `git add` and
  `git rm`, so a working-tree-vs-index diff is quiet the instant it finishes, even
  though it just rewrote CHANGELOG.md. The job compared against the index rather
  than HEAD, printed `nothing new to fold`, and exited 0 having done nothing. Every
  fragment this release was supposed to publish is still sitting in `changelog.d/`.

  And the fold only ran on the push where release-please rewrote the PR. The
  action sets its `pr` output only when it wrote something, so a `ci`/`docs` commit
  carrying a new fragment, which changes no version and therefore no note, left
  that output empty, and the job skipped with nothing saying so. The branch is now
  resolved from the `autorelease: pending` label instead, which is release-please's
  own marker for the PR it is holding open rather than a name guessed from a
  convention.

  `.release-please-manifest.json` claimed 1.2.0, a release that never happened -
  no tag, nothing on crates.io or PyPI, no changelog section. Left alone it would
  have made the next release bump *past* a number nobody can install, so it is back
  to 1.1.0, the newest version that actually shipped. The next release therefore
  re-cuts 1.2.0 with all of the fragments this one was supposed to publish, and the
  version already written into `build.zig.zon` on main becomes true rather than
  aspirational.

  With `always-update` on, the branch is rebuilt on every push while the PR is
  open, so the fold recomputes from main rather than appending to whatever the
  branch already carries - towncrier treats a second write of the same version as a
  hard error, not a no-op.

## [1.1.0] - 2026-08-05

### Added

- `pip install gist-search` used to buy a Python face with nothing behind it: the
  published wheel was `py3-none-any`, every verb shells out to a `gist` binary,
  and nothing in the distribution put one anywhere the resolver could find. The
  README's own quickstart — `import gist; gist.search(...)` — raised
  `GistNotFoundError` on the first call unless whoever ran it had separately
  built the Zig sources and put the result on `PATH` or `$GIST_BIN`. Import
  succeeding proved nothing about the product working.

  The wheel now bundles a native `gist` CLI per platform. `hatch_build.py`
  force-includes it at `gist/bin/gist[.exe]` and stamps the platform tag that
  promise requires (`py3-none-<platform>`, never `any`, once a native binary is
  inside); `scripts/build_wheels.py` cross-compiles the same six-target matrix
  `irregex`'s own wheel already ships (macOS arm64/x86_64, Linux
  x86_64/aarch64, Windows amd64/arm64), stripped, so the CLI wheel costs 4 MB
  instead of 22. None of it is reachable without `irregex>=1.1.0`'s matching
  `_resolve` rung, which is why that floor moved in the same release.

  `release.yml` proves it rather than asserting it: `wheels` builds the matrix
  and runs a real search — not an import — against the build host's own wheel,
  then `smoke` repeats that on the real GitHub-hosted runner for every other
  target, installing only the one wheel `pip`'s own tag matching picks out of
  the six, with no source checkout and no `PATH`/`GIST_BIN` override to fall
  back on. `publish` now waits on both.

### Changed

- Every package index this project publishes to now shows the repository's own
  `README.md` as the project's page, rather than the short one kept beside each
  binding. PyPI and crates.io are where most people meet this project first, and
  they were being shown a page about the Python binding's verbs - not the indexed code-search kernel underneath them.

  The README could not simply be pointed at, because a relative link resolves
  against whatever page displays it. `src/surface/face/gist/README.md` is correct on GitHub and a 404
  under `pypi.org/project/gist-search/`. crates.io is the worse of the two: it rewrites
  relative links against the crate's own subdirectory, so the same path becomes a
  well-formed URL into `bindings/rust/` pointing at a file that was never there,
  and nothing looks broken.

  So `tools/registry_readme.py` is now the one rewriter both ends share. It
  absolutizes every relative target against the `repository` URL the manifest
  already declares, in the form that serves what the target is - `raw` for an
  image, `tree` or `blob` chosen by what the path is on disk - and a target the
  repository does not contain fails the build instead of publishing a dead link.
  GitHub's `> [!NOTE]` alert, which renders as literal text anywhere else, is
  lowered to a bold lead line. Headings need no help: both renderers rewrite
  in-document anchors to match the ids they mint, so the table of contents arrives
  intact.

  Python gets it through a Hatchling metadata hook, so the corrected page exists
  only inside the artifact. Cargo has no metadata hook, so `readme` now points at
  a gitignored `bindings/rust/PROJECT_README.md` that the same tool mints at
  package time - `cargo package` fails loudly if it was never generated, and
  `cargo build` never reads it. Both indexes end up with a byte-identical page.

  An sdist is the one artifact with no repository above it, so it carries the
  corrected README beside the sources and a source build reads that, rather than
  being asked for a file the archive does not contain.

  Go needed no rewriting - pkg.go.dev renders the README at the module root and
  resolves its links against the repository - but a dead one there is still a dead
  link on the module's landing page, and a Go module has no build step to catch
  it. `--check` now proves those targets resolve too, on every commit.

  The README stays written for the repository it lives in.

### Fixed

- The changelog's own header claimed gist ships the `relate` binary. It hasn't
  since relate moved to its own package - `build.zig` only declares the `gist`
  executable, and says so in its module doc. The header now describes what gist
  actually is: indexed code search, plus the chassis module relate and blast ride.
- The root README had a Quickstart but no Install section, so the three published
  bindings appeared nowhere a reader looks first, and the Rust README's wiring
  block still said `cargo add irregex` / `cargo add gist` under an "Once
  published" comment - two names that resolve to unrelated crates now that the
  real ones are [`irgx`](https://crates.io/crates/irgx) and
  [`gist-search`](https://crates.io/crates/gist-search).

  The Go README was wrong in a way that only bites after you follow it. It gave
  `go get github.com/The-Billy-Company/gist/bindings/go`, which is correct, and
  then never said that the module root holds no package: the importable paths are
  `bindings/go/exact` and `bindings/go/index`. Fetch succeeded, import failed.

  All three now name the registry, the distribution, and the identifier you
  actually type, and the Python README says at the install - not forty lines below
  it - that the package is the bindings and the `gist` binary still has to be on
  `PATH`.
- Towncrier ran with `wrap = true`, which is right for one-line release notes and
  wrong for the multi-paragraph Markdown the fragments here actually are. It
  reflows each entry as one flat block, which loses a fenced code sample's fence,
  turns a hanging `-` at the end of a wrapped line into a setext heading, and can
  split an inline code span across a paragraph break. Off, the fragment's own
  layout survives and towncrier only indents it.

  `changelog.d` also had no README, so folding a release emptied the directory and
  git stopped tracking it - the next `towncrier create` would have been writing
  into a path that no longer existed in a fresh clone. It has one now, saying what
  a fragment is and that its layout is preserved.

  `version_parity.py` gained the skip its sibling in `irregex` needed: release
  notes name versions and the `x-release-please-version` marker as their subject
  matter, so a line-level "marker plus a number" heuristic reads them as stale
  mirrors. They are also the one file the release bot must never rewrite, since a
  past release's number is history rather than a copy of the current one.
- Windows now compiles and runs the shipped product without pulling POSIX-only daemon fixtures or measurement instruments into the native lane.
- `CLAIM.md` said ranking "reorders the complete verified hit set," full stop —
  read next to `--rank`'s documented default of a top-20 view, that is two
  different contracts for the same verb, and a reader had to guess which one a
  program should rely on. It now says both halves in one place: ranking scores
  every file in the complete set (nothing is excluded from the fusion, so
  membership never shrinks) and *presents* the bounded top-K by default; the
  same complete, unranked set stays one flag away through `-l` or full output,
  which ranking never gates.

  Separately, three documents restating the mined ripgrep replay's scoreable
  total had drifted from each other without anything noticing — two said 411,
  one still said 409, and `check_results.py` only ever watched the one README
  shaped like `results.json`'s own bucket table, not the sentences elsewhere
  that restate the same number in prose. Every restatement (`README.md`,
  `TESTING.md`, `CLAIM.md`) now carries an `x-rgsuite-total` marker, and
  `tools/evidence_parity.py` — wired into CI beside `check_results.py` — fails
  the build the day any marked line disagrees with `results.json` again,
  discovered by the marker rather than kept as a list.


## [1.0.0] - 2026-08-02

### Added

- A resident daemon now has a memory ration it cannot exceed, instead of an
  appetite bounded only by the corpus it happened to be pointed at. Measured on one
  laptop before this: a `gist serve` 36 seconds old holding 1904 MB, several of them
  resident at once across worktrees, and the machine out of memory.

  The new `exec/session/warden/` is three small pieces. `ration.zig` decides how
  many bytes this machine will lend — the smaller of a quarter of physical RAM and a
  work-shaped ceiling, floored so a machine too small to lend a useful share arms
  nothing at all rather than half a mirror (`GIST_MEMORY_MB` overrides). `warden.zig`
  makes that binding by being the allocator the daemon builds everything through, so
  the ceiling is a property of the process rather than a habit of its callers: one
  atomic test-and-add per allocation, which is what keeps eight concurrent workers
  from crossing it together and then each discovering it. Meeting it is the ordinary
  warm→cold declinature — the cold walk answers every query correctly — and the
  answer keep is surrendered first, since rendered answers are recomputable by
  construction (`Keep.surrender` tries its lock rather than taking it, because the
  hand runs inside a failing allocation on a thread that may already hold it).

  `standdown.zig` is why a ceiling was safe to impose at all. Bound the daemon and
  nothing else and an unfittable tree gets a spawn storm — meet the ceiling mid-load,
  exit, and let the next query fork a replacement that dies the same way, forever.
  A daemon that stands down leaves a note beside its socket, and the note records
  *which ration* it was refused under, so a raised `GIST_MEMORY_MB` takes effect on
  the next query instead of waiting out the expiry: the note blocks the spawn and
  only a spawn can lift it, so a refusal that covered every later attempt would have
  stranded the warm tier with nothing to say it had already been fixed.

  A bound that costs throughput is not worth having, so the overhead is measured by
  a gated bench (`zig build warden`) that fails rather than reports, against the
  allocator the daemon actually gets (`smp_allocator`) and decomposed against a
  wrapper that forwards and accounts nothing. That decomposition is what mattered:
  interposing an allocator costs 0.1-0.6 ns/op, so the whole cost was accounting —
  and charging one shared counter per allocation cost **217 ns/op with 8 workers
  against 0.5 ns bare**, a guard 350x the work it guarded, because `smp_allocator`
  scales by giving each CPU its own shard and a global counter reintroduces exactly
  the contention it exists to avoid.

  Fixed by charging wholesale and spending retail: `charge` claims 256 KiB at a
  time into a per-thread lane (one counter per cache line, carrying its own copy of
  the backing allocator so the fast path touches a single line), and allocations
  spend from the lane. Shared state is touched about once per 256 KiB instead of
  once per allocation, which puts the 8-thread cost at 0.4-0.9 ns/op over the
  no-op wrapper - inside machine noise, a 230x improvement. The ceiling stays
  absolute because the shared counter tracks *reserved* bytes: live usage is always
  `held` minus unspent lane credit, so it can never exceed the ration, and `sweep`
  reclaims every lane before anything is refused so the strictness never becomes a
  false refusal. Lanes are process-lifetime slots borrowed by index, so a dead
  thread strands nothing - its credit stays reclaimable, and Zig has no
  thread-exit hook to rely on. Two tests pin it: a lane may not hoard what the
  ceiling needs (it fails if `sweep` is deleted), and eight workers with room for
  many batches still never cross the ration.

  What remains is a floor - a hard ceiling must claim on alloc and release on
  free, and two uncontended atomics cost ~2.2-3.6 ns - so the serial column is
  marginally worse than the shared-counter version in exchange for the 230x
  parallel win. End-to-end nothing was ever detectable anyway: mirror load plus
  index build 1650 ms metered against 1675 ms bare, warm queries 3.6 ms against
  3.7 ms, both inside run-to-run spread with the winner flipping between rounds.
  Two layout facts came out of the same measurements, both against intuition:
  `held` and `crest` deliberately *share* a cache line (splitting them cost 1.3
  ns/op, since a charge writes one and reads the other), while the diagnostics are
  pushed off it; and `charge` reads the crest before updating it, because an
  unconditional second read-modify-write on the hot line cost 293 ns/op where the
  conditional costs 117, and a high-water mark that only rises is safe to skip.

  The meter earned its keep immediately by pricing a spike nobody could see. On this
  repo the daemon settles at 583 MB but *crests at 2793 MB* while building its warm
  trigram index, because that build is out-of-place — ~138 M postings at 8 bytes
  each in per-shard buffers, counting-sorted into a second buffer the same size.
  Shrinking each shard's unused tail before the output is claimed took the crest
  from 3464 MB to 2793 MB with the settled set unchanged and postings byte-identical
  (capacity only). The remaining 2× is inherent to the out-of-place sort, and it —
  not the steady state — is what currently sizes the ceiling.
- A verification lane nearly certified a tree as immune to an environment variable
  on the strength of a run that never executed. The trap belongs in both packages
  that can hit it, so it is now in the README under "Build and test" here as well
  as in irregex, which owns `brigade.zig` and carries the longer version.

  `zig build test` caches the test run and the environment is part of the cache key.
  `-Dtest-filter` reaches the harness as `BRIGADE_FILTER`, an environment variable
  set on the run step, and Zig hashes a run step's environment along with its argv.
  So a new environment always executes and any environment you have already used
  replays from cache - step skipped, nothing run, exit 0 in about a third of a
  second here. Note the direction, because I had it backwards at first: the problem
  is not that environment variables are missing from the cache key, it is that they
  are in it, so every distinct environment earns a durable entry that is replayed
  on the second visit.

  That is exactly the shape of an immunity probe - set the variable, run; unset it,
  run again to confirm - where the confirming leg revisits a seen environment and is
  therefore green by construction. The tell is neither the exit code nor the test
  count: a cached run still prints `1/1 tests passed` under `--summary all`, and the
  only distinguishing token is `cached` against `success <n>ms`.

  The README's answer is to drive the compiled test binary directly, which has no
  build-cache layer and executes every time, with `BRIGADE_TIMES=1` as the evidence
  it did.

  Measured here, not transcribed: A, B, A', B' over one probe variable gives
  `success 3ms`, `success 3ms`, `cached`, `cached` - four exit-0 runs all claiming
  1/1 passed, two of which ran nothing.
- Added **`gist --generate`**, which mints `gist(1)` and bash · zsh · fish · PowerShell completions from the same `flag_catalog` the argv parser dispatches on. `zig build` now places them where each installed shell already looks, so `man gist` answers and `gist -<TAB>` completes with no configuration; `GIST_SHELL_INSTALL=0` declines, and a shell that isn't installed is never touched.

  The point is not that ripgrep lacks these — its zsh completion is the best hand-written one in the field. The point is that it _is_ hand-written, and carries a comment asking you to re-run a CI script "to ensure that the options supported by this function stay in synch with the `rg` binary". A drift gate is an admission that there is drift to gate. Minting from the parse table removes the category, and buys three things with the effort that would have gone into keeping it in sync.

  **A tab costs no process.** `_rg_types` answers `-t<TAB>` by forking `rg --type-list` and re-parsing it, per keystroke; gist's menu is an array written into the file at generation time. Measured here with both functions' candidate sinks stubbed identically, so only the gather is timed: **5.0 ms → 0.065 ms, ~77×** (an earlier run on a busier machine put rg at 6–9 ms; gist's side barely moves, because there is nothing in it to slow down). gist's 239 candidates each arrive with their globs attached, where rg discards them by default and shows 224 bare names. The same holds for engines, sort keys, color postures and hyperlink aliases, and the bash side filters its baked menus with a pure-shell loop rather than a `compgen -W` subshell, so the claim is literal in all four shells.

  **The menu is grouped.** `rg -<TAB>` is one alphabetical wall of flags. `gist -<TAB>` arrives as captioned sections — _Corpus — which bytes are searched_, _Semantics — what counts as a match_, _Presentation_, _Execution_ — and the man page is organized the same way, because both read the `Reach` the parser already records to decide what a persisted setting may do. A flag lands in the right section by being classified at all, and the manual answers the question a reader actually arrives with instead of what comes after `--max-filesize`.

  **Mutual exclusion is derived.** `-i`/`-s`/`-S` rule each other out in the menu because they resolve to one case mode in the parser, and `--context-separator` fights `--no-context-separator` because they assign one string — a pairing no hand-kept exclusion list thinks to make. Three exhaustive `switch`es over the action union decide what each flag takes, displaces, and where it belongs, so a new action is a compile error until someone answers all three.

  **The menu tells the truth about the grammar.** Three defects that only a real keystroke finds, each fixed at the generator: a verb is offered at `argv[1]` and nowhere else, because `gist -w index` searches for "index" and a menu that captions it "build and persist the index" is lying (fish's usual `__fish_use_subcommand` is the _git_ rule — it skips leading flags — so naming it would have been the bug); a glued short value is split before the flag-list fallback, so `-t<TAB>` menus the type registry where ripgrep's generated bash dead-ends; and the zsh value tags are named ahead of the option groups, because zsh offers the first tag-order entry that yields anything and the caller half-way through `-t` wants a type, not the flag wall they have already left.

  the shell-completion suite under `shell/` is the other half of the proof: bash, zsh, fish, PowerShell and mandoc each parse their own artifact, every flag is shown to be filed in exactly one captioned group, the three grammar rules above are asserted against the generated bytes, and no generated file may run a program at tab time. The man page is pure ASCII roff, folded where mandoc measures it, and mandoc-clean with no exceptions: it carries a real date, and `SOURCE_DATE_EPOCH` pins it, so a packager or a drift gate gets identical bytes while a human minting their own page gets the day they minted it.
- Added `irgx_last_fault(irgx_fault *out)` — the C seam's per-incident detail pull, plus the one `Fault → Status` translation behind it. A status code is one of six values, so it can name a _kind_ of failure but never the incident; and because the in-process session deliberately scopes assay's diagnostic sink `.dark`, an embedding host previously had no way at all to learn _which_ fault, about _which_ file, at _which_ byte. This is a pull, not a second sink: `sqlite3_errmsg` / `git_error_last` semantics — per thread, last fault wins, `path` borrows thread-local storage until that thread's next call, and reading does not consume. `irgx_fault` is `struct_size`-checked and append-only like `SearchRequest`, so a newer field is a forward-compatible extension rather than a silent reinterpret; the symbol is purely additive, so `gist_abi_version` stays `2`. The translation itself now lives once, beside `Status` in `surface/ffi/contract.zig`, read off `contract/search_api.toml`'s `disposition` column rather than chosen at each call site: a new `Disposition` enum makes the contract's three channels executable, `Status.disposition()` proves `stale` is a declinature (negative, but not an error), and `Status.ofFault` switches exhaustively over all nineteen `fault.Fault` members so a new taxonomy member is a compile error instead of a fault silently reported as a clean run. Every entry point that starts work now opens the fault window first, so a host asking after a **successful** call is handed nothing rather than an earlier failure, while the four destructors and both readers leave the slot alone so a cleanup path can still report it.
- Added a **resident answer keep** to the `gist serve` daemon, so a verb whose answer is a pure function of the corpus is not recomputed while the corpus has not moved. Every other acceleration in this kernel makes one query cheaper; some questions have no cheaper form — `relate echoes --shape distinct` is a claim about every pair of files, and there is no index over "every pair" — so the only remaining elision is a sweep already done over the same bytes. Measured on this tree: `relate echoes --unit function --shape distinct` 27.5 s → 4.9 ms (5567×), `relate echoes --shape distinct` 8.1 s → 6.2 ms (1315×), `relate echoes --unit function --shape families` 3.4 s → 5.7 ms (590×), `irregex blast Corpus` 2.3 s → 4.8 ms (471×), `relate echoes --as shapes --shape families --unit function` 1.8 s → 4.7 ms (381×), each byte-identical to its cold answer.

  The keep is shaped so it cannot become a second source of truth. **The daemon never computes**: a client computes cold and offers its rendered stdout back stamped with the corpus change epoch it read _before_ it started, and the daemon retains those bytes only if the epoch has not advanced since — a store that cannot recompute cannot recompute differently. The key is the literal question rather than a hash (tool, verb, argv, canonical cwd, every scoping environment knob, and the running binary's own size + mtime, so a rebuilt verb is never served its previous build's answer). Output is teed, not buffered, so an early exit or a closed pipe costs a keep entry and never a byte of the answer. Every failure mode — no daemon, stale protocol, a watcher that cannot vouch for an epoch, an oversized answer — is silence, and the verb behaves exactly as it did before. `GIST_NO_KEEP=1` opts out; a TTY is out of the envelope entirely.

  Two supporting fixes. The freshness annals' `doubt` flag now poisons only _which_ files changed, not _whether_ the corpus moved: an unmappable event advances the epoch instead of making it unanswerable, so one unresolvable path no longer silently disables the keep for the rest of the daemon's life. And a recalled answer says so — stdout stays byte-identical, but stderr closes with a `recalled · epoch N · N B` line in place of the verb's own summary, because that summary's file counts and milliseconds describe work the run did not do.
- Added ripgrep's two **message switches** — `--no-messages` and `--no-ignore-messages` (with `--messages`/`--ignore-messages` to undo them left-to-right) — closing the last lane of gist's stderr that had no switch at all. `--no-messages` quiets the per-file line for a path that would not open, descend, or preprocess, the `-L` symlink-loop report, and the "no files were searched" verdict; `--no-ignore-messages` quiets the narrower lane for an ignore source that would not open, and `--no-messages` subsumes it exactly as it does in rg.

  **Suppression is cosmetic by construction.** Flagging the run and reporting it were already separate statements at every producer, so a quieted walk error still exits 2 and a quieted ignore message still exits 0 — measured against live rg for all three producers. That split is the half of this feature a careless implementation breaks, so it is what the new differential asserts: rg's own mined `--no-messages` cases score on the exit code alone, which a gist that merely _rejected_ the flag also satisfied (both exit 2). `bench/rgsuite/flags.py` now proves the real property — stderr goes empty while stdout and the exit class do not move — across four flag postures × three producers × both engines.

  The gate itself is `assay.Chatter`, the exact inverse of the existing `GIST_TRACE` lens: a lens is dark until it is named, a chatter class speaks until it is muffled. Both live behind one thread-local sink, so the C-ABI never-write contract and the daemon's per-request capture keep holding without a second mechanism. The nesting between the two switches is resolved once in `assay.muffle` rather than re-derived per call site.

  Fixed alongside it: a named `--ignore-file` that will not open was previously **silent**, so rules the user explicitly asked for could go unenforced with a clean exit and no way to notice. It now reports with rg's errno phrasing (`gist: nope.ignore: No such file or directory (os error 2)`) and, as in rg, still does not error the run — an unenforced ignore source is advisory, unlike an unreadable directory.
- Apache-2.0, matching the rest of the ecosystem: the same permissive freedoms as MIT plus an explicit patent grant, a NOTICE obligation, and a stated-changes requirement. NOTICE records that nothing third-party is bundled here — the dominance certificate measures ripgrep, csearch, and zoekt by invoking binaries the operator installed, so no competitor's bytes ship in the package — and that the rg-parity conventions this chassis is a drop-in for are implemented from published behavior, credited in the module headers and `research/gist/PRIOR_ART.md`.
- Every one of these repositories has shipped a `deny.toml` since the crate existed, and not one of them ever ran it. Four checks were written down and none enforced: a RustSec advisory against anything in the graph, the banned crates that would mean a regex binding grew a TLS stack or an async runtime, the license allowlist, and which registries a crate may come from. A policy nobody runs is a policy nobody has.

  So `cargo deny check` is a step in the `rust` job now, on a prebuilt binary rather than the Docker action - that action takes a repo-root-relative manifest path and the checkout layout differs in every repo here, so a plain step inheriting the working directory is both shorter and harder to get wrong.

  It passed first try in all four, which is the good version of this news and also exactly why it needed wiring: nothing was wrong, so nothing would have said when something became wrong. One thing needed saying out loud. The allowlist is a policy - the licenses this project accepts - not a snapshot of today's graph, so most entries go unmatched and cargo-deny warns once each. Shrinking the list to silence that would invert the point, because the next permissively-licensed crate would fail and get fixed by widening the list again, one entry at a time, with nobody deciding anything. `unused-allowed-license = "allow"` says that instead.

  While in there: the toolchain pin asked for `rust-src`, which nothing in this repository uses. Every contributor and every CI run was downloading the standard library's source to satisfy a component no build reads. It is gone, and the pin now carries the same comment its three siblings do.
- Every published Dominance-and-Fit Certificate now appends a row to a mint ledger (bench/certify/LEDGER.md) recording its corpus, the layers it actually carried, its verdict tally, and its cold/crest geomeans — so a re-mint that silently drops a layer is caught at the mint instead of surfacing later as a stale documentation pin. Verify with 'python3 bench/certificate/ledger/ledger.py verify'.
- Layer I of the certificate now measures gist as a pure scanner — `--no-index`, no crest sidecar, no resident daemon — against ripgrep, because the interesting claim was never that an index is fast. `bench/races/scanner_headtohead.sh` races the same 12 query classes Layer A certifies (plus a `-c` lane, where no short-circuit is available and every candidate must be scanned whole) with INTERLEAVED round-robin sampling rather than block-per-tool, so a load excursion on a machine ~10 agents share cannot be mistaken for a tool difference; every cell is equivalence-checked against rg's exact result set before it is timed, because a timing number for a wrong answer is worse than no number. `bench/certify/certify_scanner_report.py` splices the verdicts under the certificate's own fail-closed statistic (lower median AND Mann-Whitney p < 0.05) and refuses to splice if any class loses or if measured rg-conformance drops below its committed floor. Measured: 24 of 24 cells are outright wins with the index switched off — no parity cells and no losses — at a 1.93x geomean, with the index then adding a further 3.1x on top. Conformance is measured against a denominator ripgrep owns rather than one we chose: 186 flags read from rg's own generated completions and man page (176 byte-identical, 10 declared boundaries each re-verified this run, 0 divergent, 0 unprobed) plus 411/411 of its mined `tests/` corpus. The "scanner by design" claim is therefore not a claim about design at all, and it does not survive measurement.
- Nothing was checking the news fragments, and the way that fails is nastier than
  it sounds. `towncrier build --draft` does not complain about a filename it cannot
  parse; it just does not treat it as a fragment. So a file typed `.fixd.md`
  instead of `.fixed.md` renders nothing, exits 0, and stays invisible until
  somebody notices the entry missing from a release - by which point the fragment
  is buried among the sixty others in the directory.

  I checked whether `--draft` on its own was the right gate before writing one, and
  it is not. Against the real fragment set it is completely blind: a typo'd type, a
  file with no type at all, a wrong-cased `.Fixed.md`, and an empty type all give
  exit 0 with stdout byte-identical to a clean run and nothing on stderr. Adding
  `--draft` alone would have been a green tick over exactly the defect it was
  supposed to catch, which is worse than no job because it reads as coverage.

  The strictness has to come from `ignore` in `towncrier.toml`. Setting that key -
  even to an empty list - flips towncrier from skipping unparseable filenames to
  failing on them, with a message naming the file and telling you to whitelist it
  if it was deliberate. That is the right place for it: the fragment grammar stays
  in towncrier's hands instead of being re-spelled in a filename parser here, the
  same reason the formatter's file set comes from `git ls-files` rather than a path
  list. It also means a contributor running `towncrier build --draft` locally now
  gets the identical error CI does, which is the part a CI-only check would have
  missed.

  `towncrier check` is deliberately not what this runs - that verb asks whether a
  branch added a fragment, which is a contribution policy and a different argument.
  This job only asks whether the fragments that exist are well-formed.

  There is also a guard against the job passing over nothing, in the same spirit as
  the formatter's "found no .zig files": a misconfigured `directory` renders "No
  significant changes." and exits 0, so the job fails if fragments are sitting on
  disk while towncrier reports none. It is conditioned on fragments actually
  existing, so the honest empty draft right after a release still passes.

  Proven the whole way round: green on the real tree, exit 1 naming the file when I
  drop a `.fixd.md` into a faithful copy, green again once it is removed, and exit 1
  on the vacuous-green case when the fragment directory is pointed somewhere empty.
- The Python and Rust bindings now tell the engine's two exit-2 classes apart,
  because they ask for opposite responses. `UnsupportedPatternError` /
  `Error::UnsupportedPattern` still means *this pattern is outside the linear
  engine, retry on `pcre2`/`auto`* — real advice. The new `BadPatternError` /
  `Error::BadPattern` means *no grammar here accepts this at all*: the message
  names the defect and points at the offending byte, and no `engine=` choice lifts
  it.

  Both used to arrive as the unsupported class, so a caller retrying on PCRE2 for
  `[abc` retried into a second failure. The new class is a sibling rather than a
  subclass, precisely so that `except UnsupportedPatternError` no longer catches
  it — a retry loop written against that class would otherwise keep retrying
  something nothing can compile.

  The classification reads a phrase the engine prints only after asking PCRE2 and
  being refused too, so it reports a probe's verdict rather than guessing at one.
  Malformed is tested first, because PCRE2's own message can contain "not
  supported" and the diagnostic echoes the user's pattern, which can contain any
  marker word at all.
- The Python binding now imports all three faces, and stops pretending a program wants what a terminal wants. Previously the package covered gist alone: every kinship, retrieval, and composed verb was reachable only by shelling out and re-parsing text, which is exactly the reflex the unified importable API removed for exact search. The new surface is thirteen verbs across four modules — `kinship` (`similar`/`dups`/`clusters`/`echoes`, plus the function-granularity `concepts`/`fragments`), `retrieval` (`recall`/`pack`/`quote`), `radius` (`blast`), and `compose` (`context`/`family`/`provenance`) — over shared infrastructure lifted into `corpus` (scope lowering, the NDJSON+diagnostic verb runner, `Region`, the `Kin` result), with the multi-pattern sweep (`patterns`/`pattern_counts`) relocated into its own `sweep` module. It deliberately **diverges from the CLI wherever a caller's needs differ**, because the CLI's answer is a rendering and a program needs the model behind it. Calibration was the sharpest loss: the kernel grades every distance against per-channel bands, then prints that verdict to _stderr_, so a subprocess caller received a bare `0.78` — a number that looks like a result and frequently means "both files are Python". `grade.py` mirrors `src/surface/cli/grade.zig` as `StrEnum`s that know their own polarity (a gap channel improves as it rises, a distance channel as it falls — the inversion a hand-rolled threshold gets wrong), every row carries `grade`, `min_grade=` withholds background engine-side, and `Kin.at_least()` re-filters without a second process. `tests/test_grade_parity.py` reads the Zig source as its oracle and asserts every tag, alias, cut point, band edge, NaN case, and the `meets` floor, so the mirror cannot drift silently. The same principle drove the rest: `Kin` carries the scored population, warmth, and elapsed time the CLI leaves on stderr (nearest-of-three and nearest-of-twenty-thousand are different claims); `Region.read()` returns the source a program has to be handed rather than the coordinates a human goes and looks at; `Blast.paths`/`.exact_paths` expose the edit set the six printed sections are evidence for; `FamilyReport` keeps families and unaffiliated implementations as separate collections instead of one stream to re-sort; `Packed` reports coverage and foreign chunks beside its picks; results are complete rather than trimmed to a context budget; and `atlas_status()`/`atlas_index()` let a long-running process decide warmth once, with `can_quote` preflighting the one artifact `quote`/`provenance` genuinely require instead of catching its absence. Scope refusal moved into Python too — `context`/`family` raise on an unscoped call rather than surfacing an opaque exit 2 from the child. No analysis was reimplemented: grades come off the row when the engine emitted one, and Zig stays the sole case, class, and calibration authority. Verified by 51 tests across grade parity, kinship, retrieval, composed verbs, and atlas lifecycle — 46 of them new — each exercising a real built binary over a planted corpus rather than a mocked stream.
- The certificate machinery decides whether a published dominance claim is
  well-formed - the mint ledger, the cross-machine release gate, the report
  post-processors - and nothing was running its tests. 55 tests across four suites,
  all passing, none of them in CI. A break in that subsystem would not have
  surfaced until someone tried to mint, which is the worst possible moment to start
  debugging it.

  So there is a `certificate` job. It runs on a bare checkout with no Zig and no
  sibling, and that is worth saying because it is the sort of thing later "fixed"
  into something slower: none of these suites build or drive a gist binary. They
  are hermetic by construction - every certificate, bundle and residual record is
  synthesized into a tmpdir - and their own docstrings say so.

  That also means the job does not want the minted artifacts, which matters right
  now. The published bundles under `bench/certificate/artifact/` were purged and
  gitignored because they had been minted over a corpus that is not public. The
  machinery survived that intact and the tests never touched those artifacts, so
  this job is the standing proof of the separation rather than something that
  quietly needs them back.

  Two steps, because they catch different things. The suites are enumerated from a
  glob rather than listed, for the same reason the formatter's file set is. Then
  every module gets imported, which earns its place: `test_release` already reaches
  `release` → `artifacts` → `layers` transitively, but nothing reaches `ratio.py`
  or the nine report post-processors, so a bad import in one of those was
  invisible. I proved both halves by injecting defects - breaking the ledger's
  column-alignment contract (`c.ljust(w)` → `c`) fails the suite step with
  `FAILED (failures=1)`, and appending a bad import to `ratio.py` or
  `report/portable.py` sails past the suites at exit 0 and is caught only by the
  import step. Both revert clean.

  One caveat for whoever reads a future red X: `report/test_scanner_residual.py`
  puts `bench/conformance/rgsuite/` on `sys.path` and drives `fuzz._klass`, to prove
  every residual class the harness can emit has prose in the reporter. The coupling
  is the test's entire point, since that vocabulary has two owners and drift
  between them is otherwise silent, but it does mean a change to the fuzz harness
  can fail this job. Reconcile the two; do not drop the suite from the glob.
- The conformance slate now lives here, where the binary it oracles is built.
  `bench/conformance/` — the `rg` parity gates, the behavioral-contract gates, the
  mined ripgrep drop-in replay, the stderr goldens, the CLI-shape admission
  matrix, and the cross-compile target matrix — arrived from the engine package
  along with the corpus fetcher that was its only consumer, now at
  `bench/apparatus/corpora/`.

  The split left it behind, and the seams said so before anyone noticed: the
  contract gates already sourced `gist/bench/dominance/races/field.sh`, the target
  matrix already pinned `bench/certificate/report/portable.py`, the shapes README
  already called itself `gist/bench/matrix`, and half of this repo's own prose
  already cited `bench/conformance/…` as a local path. Four parity gates were
  resolving the `gist` binary out of the engine's `zig-out`, where it is never
  built, so they had been failing to find their subject rather than failing to
  prove anything about it.

  From here the resolution is what it reads like — `PRODUCT` is this checkout —
  and `rgsuite/stress.py`, which finds the binary by walking up three parents, is
  correct without being touched. `patterns_corpus_parity.sh` now builds the
  sibling `relate` from its own package instead of expecting one `zig-out` to hold
  both binaries.

  Re-run from `bench/conformance/rgsuite`: 411 of 411 supported cases byte-identical
  to ripgrep 15.2.0, on both the parallel and the serial engine.
- The public tree now judges the parts a compiler cannot: prose, spelling,
  manifests, shell, editor shape, and binding lint all fail in CI when they drift.
  GitHub Actions joins the same contract; every action is pinned to verified bytes
  instead of trusted through a movable tag.
- The repository had a license, a NOTICE, and eight workflow jobs across two
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
- This repo had no CI at all after the split, which meant the only thing standing
  between a bad commit and `main` was whoever happened to run `zig build test`
  locally. It has two workflows now. `ci.yml` is four jobs for the four faces -
  the engine on Linux and macOS, the Python binding across 3.12/3.13/3.14, Go,
  and Rust - deliberately not one job, because a Zig engine regression and a
  clippy nit are different news and a single red X reports them as the same thing.
  `windows.yml` is the native Windows lane, on x64 and on windows-11-arm, ported
  over from the monorepo it was written in: the suite, a ReleaseFast build, the
  index-elision parity gate, a CLI smoke over the rg exit-code contract, the
  Win32 block (path separators, ignore rules spelled with `/`, `--max-depth`,
  `--one-file-system`, console color, preferences under `%LOCALAPPDATA%`), the
  resident tier and its watcher, and `install.ps1` proven by running it. Cross
  compilation says the Win32 arm compiles; only a Windows kernel can say whether
  `NtCreateFile` really descends an NTFS tree.

  The interesting part was the sibling. `build.zig.zon` resolves `irregex` as
  `../irregex`, and so do all three bindings independently - the Go `replace`, the
  uv source, the Rust path dep - so a bare clone of this repo builds nothing.
  `actions/checkout` refuses a `path:` that leaves the workspace, so the obvious
  `path: ../irregex` is not on the table. Both repositories are checked out into
  subdirectories of the workspace instead, which makes them siblings of each
  other, and every one of those relative paths then resolves exactly as written.
  Nothing in the package is patched for CI; what builds in CI is the layout a
  contributor actually clones.

  Two assumptions from the substrate's CI turned out to be false here and are
  worth naming, because copying them would have produced a green lane that proved
  nothing. Its Go and Rust jobs install no Zig, on the correct reasoning that
  those modules link a vendored archive and `go get` needs no toolchain - but
  gist's bindings are subprocess transports over the certified binary, so all
  three suites need a real `zig build` first, and the Go suite fails rather than
  skips without one. And the Python packaging gate stages `libgist` beside
  `libirgx` from the *sibling's* `zig-out`, so that checkout gets built too or
  the assertion silently takes its skip branch. ripgrep is installed on the Linux
  jobs for the same reason: it is the oracle the parity tests compare against, and
  without it on PATH they skip, which is a parity gate that has stopped gating.

  Dropped on the way over: the monorepo's `paths:` filter and the scope job that
  replaced it, both of which existed only because a required status has to be
  resolvable on a PR that touches none of the kernel. Here the repository is the
  package, so there is no out-of-scope PR and nothing for the filter to say. The
  job that collapses the matrix into one verdict stayed, because its reason is a
  GitHub fact rather than a monorepo one - a matrix job reports one status per leg
  and never one under its own id - but `skipped` is no longer a pass in it, since
  nothing gates the legs anymore and a leg that did not run is a lane that was not
  proven.

  One extraction bug fell out of writing the install step: `install.ps1` still
  expected to place `gist.exe`, `relate.exe` and `irregex.exe` out of this
  package's `zig-out`, and this package builds exactly one of those now, so the
  installer threw before placing anything. It installs `gist`, and its "install
  Zig" hint no longer points at a `.mise.toml` that did not come across the split.
- Zig is the language this package is written in and it was the only one here whose
  formatter nothing checked. Rust already got `cargo fmt --check` and `cargo clippy
  -D warnings` on every push in the `rust` job; `zig fmt` was on the honor system.
  irregex, relate and blast each grew a `fmt` job for this already, so gist was the
  last one running without.

  The drift this catches is not the kind you spot in a diff. `zig fmt` pads a
  column-aligned multiline array literal into a grid, so a rename that shortens the
  widest cell leaves every row beneath it one space too wide, in files nobody
  edited. That deserves a red X that says "formatting" rather than one buried at
  the bottom of a build log, which is why it is its own job: folding it into
  `engine` would run it once per host for a verdict that cannot vary by host.

  The file set comes out of git rather than being written down, and this package is
  a good argument for why. The obvious hand-written list is `src/ bench/` - which
  would silently skip `build.zig` sitting at the repository root, and `tools/`
  looks like it would hold Zig and holds only Python, so a list naming it would
  check a directory with nothing in it while missing a real file. `git ls-files -co
  --exclude-standard '*.zig'` is every Zig file the repository owns; what it leaves
  out is exactly the ignored trees (`zig-out/`, `.zig-cache/`, and the fetched
  `zig-pkg/`, which parks a whole `build.zig` of its own), and those are named in
  `.gitignore` where someone can review them.

  It needs no sibling checkout, unlike every build job in this file, because it
  reads files instead of configuring a build - so it is also the cheapest job here.

  I watched it fail before believing it: 50 files check clean today, a deliberately
  mis-padded grid literal dropped at the repository root takes it to exit 1 with
  the offending file named, and deleting that file puts it back to 50 clean. The
  enumeration picking up a brand-new root-level file is the same thing the
  hand-written list would have missed.
- `.mise.toml` and a committed `mise.lock` turn the Setup table in `CONTRIBUTING.md` into `mise install`. Zig, Rust, Go, Python, and uv are pinned at the versions CI already uses, with checksums recorded for all four release platforms. The pins are mirrors of `build.zig.zon`, `bindings/rust/rust-toolchain.toml`, `bindings/go/go.mod`, and the `--python` CI hands uv - never the authority, so a bump has to touch both files or nothing resolves the way it reads.

  The discipline gate's binaries are pinned the same way, and for the same reason a red X should mean the same thing in both places: markdownlint-cli2, typos, shellcheck, and golangci-lint, each at the version its CI step already resolves. Two of those come from the versions their actions bundle, which is why the markdownlint action moved up to v24.1.0 in the same pass - it had been running markdownlint-cli2 0.22.1, one minor behind the 0.23.1 pinned here.

  The other half of the gate is deliberately not here. Ruff, yamllint, taplo, editorconfig-checker, towncrier, and zizmor arrive through `uv run --no-project --with <pkg>==<version>`, which is a version authority already - written in the workflow, repeated verbatim in `CONTRIBUTING.md`, and needing no install step at all. A second pin for those could only ever disagree with the first.

  ripgrep is pinned alongside them, which needs a word since the CI step that installs it argues the opposite. That step is right: the parity corpus is a handful of files and three patterns, so the comparison does not turn on which rg release a runner carries, and this pin makes no claim that it does. It is here for presence, not version. The conformance gate exits 1 without an oracle rather than skipping - deliberately, because a parity gate that skips has stopped gating - and the failure that produces on a laptop missing `rg` is a gate failure that says nothing about the code. One `mise install` and the oracle is there.
- `bench/conformance/gates/parity/type_union_parity.sh` - a permanent guard that
  every `-t` named on the line reaches the answer, with ripgrep as the oracle.

  It exists because a real bug got through: a `--type-add` name selected with
  `-t` was routed into the `-g` include set, which ANDs against the built-in
  types rather than joining them, so one custom type silently voided every other
  type on the line (fixed in irregex, `Builder.addType`). Each half was
  individually correct - built-ins union with built-ins, a custom type alone
  matches rg exactly - so only the mix diverged, and no existing case asked for
  the mix.

  The gate checks per case that gist's file set is byte-identical to rg's; that
  the mixed answer contains each part it was built from and is strictly larger
  than both; that `-T <custom>` subtracts exactly what `-t <custom>` selected;
  and that a custom `-t` still respects `.gitignore`, since only `-g` may
  un-ignore.

  It synthesizes its own corpus (go, py, rust, ts, tsx, plus a gitignored file)
  instead of reading whatever tree it runs in. gist's own checkout is pure Zig,
  so the interesting cases would have matched nothing and passed as vacuously
  equal; the non-vacuity floors now have something to stand on, and the run is
  the same run on every machine.
- `gist-bench` lives here now, and can be built again. The harness spent the split
  in the engine package, where it could not compile at all: its `session` mode
  spawns a real `gist serve` daemon on a thread and speaks the real socket frame
  grammar to it, and `gist` depends on `irregex` rather than the reverse, so the
  imports it needed pointed the wrong way down the dependency edge. Everything
  that drives it — `certificate/`, `dominance/`, `certify_session.sh`, the warm
  and scanner races — is already here, and now so is the binary.

  `bench.zig`, `certify.zig`, `flagbench.zig`, and `sessionprof.zig` moved into
  `bench/apparatus/harness/`. The three instruments they read did not: `probes`,
  `pmu`, and `stats` stay with the engine and arrive as Zig modules through the
  `irregex` dependency, because that package's own rungs and bounds read them too.
  One registry and one significance test across both repos is what keeps a class
  name meaning the same thing in a race here and a rung there.

  The warm race was the visible casualty and is the clearest proof it is fixed.
  `dominance/races/warm.sh` had been failing outright on a missing `zig build
  bench` step; it now completes and wins 20 of 20 queries against every tool in
  the field, at a 1012x geomean over ripgrep on the resident path.

  New and restored steps: `zig build lab` installs `gist-bench` and `warden`;
  `bench`, `verify`, `certify`, `flagbench`, `sessionprof`, and `warden` each run
  their lane. `session` is new as a step — the daemon lane was previously
  reachable only by argv, despite being the one number a long-lived client
  actually sees. `cli` is back for running the built binary straight out of the
  build graph. The monorepo's `gist` step is gone rather than ported: it existed
  to install the CLI without the lab, which is what a bare `zig build` already
  does here.
- `gist` is its own package: the product chassis (both binary faces, the
  resident daemon, the session C ABI + bindings, the editor plugin, generated
  man page + completions, and the dominance certificate) extracted from
  a private monorepo kernel package at ce430bbaab, over the `irregex` and
  `relate` libraries as sibling checkouts. CLI binaries build ReleaseFast by
  default via `-Dcli-optimize`.
- `install.ps1` is the Windows half of `zig build`. A Windows user could
  build the three binaries and had to place them, put them on PATH, and find the
  completions themselves — the one-shot setup existed only as a Makefile target
  shelling POSIX tools. The script installs all three executables, persists the
  prefix to the user PATH without duplicating an entry it already added, generates
  the PowerShell completion from the same flag table argv is parsed with and
  sources it from `$PROFILE`, links the editor plugin (symlink first, copy when
  Developer Mode is off), and indexes the tree it was run in. Two Windows
  specifics get handled rather than papered over: a running `gist.exe` cannot be
  overwritten, so a locked target is renamed aside and cleaned up on the next run,
  and the PATH edit uses the registry-backed user environment so it survives the
  session that made it. Re-running is a no-op, which the native CI lane asserts by
  running it twice and counting PATH entries and profile lines.
- `ruff check` ran here and `ruff format --check` did not, which is half a gate: the lint rules were enforced and the formatting they assume was not. Thirty-four files had drifted out. They are formatted now and the check runs in CI beside the lint, so the two stay in step.

  The reformat is mechanical. I parsed all 72 files before and after and the syntax trees are identical, so nothing here changed behavior.
- gist ships an **editor face**: a Vim and Neovim plugin (`editor/vim/`) that
  `zig build` links into `pack/*/start/` for whichever editors are
  already on the machine. Nothing is added to a vimrc, `:help gist` is minted at
  install time, and a checkout that moves updates the plugin with it.

  The usual ripgrep integration is one line — `set grepprg=rg\ --vimgrep` — and
  inherits four consequences the plugin does not. Searches run in a job and
  stream into the quickfix list as they arrive, so a large tree does not freeze
  the editor and `:GistStop` can cancel. Arguments are handed over as argv, so
  `:Gist foo|bar` and `:Gist 'a b'` reach the regex engine as typed instead of
  through the user's `'shell'`. Each output shape is parsed for what it is,
  which retires the catch-all `%f` in `'grepformat'` that turns a stray stderr
  line into a quickfix entry pointing at a file that never existed. And a miss
  keeps gist's coaching out of the list while turning the runnable part of it
  into a numbered offer, so `try -i` becomes `:GistRetry 1`.

  The three faces stay themselves: `:GistRank` is the definition-first view,
  `:GistSimilar` is `relate similar` on the current buffer, and `:GistBlast`
  puts a symbol's live blast radius in the quickfix list so `:cnext` walks a
  change's consequences the way it walks matches. A selection or motion that
  crosses line breaks is searched with `-U` as one string, which a
  line-at-a-time grep cannot express at all. Completion asks the installed
  binary — `--schema` for flags, `--type-list` for `-t` names — so `<Tab>` can
  never drift from the gist that is actually there.

  Two runtime facts the plugin settles rather than exposes. Neovim's default
  job stdin is an open pipe, and gist inherits ripgrep's rule that a readable
  non-tty stdin _is_ the corpus, so a pathless search would have waited forever
  on input no one was going to write; every runtime now hands the child a null
  device. And `'grepprg'` is claimed only while it still holds a value the
  editor chose for itself — Vim's built-in grep or the ripgrep line Neovim
  writes when rg is on `$PATH` — because a `'grepprg'` in a vimrc is a decision,
  not a gap to fill.

  `zig build test` (plus the editor suite under `editor/vim/`) runs the suite in both editors against a temp corpus with
  its own `$GIST_DIR`; both must pass, since the two runtimes disagree about
  jobs, quickfix, and completion often enough that one proves nothing about the
  other.

### Changed

- A certificate's recorded git_commit is now provenance only. The release and reproducibility gates no longer resolve it, compare it to HEAD, or require it at all: a mint rewrites the tracked bundle, so the tree is necessarily dirty by the time a certificate exists and every caller already ran the check disabled. Bundles are judged purely on their bytes, so a mint from a dirty tree or an exported tarball verifies like any other.
- Adopted the substrate's shortened caller-facing spelling. The engine library's C
  ABI prefix is `irgx_` rather than `irregex_`, its installed header is `irgx.h`,
  its Python package imports as `irgx`, and its Rust lib is `irgx`. Every seam
  this repository reaches through it moved with it: the cgo preamble and cursor in
  the Go binding, the `extern "C"` block and `use` paths in the Rust binding, the
  cffi cursor in the Python binding, `include/gist.h`, and the FFI prose in
  `src/`. The project, the repository, the PyPI and crates.io identities, and the
  `@import("irregex")` Zig alias are all unchanged - what shortened is the
  identifier a caller types, not what the thing is called. gist's own `gist_*`
  symbols were never in scope.
- Closing the roofline Layer C gap traced the corpus scan's 35%-of-DRAM ceiling to document fragmentation, not the kernel: the default fused parallel loader leaves ~20k file bodies scattered across per-worker arenas and then path-sorts them, so `for (docs) |d| contains(d, …)` jumps to an unrelated address at every one of them and the hardware prefetcher restarts cold — the certificate's own ladder showed a contiguous 512 MiB buffer streaming at 52.8 GB/s while the same bytes as scattered corpus documents reached only 28.7. `corpus.load` now runs one final `compact` pass that relocates every body into a single contiguous, scan-order blob (paths copied alongside so the scattered source arenas and worker shards free — steady-state retention is one tight blob), letting the prefetcher, which streams linearly and never stops at a slice boundary, warm the next document's head while the current tail is still in flight. Each slice stays scanned within its own bounds, so no separator is needed and no cross-document match can appear; content, paths, iteration order, and doc ids are byte-identical, so `loadpar`'s membership parity test doubles as the compaction proof. `GIST_NO_COMPACT` keeps the scattered layout as an A/B toggle and parity escape hatch (mirroring `GIST_NO_PARALLEL_LOAD`), and the pass is fail-open — an allocation failure leaves the corpus in its original layout. Roofline A/B on M4 (same binary, compaction on vs off, DRAM ceiling ~80 GB/s both): pure-streaming full-scan 28 → 61 GB/s (36% → 76% of the ceiling, ~2.15×); end-to-end full-pipeline `})` p50 1.29 ms → 0.75 ms (~1.7×) with far tighter tails. Byte-parity proven by `zig build test` and the rg equality oracle (`bench/gates/equality.sh`: 140 literals + 70 regexes, 0 FN / 0 FP over the compacted corpus).
- Lifting the `relate patterns` parity gate's two scopes into knobs left it half configurable, because seven of its cases still carried hardcoded needles and two of those were tool names from the private monorepo. So a tree could declare both roots correctly and still not run the gate; pointed at the sibling `irregex` checkout with stock knobs, `build_graph` found nothing at all and the run went red on a *pattern* fact while the scope facts were fine. The slate is declared now too - `GIST_PARITY_SLATE`, rows of `<label> <pattern> [<scope>]` in the same shape every `PROBES` array under `bench/` already uses, either naming one of the two slates in the file or supplying its own. What each case is *for* moved with it, because the spread is the coverage argument and not decoration: a literal the pruned tree dominates (the one that was silently reporting 145 files of 616), a second resident of that tree in a different shape so the first isn't one token's luck, ordinary first-party literals outside it to catch a fix that over-corrects the other way, a 3-character pattern that is exactly one trigram, and one case scoped to each side of the skip decision. A replacement slate that drops a role stops proving what the gate's name claims, so the roles are written down at the knob.

  The bigger problem was that this gate could not go green anywhere except pointed at a tree nobody outside the company can clone. Fail-closed is honest, but a permanently-red gate is not a signal. It needs exactly one thing a package cannot manufacture for itself: a directory whose basename `haystack.isSkipDir` prunes out of the corpus loader while the rg-parity walk still enters it - committed, not gitignored, not named in the charter `skip`. `bench/apparatus/corpora/torture.py` already generates a tree deterministically with no network, so it grows a `vendor/` (16 vendored C lanes plus 6 Go files, nothing ignoring them) and a `src/` that calls into it. I checked the asymmetry is real rather than assuming it: the corpus loader indexes 3037 files there and the walk sees 3061, and adding three more files under `vendor/` moves the walk and leaves `amended 0 docs` behind. `node_modules` would have pruned identically and proved nothing, since it is gitignored nearly everywhere and then both sides drop it together. The gate now runs green on that corpus - 32 files for the pruned literal with 24 vendored, 25/17 for the underscored one, 9 and 10 for the first-party pair with zero under `vendor/`, 24 and 9 for the two scoped cases - and it still fails loudly on everything it should: the monorepo slate against that corpus reports six vacuous cases, a slate that never reaches the pruned tree trips the non-vacuity check, an empty slate is refused, and a malformed row is a FAIL rather than a skip. The 168-case differential sweep still passes on the extended fixture, both engines.

  Two smaller things. `pruned_hits` ended `sed | grep -F -c`, and `grep -c` prints its count and then exits 1 when that count is zero; under `pipefail` that was the function's status, so it returned rc=1 on the perfectly legitimate answer "no hits under the pruned tree". Harmless today only because the script has no `set -e` - adding one later would have turned every such case into a run-killer, which is a hard thing to notice because it fires exactly when the corpus is wrong. The status is discarded deliberately now and the count is untouched. And `fetch.sh` only checked that a torture corpus *existed*, which made a tree generated before these subtrees indistinguishable from a current one; the ready-marker carries a build id now, so a stale corpus regenerates instead of claiming to be ready and then failing the gate it was supposed to satisfy.

  The header sentence about a package measuring itself said the two root-scoped cases resolve to nothing. That was already understating it and is more wrong now that the patterns are declared: with no pruned subtree *and* a slate describing another tree, most cases come up empty and the non-vacuity check fails as well, each on its own line. It says that. The gate also prints whether the corpus actually carries an index, because the headline claim is "armed AND stripped" and against an unindexed tree both legs are stripped - it never builds one itself, since it must not write into a tree it was merely handed, but a half-vacuous run should not read like a full one.
- Restructured the crate into five layers — floor (`portal` · `assay` · `fault` · wire-floor `corpus/index/frame/`), `kernel/` (ten pure-compute tiers with a dedicated **math floor** and a first-class **regex package** sealed through `regex.zig`), `corpus/` (scope · read · tree · fresh · index), `exec/` (cold · retrieval · session, promoted out of `surface/`), and `surface/` (cli · api · ffi · faces). The warm daemon moved into `exec/session/daemon/`; gist lifecycle verbs consolidated flat under `face/gist/verbs/`; FM-index math lives in `kernel/codex/` with the persisted shelf under `corpus/index/shelf/`. Import topology is the ward contract (`contract/irregex.ward`); this is the prose half.
- The FFI transport, the contract mirror and the parity gates over both now live
  here rather than in the substrate, across all three bindings.

  Python gains `gist._native` and `gist._daemon`, moved from `irgx.runtime`, and
  they carry the `gist_*` cdef with them; `irgx.runtime.loader` grew a face
  registry so a product registers its declarations, its library stem and its ABI
  expectation, and the substrate composes one cffi type universe from what
  registered. `gist._contract` holds the published `dist` / `import` names and the
  tool-boundary aliases and routing keys, which `irgx.contract.abi` used to carry.
  Rust gains `gist::contract` with the same four constants. Both are gated here
  against this repository's own `contract/surface.toml` and `include/gist.h`.

  Two tests arrived with their subjects. `tests/test_span_parity.py` holds
  `gist --json` and the engine's own iterator to the same submatch spans, the claim
  `irgx.h` names this tool the authority for; it is a statement about two tiers and
  the far one is this repository's binary. `exact/ladder_test.go` drives the shared
  cold tier through `rank` and asserts an answer can say how much work it did and
  which tier did it.

  None of it was unused where it was. It moved because a substrate whose tests need
  its consumers checked out is a substrate its consumers cannot be released
  without, and because a mirror should be checked against the header that owns it.
- The Go and Python bindings stopped carrying the private monorepo's names. The Go module declared itself by its path inside that monorepo — a path that resolves for exactly one checkout on earth and cannot be `go get`-ed by anyone else — and its root package was `irregex`, which forced every importer to spell an explicit `irregex "…/bindings/go"` alias because the trailing path element is `go`. It is now `github.com/The-Billy-Company/gist/bindings/go` with root package `gist`, so a plain import binds the right identifier and the aliases are gone. The Python side published as distribution `billy-irregex` importing as `irregex`, which was worse than untidy: the kernel repo holds a separate package that genuinely owns the `irregex` import name, and two installed distributions cannot both provide one top-level module. It is now distribution `gist-search`, import `gist`.

  Neither name was invented for this change — the Rust crate has been `gist` all along and `contract/search_api.toml` already declared `package_import = "gist"`, so what actually happened is that two of the three faces drifted off a name the contract had been asserting the whole time, behind a parity test that was silently skipping. Four meanings of the token `irregex` were deliberately left alone, because only one of them was ever this package: the engine and the prose about it, the native artifacts (`libirregex.*` and the substrate header and C symbols it exports) whose filenames the FFI loader opens by name, the contract's own `[irregex.*]` sections, and the `irregex` binary itself.
- The Python binding answers every analytic verb in-process through the analytic row plane, with one schema-driven decoder in place of seventeen hand-written NDJSON readers, and reshapes into the six packages the Rust and Go bindings share.

  **Seventeen parsers were one parser written seventeen times.** Every kinship, retrieval, and composed verb reached the engine by spawning `relate`/`irregex`, then re-parsing `--json` with a per-verb reader that knew its own key names — `shell.as_float(row, "gain", 0.0)` sixty-odd times over — and the ranked view was recovered by regex-scraping human stdout, the only verb with no `--json` at all. A key that got renamed in Zig produced a silently zero field in Python. There is now one decoder (`runtime/decode.py`) that walks `contract/search_api.toml`'s `[row_schemas]` positionally, so a field is located by its declared slot rather than by a string that has to survive a transport. It resolves enum ordinals through the generated table, recurses into nested row fields, and emits frozen slotted dataclasses — bound to the published row types where those predate the plane, generated from the schema where they do not. A dataclass that drifts from its schema is an `ImportError` at import, not a mis-decoded field two layers down.

  **Absence stopped looking like zero.** `distance = 0.0` is the _identical_ verdict, so a row whose distance was never measured could not keep decoding as `0.0` — and on the subprocess tier, where the wire simply omits the key, it did. The presence mask is now honored on both tiers (reconstructed from which keys an object carries on the cold rung), an absent required field is a loud `RowDecodeError` rather than a guess, and an enum ordinal this binding's table does not name surfaces as `Unknown` — which refuses every `--min-grade` floor instead of being rounded to the nearest label it happens to know. A collection is the one exception, because JSON cannot say "unmeasured list": `pack` prints no `patterns` when nothing narrowed the pick, and empty is the true reading.

  **The transport is a ladder, and it is invisible.** `gist_run` is the preferred rung, the CLI is the fallback, and a tier that cannot express a request — a scope the handle does not cover, a CLI-only knob the params struct has no room for, a library built before the plane existed — declines. `IRGX_STALE` is never raised; the next rung answers, identically, and only `Stats.source` says who did. The plane is _probed_, not assumed, so a stale `libirgx` costs nothing but speed. The one thing that cannot degrade is agreement about what a row _is_: the library's `irgx_schema_digest()` is checked against the generated table at load, and a mismatch fails loudly and names the drifted schemas through `irgx_schema_get`, because decoding against the wrong table produces values of the right type read out of the wrong field.

  **Rows batch, and the arena stays behind.** `Rows` iterates lazily by default, `batches(n)` maps to one `irgx_rows_next_batch` per chunk, and `drain()` takes everything. Native rows borrow the cursor arena and expire at the next pull, so records are materialized before they are yielded and `Stats` is snapshotted at close — a record read after the cursor is gone is still a record. `foreign` and `omitted` ride that snapshot rather than being read off stderr by eye, so a caller can finally distinguish "your text is not in this corpus" from "no results", and `pack`'s coverage comes from the picks themselves instead of a parsed summary line.

  **Nineteen flat modules became six packages.** `contract/` (mirrored constants, calibration, the generated schema table) · `runtime/` (transports, the ladder, the decoder) · `exact/` (request, cursor, aggregation, the ranked view) · `relate/` (kinship and retrieval) · `compose/` (the composed verbs) · `index/` (artifact lifecycle) — the shape the Rust and Go bindings mirror, each package documented where it lives. `irregex/__init__.py` is unchanged as the public API.
- The Python binding declared `requires-python = ">=3.14,<3.15"`, which was the monorepo's pinned interpreter wearing the costume of a library requirement. It is now `>=3.12`, the floor the code actually has (PEP 695 syntax in `exact/aggregate.py`, and the `irregex` substrate's own floor), with no upper bound.

  Both halves were wrong in a way worth naming. The lower bound locked out every 3.12 and 3.13 user for no reason the source supports — the binding imports and runs fine on 3.12, which is how the real floor was found. The upper bound was worse, because it fails in the future: `<3.15` turns the day CPython 3.15 ships into the day this package stops resolving, for a cap nothing ever asked for. An application may pin one interpreter; a published library has no business refusing the next one.
- The Python distribution is `gist-search`; the import is still `gist`. `gist` on
  PyPI belongs to an unrelated author, so the name was never available to publish
  under - and, worse, a plain `pip install gist` fetches that stranger's package
  into a tree that then imports `gist` and gets whatever it contains. Splitting
  the two names closes that: `pip install gist-search`, `import gist`, which is
  the same shape bs4, PIL, and cv2 already ship. Only `[project].name` moved; the
  package directory, the wheel's `packages` entry, and every `import gist` in the
  tree are untouched, so nothing a caller writes changes. The release workflow was
  already publishing under `gist-search`, and `contract/surface.toml` now declares
  the split it was silently contradicting.
- The README stops re-deriving the engine and says what powers it. Engine lineage,
  the trigram/crest construction, the rank fusion, and the genus classifier now
  link into `irregex` where they live, so this page is about the tool built on the
  engine: argv, the daemon, distribution, and the parity contract. Also repairs
  two links that named files this tree does not have.
- The README takes the house shape the sibling packages already use. Both tables
  became lists, the headings became Title Case labels rather than arguments with
  glosses, long paragraphs split to one idea each, and the page gained a contents
  list, a section routing bugs and vulnerabilities, and a section telling a reader
  in the wrong repository where to go instead. Every claim, number, and flag
  survives the move, and the prose now speaks for the company rather than one
  author.
- The `relate patterns` corpus parity gate stopped naming the private monorepo `gist` was extracted from. Everywhere else that tree got quoted it was quoted in prose, so sanitizing the text was the whole fix; here the strings were live functional inputs — `scripts/vendor` was a scoped case's root *and* the needle of the `grep -c` that decides whether a run proved anything at all, and a second nested directory was the other scoping root — so substituting the text would have left an executable gate measuring directories that do not exist, cheerfully reporting five cases ok and two vacuous. Excluding the one file from the rewrite would just have shipped the paths instead.

  The gate is told those two paths now rather than assuming them: `GIST_PARITY_PRUNED_ROOT` (default `vendor`) and `GIST_PARITY_SCOPE_ROOT` (default `src`), overridable the way `GIST_CORPUS_ROOT` already was. `vendor` is the honest default because the property the gate needs is not "a vendored tree" but "a directory `haystack.isSkipDir` prunes out of the corpus loader that the rg-parity walk still enters" — that asymmetry is the only place the two populations can disagree, so it is the whole instrument. Of the generic basenames in the comptime skip set, `vendor` is the one most likely to hold committed third-party source a walk really sees: Go module vendoring, Composer, Bundler and `cargo vendor` all put code there and it is normally checked in. `node_modules` prunes identically and is the obvious alternative, and it is the wrong one — it is nearly always gitignored, which takes it out of the rg-parity walk too, and then both sides agree for the wrong reason and the gate goes green having proved nothing. Naming a directory in the tree's charter `skip` or in `GIST_SKIP` is the same trap and worse, since cold search honors those deliberately. All of that is written down at the knob, because it is the one thing someone configuring this can get wrong.

  One thing had to get stricter rather than just move. The vacuity count was `grep -c 'scripts/vendor'`, and a bare substring is close enough while the literal is two components; it stops being close enough once the value can be a single generic word, because `vendor.zig` and `bench/myvendor/x` would then count as hits under a pruned tree and satisfy the check without one. Making the check configurable would have quietly turned the gate's entire point into something that passes vacuously, so each path now gets a leading `/` before a single fixed-string match and what gets tested is a whole path component. On the tree the old literal described, both spellings count 470 of 625 — byte-identical; against a corpus built to have a `myvendor/` and a `vendor.go` and no real `vendor/`, the gate still fails as vacuous, which is the point. The failure message picked up the corpus property that is missing and the invocation that supplies it, and a package measuring itself still fails as vacuous by design, because it has no pruned subtree to measure.
- The `relate` CLI left this package.

  Its face (`src/surface/face/relate/`) and the four CLI modules only that
  face needed (`flags` · `grade` · `manifest` · `reprise`) moved into the
  `relate` package, which can now ship its own binary. The FM-index shelf
  had already broken the cycle that forced the face to live here; with the
  face gone, `gist` no longer depends on `relate` at all. What stays is the
  `gist` binary, the resident daemon, the answer keep's transport, the
  session C ABI, and the `--generate` primer. `relate` imports this chassis
  for the daemon the keep dials.
- The `relate` and `irregex` faces gained one kinship vocabulary, a calibration that tells a finding from background, and a single verb table that four renderings derive from.

  **A distance was not an answer.** `relate similar fresh.zig` returned five neighbors at 0.77–0.80 — correctly reporting "no real twins", but a ranking verb always returns rows, so the output read exactly like a hit and nothing said the whole answer sat past the 0.50 line where kinship stops meaning "related" and starts meaning "both files are Zig". The calibration existed only in prose, which the binary's caller does not have. It now lives in the engine (`surface/cli/grade.zig`): distances band `identical` ≤ 0.05 · `strong` ≤ 0.25 · `moderate` ≤ 0.50 · `weak` ≤ 0.75 · `none` above, gaps invert from the 0.15 `--min-echo` floor, the band rides every `--json` row, `--min-grade G` withholds anything weaker (empty beats noise), and an answer made entirely of background explains itself on stderr in gist's own hint grammar — naming the band and the channel that would have found something. A trimmed but genuine answer accounts for what it withheld without recanting the finding, and `GIST_HINTS=0` mutes the channel for byte-counting captures. gist's no-match hints and relate's verdicts now speak one grammar (`surface/cli/guide.zig`) rather than two hand-kept copies of the `tool: try …` shape.

  **One channel vocabulary.** `--lens` used to name two mutually incompatible enums — `similar --lens echo` and `concepts --lens fused` both failed for no principled reason. There is now a single `Channel`, named for what each channel _finds_ rather than the metric behind it: `copies` (LZJD over raw bytes), `twins` (the bytes−structure gap — the `echoes` signal), `shapes` (normalized-structure silhouette), `any` (the closer of either), spelled `--as` with the metric names kept as `--lens` aliases so nobody who learned the old spelling is stranded. Polarity is explicit rather than remembered (`copies`/`shapes`/`any` score a distance, `twins` scores a gap), and each channel's definition in terms of the two metrics exists in exactly one function, where before every verb re-derived the `min`/subtraction inline.

  **An empty answer now says so in `$?`.** The kinship verbs exited 0 whether they found kin or not, so `relate similar X && …` was a lie a shell could not detect — and the contract had declared exit 1 for "ran cleanly, found nothing" all along. Emitting no row now exits 1 across `similar`/`dups`/`clusters`/`echoes`, the same code `gist` returns for a pattern that matches no line, whether the corpus held no kin or `--min-grade` withheld every candidate. The trace diagnostic still prints first: how long a query took is a fact about the run, not about whether it found anything. `clusters` also gained the verdict and `--min-grade` the other three had, graded by a family's _loosest_ verified edge so the grade describes the whole family rather than its tightest pair.

  **The verb surface is declared once.** `relate`'s surface was written down five times — the module doc comment, the `usage()` text, the `--schema` JSON, the `dispatch` tuple, and the unknown-verb line — with nothing tying them together, so they drifted: the shipped manifest still advertised `similar --lens bytes|structure|fused` after the flag changed, and both faces claimed version 0.1.0 against an engine at 0.2.0. Each face now declares a `Face` in its own `repertoire.zig` — every verb row carrying its usage form, its human blurb, its machine summary, its typed flags, and the handler that runs it — and `surface/cli/manifest.zig` renders the help, the JSON manifest (including the envelope both faces were copying verbatim), the dispatch, and the verb list from that one table. A verb cannot be listed without being runnable or runnable without being listed, and the two hand-written `schema.zig` documents are gone. Fittingly, `relate echoes` is what found those two manifests in the first place: structure distance 0.038 while 0.66 apart in bytes — the same document written twice in different words, which is exactly the DRY signal byte kinship structurally cannot see.

  **Then it found the fix's own echo.** Collapsing the four hand-kept lists left both faces' `main` byte-identical apart from the name it passed itself, and `echoes` scored the pair at structure distance 0.000 — the strongest echo in the corpus, in code minutes old. Every irregex-family binary is the same program with a different verb table, so the process moved into the table too: `manifest.drive` owns the diagnostic install, argv, the three introspection conventions, the output budget, the dispatch, and the exit contract, and a `main.zig` is now a doc comment and a single call naming its repertoire (189 → 29 lines for relate, 147 → 33 for irregex). An agent that learns `--help`/`--version`/`--schema` on one face has learned all of them, because there is one implementation left to learn.
- The artifact home moved from `.local/gist-verify/` to `.gist/`. The old path was two inherited conventions stacked on each other: `.local` was the private monorepo's machine-local scratch drawer, and `gist-verify` was the name of one directory inside it that happened to be where the index landed. Neither means anything in a repo you clone yourself, and together they read like a temp dir you could delete. `.gist` says what it is the way `.git`, `.ruff_cache`, and `.mypy_cache` do, and it reads correctly next to the `GIST_DIR` override that was always the real knob.

  This orphans whatever index you already have — nothing migrates it, and a stale `.local/gist-verify/` just sits there until you delete it. Rebuilding is `gist index`, about three seconds on a large tree, and every verb answers correctly from a live scan in the meantime. If you'd rather not move, `GIST_DIR=.local/gist-verify` pins the old location and nothing else changes.
- The corpus parity gate now refuses a tree with no index instead of reporting a half-vacuous run as a pass. Its headline claim is that `relate patterns` answers over the same file set as N sequential `gist -l` runs *with the index armed and with it stripped*, and those are two different legs: the armed leg proves the index accelerates the read without deciding the population, the stripped leg proves the walk alone decides it. Against a corpus carrying no index both legs run stripped, so the armed half went unproven while the gate still printed `PROVEN` and exited 0. The banner had quietly weakened itself to "armed or stripped" to stay technically true, which is the tell: a gate whose proof text disagrees with its own headline is reporting something weaker than it claims. It now fails closed with the remedy (`gist index` inside the corpus) and the reason, and the banner says "armed AND stripped" because that is now guaranteed. It still never BUILDS an index; writing into a tree it was merely handed is a different and worse failure than declining to judge one. Proven red-then-green against a freshly generated unindexed torture tree (exit 1, no cases run) and the indexed one (exit 0, 7/7 with 4 cases resolving under the pruned `vendor/` subtree), with the three pre-existing refusals unchanged: a wrong slate still yields 6 vacuous failures, an empty slate is still refused before anything runs, and a malformed row is still a loud failure rather than a skip.
- The differential-fuzz residual floor drops from 13 divergences to 9, and one
  whole class disappears from it.

  Seed 20260727 at 6000 iterations, against ripgrep 15.2.0. `line-count+exit` goes
  to zero (the `--files-without-match` exit code), and `line-count` falls 5 -> 2
  (the `--crlf` dot eating a carriage return, the `-w` arm that was never retried,
  and the binary file this mode listed twice over). `line-content` (4),
  `timeout-rg` (2), and `trailing-bytes` (1) are unchanged, and each is a case I
  have not fixed rather than a number I have moved: the two timeouts are the oracle
  giving up on a pathological pattern over the `giant` corpus and were never
  ratcheted, and the rest are reported in the fix's own fragments in irregex.

  Every fix is in irregex; this file only moves the floor those fixes lowered, and
  it was republished by the command the contract in the baseline names rather than
  hand-edited.
- The distribution is called `gist-search` because the bare name was taken, which
  means the name does no discovery work at all - nobody types "gist" looking for a
  code searcher. Until now the metadata did not make up for it. The Python package
  shipped a one-line summary, no keywords, no classifiers, no README, and no
  links, so its PyPI page was going to be a blank card with "Importable Python API
  for gist exact search." on it.

  It now carries the words the job actually gets searched under: code search,
  grep, ripgrep, find in files, trigram index. The summary leads with what it does
  rather than with the word "importable", the README opens on indexed code search
  with ripgrep semantics instead of on package boundaries, and `rank` gets named
  early because it is the one verb with no grep equivalent. The crate got the same
  treatment inside its five-keyword budget, plus `readme`, `homepage`,
  `repository`, and `documentation`.

  The rest of the Python README is unchanged apart from an install section and
  links to the three sibling packages.
- The docs, examples, and test fixtures stopped naming the private monorepo `gist` was extracted from. Every `gist WalletService services/backend/api` was demonstrating path-scoped search over a tree nobody outside that company can look at, so the shape of the example survived and the names didn't: `SessionStore` exercises the same ranking signals as a CamelCase type, and `src/server/api` scopes a path the same way. Same for the fixture paths in the Go, Rust, and Python binding examples, the `:Gist` example in the Vim help, the daemon protocol and serve tests, and the `gist SessionStore` line the man page carries — that last one is baked in by `generate.zig`, so the generator is what changed and the page mints correct the next time you build it.

  `CHANGELOG.md` lost its `ADR-NNN` citations too. An architecture-decision-record number is a pointer into a document set that did not come with the code, so each one either got replaced by the substance of what was decided or dropped as a parenthetical that was carrying nothing. Prose that described measurements taken against that monorepo still says so, just as "a large polyglot monorepo" rather than by name; the numbers are real and I'm not going to restate them as if they came from somewhere else. Two things were deliberately left alone: the copyright line, which names the actual holder, and everything under `bench/`, where `WalletService` is not an example but a high-match race pattern chosen against a specific corpus — renaming it there would quietly turn every measurement built on it into a zero-match run.

  The hand-cloned upstream checkout the differential tests read moved out of a hidden dotfile bucket into `upstream/` on the same reasoning, and both it and `.gist/` are now gitignored by name.
- The engine this product links is spelled `irgx` on the linker line too. You already included `irgx.h` and called `irgx_rows_next`, but the `-l` flag and the status constant you compared `gist_search_cursor` against were both still the long spelling - one API that could not decide what it was called. Both caught up.

  A C host now links `-lgist -lirgx`, and a staged prefix holds `libgist` + `libirgx` in one lib directory - which is also what `libgist`'s loader-relative rpath resolves, so the packaging gate that opens the product from an unrelated directory is asserting the new filename. The substrate vocabulary `gist.h` speaks by including the engine's header is `IRGX_*`: `IRGX_OK`, `IRGX_MATCH`, `IRGX_STALE`, `IRGX_INVALID`, `IRGX_OOM`. The Go cgo tier is `-tags irgx_ffi`, closing a split where `relate` and `blast` had moved and this repo had not, so there was no single tag that built the in-process rung across all four checkouts. Rust's `native` feature links `dylib=irgx`, the Python binding pins `IRGX_LIB` at the `libirgx` sitting beside the `libgist` it is about to map, and the contract-override knobs are `IRGX_CONTRACT` / `IRGX_<NAME>_CONTRACT` - chased as strings rather than identifiers, because a missed status code is a compile error while a missed knob is silent.

  None of this touches what gist itself is called. `libgist`, `include/gist.h`, the `gist_*` symbols, the `GIST_*` environment namespace, and the `gist-search` distribution are unchanged; only the engine underneath answers to a shorter name.

  Rebuild clean. A renamed library file fails at *load* time rather than compile time, so a warm `zig-out` will happily hide a miss, and the engine header an older build installed under its long name is now a file nothing writes.
- The macOS watch set is now budgeted against the ceiling the kernel actually enforces, and an idle daemon gives the set back long before it gives up its session. Both fix the same oversight: one descriptor per watched vnode makes the file table a **commons**, and the old budget priced it as if this process were alone on the machine. `watchBudget` derived its cap from `RLIMIT_NOFILE`, which on Darwin is not the enforced limit — measured here, a soft limit of 1,048,575 against a `kern.maxfilesperproc` of 245,760 over-states the room by 4.3×, and a stock macOS box ships 24,576, _under_ the ~26k watches this repo alone admits. The design already failed closed, but not PREDICTIVELY: it would accept a set it could not register and meet `EMFILE` partway through instead of declining up front. The budget now clamps by `kern.maxfilesperproc` and by a bounded share of the live system table (`kern.maxfiles / 8`, never more than the free headroom above a 4,096-entry reserve, priced against `kern.num_files` at arm time) — so the fifth concurrent daemon declines to arm rather than starving the `pipe(2)` of whatever starts next. On this machine that resolves to 61,440 watches, which the 26k set fits; on the stock box it resolves to 24,064 and the session stays unarmed (reconcile-always) from the start. Second, daemon accumulation: four to five `gist serve` processes across different trees held 27,057 descriptors at once, and the 10-minute idle TTL was the only thing that ever gave them back. Idle release is now **two-stage** (`daemon/serve/idle.zig`), ordered by what each resource costs the machine rather than the process: the watch set — the commons — is shed at 2 minutes of continuous idleness, while the resident corpus + index, which are only this process's own RAM, still live to the unchanged 10-minute TTL. Shedding cannot cost correctness by construction, because the watcher is a pure accelerator (macOS kqueue freshness barrier): a shed session withdraws the exactness promise, clears clean, and reconciles every query against the live filesystem, which is exactly the pre-ADR behavior. Re-arming is deferred rather than done in front of the client that woke the daemon — registration walks the tree and opens ~26k descriptors (~300 ms), so it waits for the returning burst to go quiet (2 s) and every query meanwhile answers on the ~50 ms baseline; the re-arm then forces one full pass and re-seeds the annals, so a `changed` consult never answers for the window nothing was covering. Measured on a live daemon over this repo: armed at 26,113 watch descriptors, **13** open files after the shed window with the daemon still warm, a query during that window still answered warm and still finding a file created _after_ the shed, and the set back to 26,114 six seconds later. Proven by `zig build test` — budget arithmetic including the clamp edges and the zero-watch (unarmed) floor, the idle policy as a pure two-input function with its overdue/clock-jump edges, `Seqlock` disarm/re-arm, and an end-to-end kqueue case that sheds a real watcher against a real tree, mutates files through the gap, and grades the re-armed answers against an independent on-disk oracle.
- The packaging gate now quotes the product library's own dependency table when it
  fails. A load-time verdict cannot distinguish "imports the shared engine" from
  "absorbed a private copy of it", which is the only thing that gate is asking, so
  a red run used to leave the reader to go re-derive it by hand.
- The resident daemon (`gist serve`) is now five peer modules behind an unchanged `run`/`socketPath` surface instead of one 822-line file: `crew.zig` (the connection table + bounded worker pool), `loop.zig` (the poll multiplexer, idle staging, and the annals seed), `route.zig` (poll-thread frame triage — what one readable client costs), `answer.zig` (a query's decode → session verb → response write, plus the per-query wall-clock budget), and `serve.zig` (lifecycle only: singleton lock, session, watcher, socket, pool, teardown order). Each file is now one level of abstraction, which is what the old `MONOLITHIC` deferral was buying time for — the marker and its registry row are retired. No behavior change: the same 176 unit tests pass, including all six end-to-end daemon lifecycle cases (worker-pool non-starvation under a pinned query, budget decline, the annals consult behind the flush barrier, and fd-transport byte-parity with chunk frames).
- The resident-session wire protocol is now a sealed `conduit/protocol/` module entered through `protocol.zig` instead of one 703-line file: `frame.zig` (the opcode spine, frame budgets, and typed fd transport), `query.zig` (the request codec with its flags byte and self-describing rank/context/pcre trailers), `result.zig` (the answer codec and zero-copy readers), `keep.zig` (the v8 recall/retain answer keep), and `annals.zig` (the watcher consult). The opcode enum is a leaf every chapter imports downward, so an opcode byte is still minted in exactly one place, and encode/decode for a given frame stay in one chapter so a trailer's writer and reader cannot drift. The public surface is unchanged — the entry file re-exports every name callers already bind to, and the ward seal makes the chapters internals — while the `MONOLITHIC` marker and its registry row are retired. `encodeRecalled` now takes named `Vouched`/`Hit` types instead of an anonymous parameter struct only the callee could spell, which a caller assembling the value before the call could not construct.
- Thirty-seven READMEs carried a `doc_radar:` block - YAML frontmatter on most, an
  HTML comment on the rest - declaring path, count, and sentinel assertions for a
  freshness gate that lives in the monorepo this package was split out of. That
  gate was never ported here, so every one of those blocks was inert. On the
  Python binding's README it was also the first thing a PyPI reader would meet,
  where the renderer turns a YAML preamble into a horizontal rule followed by a
  heading made of raw YAML. They are gone, and the prose below each is untouched.

  One comment in `bench/conformance/gates/parity/patterns_corpus_parity.sh` cited
  the corpora README's sentinel as the only thing coupling that gate's torture
  slate to the generator that plants it. The sentinel never ran, so the comment
  now says plainly that nothing enforces the pair and a rename has to land in both
  files at once.
- This package no longer depends on `_buildkit`, a sibling that existed on one machine and had no remote. It borrowed one file from it — `brigade.zig`, the shard-aware test runner — which now lives in `irregex` and is reached through the dependency on `irregex` this build already declares. One fewer edge in the graph, and one fewer unpublished repository standing between a clone and a test run.

  Two doc comments pointed at a `_buildkit/build.zig` helper that is no longer reachable from any of these repositories; they now describe the fan-out this build actually performs.
- This repo now authors `contract/surface.toml` - the row schemas, ABI status
  vocabulary, transports, session semantics, analytic and composed planes, tool
  boundary, and published package names. All of it previously sat in the kernel's
  `search_api.toml`, describing surfaces the kernel does not own.

  The contracts we do not author stay with their authors: `analytic.toml` and
  `engine.toml` in `irregex`, `kinship.toml` in `relate`. Every binding resolves
  them from the author's checkout, and `tools/sync_contract.py` fails when a
  sibling is missing or its contract is absent - so a checkout of only this repo
  knows what it cannot gate, rather than silently gating nothing.

  That matters because **the parity gates now fail closed**. Every binding mirrors
  constants from all three contracts so an installed package needs no repo file,
  and a per-binding parity test is the only thing keeping five copies of the same
  numbers honest. Those tests used to skip when a contract was unreadable, which
  was defensible for a wheel and disastrous in a checkout: after the repo split
  the locators resolved to files that no longer existed, so the assertions stopped
  running and nobody noticed. An unreadable contract is an error now, and it names
  the file and the command that restores it.
- `--files-without-match` is no longer a declared boundary in the ripgrep-parity
  harness, because there is nothing left to declare.

  The entry said rg contradicted itself: over a tree holding a walked NUL-bearing
  file it exits 0 while printing no path, so gist's exit 1 was recorded as the
  coherent reading of a mode whose code means "a path was listed". That reading was
  wrong. rg's success predicate here is `match_count == 0` - "some file's search
  found no match" - and an abandoned binary search found none. gist now answers the
  same question (fixed in irregex), so the difference the boundary excused does not
  occur.

  That matters more than tidiness: `surface.py`'s table is imported by both the flag
  probe lane and the differential fuzzer, so as long as the entry stood, a
  regression back to exit 1 would have been scored `declared` in both and waved
  through. The `silent0` residual it was the only user of is gone with it.

  411/411 mined cases still pass in both the parallel and serial lanes.
- `contract/surface.toml` is down to what gist actually authors: `[package]`,
  `[transports]`, `[session]` and `[tool_boundary]`.

  The row schemas, enums, verb table, params families and producer map that used
  to sit here are substrate, not gist's. relate and blast return those same rows
  through the same cursor, so declaring them in gist's contract meant two
  libraries reading a third's file to learn their own wire shape. They are in
  `irregex/contract/analytic.toml` now, beside the generator that lowers them into
  every binding. `[compose]` and its verbs went to `blast/contract/compose.toml`,
  where the library that answers them lives.

  `tools/build_schema_tables.py` left with the tables. `tools/sync_contract.py`
  now verifies four contracts rather than three, and the Python and Rust parity
  gates resolve `analytic` from `irregex` the same way they already resolved
  `engine` and `kinship`. Nothing is vendored; each sibling declares its own and
  the mirrors cite them where they live.

  The C header's account of what a row means pointed at `contract/surface.toml`,
  which no longer declares it; it names `irregex/contract/analytic.toml` now, as
  do the binding READMEs.
- `contract/surface.toml` no longer declares `[status_codes]`,
  `[decline_reasons]` or `[fault_domains]`. They describe what
  `include/irgx.h` returns, so they moved to `irregex/contract/engine.toml`,
  which this repository already resolves as a sibling — the row schemas,
  transports and session semantics that are genuinely ours stay here.

  Nothing changed about what libgist returns, and no mirror moved: the Go, Python
  and Rust constants are unchanged and their parity tests still read the engine's
  contract the same way they read it for `[meta]` and `[request_options]`. The
  practical difference is upstream of us. A host that links only libirgx now
  has a contract for the codes it receives, and there is exactly one file to edit
  when a fault domain gains a member — where before this repo could have added one
  that the engine emitting it had never heard of.
- `gist --version`, the `--schema` manifest, and the generated man page now answer with **this package's** version rather than the engine's. They read `build.zig.zon` - `build.zig` lifts `.version` in as a build option and `src/root.zig` exposes it - so the number is written in one place and nothing restates it. Both packages happen to be at 1.0.0 today, so no output moves yet; what moves is that they are now free to diverge without the CLI reporting a number that belongs to something else. The engine is still there to ask: `gist rg --pcre2-version` for the vendored grammar, and the engine's own accessor for its semver.

  The two publishing manifests, `Cargo.toml` and `pyproject.toml`, are the only remaining copies, since neither can import anything. Both carry an `x-release-please-version` marker that `release-please-config.json` lists, so a merged release PR moves them with the manifest in one commit, and `tools/version_parity.py` fails if one lags or if a marked line was never declared to the bot. It runs in CI as the `version` job.
- `gist_abi_version` is the session ABI (still 2). It is no longer exported as
  `irgx_abi_version`, which `libirgx` owns for the engine plane (1). A
  host that version-gates both libraries reads two axes, not one overloaded
  integer.
- `gist_run` keeps only `rank`. Kinship, retrieval, and the multi-pattern sweep
  moved to `librelate` (`relate_run`); the composed verbs moved to `libblast`
  (`blast_run`). A host that wants kinship no longer links the search library
  to get it — each producer returns the same `irgx_rows *` walked by
  `libirgx`. Op numbers are unchanged, so a stored verb id still means the
  same thing ecosystem-wide.
- `libgist` is the search product's C ABI again. The artifact, header, and
  session symbols were still named for the engine library after the ecosystem
  split (`libirregex`, an engine-named header, and an `irregex`-prefixed
  `open` / `search` / `analytic_run` triad). They are now `libgist`,
  `include/gist.h`, and `gist_*`.
  Substrate status codes, the fault pull, and the `irgx_rows_*` cursor stay
  in `libirgx`; `gist_run` returns that cursor on purpose. The product
  stops shipping duplicate `ffi/{rows,schema.gen}.zig` and the `Rows` walker —
  those live in `@import("irregex").ffi`.
- macOS resident sessions now answer from a sound causal barrier instead of re-walking the tree for every query. The old FSEvents backend could only observe, never prove: fseventsd journals asynchronously with respect to the write syscall, so `flushSync` returned an unconditional doubt and every macOS query paid the full parallel walk — after two rounds of walk optimization (~160 ms → ~50 ms) that walk _was_ the remaining cost. Both candidate barriers were probed adversarially before any code was written: an FSEvents "fence file" is **unsound** (200 of 300 iterations at zero stream latency, once with 54 of 64 earlier writes still undelivered — monotonic event IDs order the journal, not delivery relative to a completed write) and its 0.05 s coalescing floor alone costs ~48 ms, slower than the walk it would replace; a kqueue `EVFILT_VNODE` barrier is sound and ~20× cheaper (**zero** unsound iterations across 355 adverse iterations at full repo scale, drain 1.9 ms). Two probe findings shaped the design rather than confirming it: directory-granular watching reports 0 of 2000 in-place content edits (a directory does not change when a file's bytes do), forcing a composite set of directories _and_ files; and case-insensitivity — expected to kill the design — does not apply, because kqueue keys events by a DESCRIPTOR this process opened with the walk's canonical spelling, so macOS can now arm exact on the very volumes where Linux's name-keyed inotify deliberately cannot. The watch set is selected by the walk's own `Ignore` (not the raw tree) and carries the hidden per-directory ignore SOURCES that decide admission, so a `.gitignore` edit re-derives both the rules and the coverage — otherwise a newly-admitted file would be unwatched while the session still reported clean; paying one descriptor per file makes that difference 193k descriptors versus 26k here (40% of the system-wide file table for a single daemon, enough to fail a second daemon's `pipe(2)`). Everything degrades to the walk, never to stale bytes: a descriptor budget that will not fit leaves the session unarmed, a post-arm registration failure poisons the fast path, and `EV_ERROR` raises doubt. Measured A/B on this repo (20.3k-file corpus, same binary, private index + socket per arm, unarmed = the pre-ADR behavior reproduced by starving the descriptor ceiling; wall = full client spawn + UDS round trip; each daemon grading its own reconciles): quiescent warm query 59.5 ms → **5.0 ms**, one-file-changed 62.7 ms → **4.9 ms**, and 51 full reconciles over 50 queries → **0** (26 scoped, the rest clean). A change to a served root still takes the walk by design. `coreservices.zig` — the dlopen'd CoreServices/CoreFoundation binding that existed only to drive the old stream — is deleted. Proven by `zig build test`, including an end-to-end kqueue suite that boots the real watcher against a real tree and grades every answer with an independent on-disk oracle: in-place edits, post-arm file and directory births re-edited in place, cross-directory moves, case-only renames, deletions, the root-entry full-walk fallback, and an ignore-rule edit that must re-cover the newly-admitted file (that last case fails, 3 matches where 2 are live, if the refresh is removed).

### Fixed

- A `gist` verb could die of a stack smash purely because the artifact home's path was a certain length.

  The session's rendezvous path is `<artifact home>/gistd.sock`, and anything that probes for a resident daemon hands that path to `std.Io.net.UnixAddress`. std publishes one POSIX-wide `max_len` of 108 bytes, but Darwin's `sun_path` holds **104**, and std's POSIX copy takes the length unclamped — only its Windows arm applies a `@min`. So an address of 105–108 bytes passed `init` and was then memcpy'd up to four bytes past a 104-byte `sun_path` sitting on std's own stack, into whatever neighbored the connect helper's frame.

  The window is four bytes wide and exact: 104 and below fits, 109 and above `init` refuses. That is why this read as flakiness for months. Whether a run landed in it depended only on how long the artifact home happened to be, so it appeared under a test runner that names temp directories after the test — and never from a shell, where `mktemp` paths are short.

  It also never crashed anywhere near the damage. The report we finally chased was a segfault inside an unrelated file read three calls later, dereferencing a pointer whose low bytes were `0x6b636f73` — `"sock"`, the tail of the very path that overflowed.

  `conduit/rendezvous.zig` now owns the platform's real capacity, read off `sockaddr.un`'s own `path` field rather than assumed, and every site that turns a path into a socket address goes through it. An address the kernel cannot hold is refused, which the callers already handle as "no daemon is listening there" — true by construction, since nothing can be bound to a path the kernel will not accept.

  Two gates, both mutation-proven. The unit test walks every length std would have admitted past the platform bound and pins the refusal (on Linux the two bounds coincide and that span is empty, which is the correct statement there rather than a weaker test). `bindings/python/tests/test_rendezvous.py` runs the real binary across rendezvous lengths 98–115: with the guard removed and the binary rebuilt, exactly 105, 106, 107 and 108 fail and nothing else. It builds its temp home under the shortest writable temp root on purpose — under macOS's default `TMPDIR` there is no room left to construct a 105-byte address, and the suite would have skipped the entire window while reporting itself green.

  This is a bug in the Zig standard library that we are guarding around; the upstream fix is for `UnixAddress.max_len` to be per-platform, or for `addressUnixToPosix` to clamp on POSIX as it already does on Windows.
- A certificate mint no longer loses half an hour of valid measurement when a coworker deletes a file. The corpus manifest hashes every path in the index snapshot, and a file that vanished between the snapshot and the hash raised an uncaught FileNotFoundError after the whole macroscopic race had already completed. On a clean tree that strictness is the point — a manifest row promises the exact bytes that produced the timings — so strict mode still aborts on a vanished or mid-hash-mutated file. Under CERT_ALLOW_DIRTY=1, which already declares a churning coworking tree, such a file is dropped from the manifest rather than hashed loosely and counted in machine.json as corpus_unstable_files, so the certificate states exactly which bytes it can and cannot vouch for. Still fail-closed: churn past 1% of the corpus aborts the mint outright.
- A native failure through the Rust in-process plane read `analytic run: native
  status -3` when the engine had already said which file and which byte.

  `plane::fault` exists to enrich that: pull the thread's last fault, render the
  name, the path and the offset into the message. It pulled it, then tested the
  return for `IRGX_OK` - which is the pull's "this thread has nothing to
  confess". `IRGX_MATCH` is "a fault was written". So the test was inverted:
  every real incident took the bail-out branch and every message fell back to the
  bare status number, while the one case that got through was the empty slot,
  whose `name` is `""`.

  Nothing caught it because the rendering was a closure inside the only function
  that called it, unreachable without a loaded engine. It is `incident()` now,
  taking the pull as an argument, with a fake one in the tests - and the four rows
  that pin it fail on the inverted spelling.

  While there: the offset is only appended after a path when `at_space` is
  `AT_FILE`, so a pattern offset can no longer be printed as a position inside a
  filename.
- A published certificate names the incumbents it beat, so `tool-versions.txt` has to say _which_ csearch and _which_ zoekt — and it did not. Every row was a bare `sha256:` of whatever `command -v` returned, which is unreadable, is not comparable to anything upstream, and differs per platform for one release. Worse, it can name the wrong file entirely: under a version manager the resolved path is the multiplexer, not the rival (a `mise` shim is a symlink to `mise`), so shimmed tools all hash to one launcher while still reading as exact pins. Measured on this machine, `csearch`, `zoekt`, and `zig` recorded the single digest `20d3bc06…`, which is `mise` — three tools, one meaningless pin, and `guard/artifacts.py` could not tell, because a digest is a digest.

  Identity is now the version the tool reports of itself **and** the digest of the executable that resolved, because either alone degrades: a digest cannot survive a shim, and a version cannot separate the two local csearch builds here that are both module `v1.2.0` under different Go toolchains. Resolution walks `PATH` for a candidate whose name survives symlink resolution — a multiplexer renames itself, a real install does not — so no version manager is special-cased. The guard now fail-closes when two tool ids share one digest, which is the only signal that separates a collapsed pin from a real one.

  csearch and zoekt carry no version flag at all, so their pin is the embedded Go module version read from build metadata rather than by running them. Asking a search tool for its version is actively unsafe: `csearch version` treats `version` as the _regexp_ and prints a matching corpus line, which scraped a bogus `26.3.0` into an identity before the probe order was fixed. The field now records `github.com/google/codesearch v1.2.0`, `github.com/sourcegraph/zoekt v0.0.0-20260622122048-f80c7e09ab9d`, ripgrep `15.2.0`, ugrep `7.8.2`, ag `2.2.0`, GNU grep `3.12`, git `2.55.0`. Two-component versions are accepted as the real shape they are — GNU grep ships `3.12`, and refusing it would be the guard demanding a form reality does not have. The eight non-shimmed digests are unchanged from the published bundle, so resolution moved nothing it should not have.
- A resident daemon can no longer answer for a build it isn't running: READY now names the daemon's executable image, a gist client on a different one runs cold, and the newer of the two retires the older.

  **A well-formed answer carrying bytes that no longer exist.** A freshness fix landed, the binary was rebuilt two minutes later, and `gist` kept printing a line from a file edited hours earlier — text the file on disk had not contained since. `gist index` "fixed" it, which pointed at the on-disk index; the index was sound. What was serving the stale line was a daemon started before the fix, answering a freshly-rebuilt client from the pre-fix engine. `protocol_version` did not catch it and could not: it proves two peers FRAME alike, and a correctness fix that changes what a warm answer IS moves no byte on the wire, so it earns no bump. Every behavior-only fix this engine will ever ship has that shape.

  **So READY says which build is answering** (`exec/session/conduit/image.zig`, protocol v9). The daemon stamps its executable at boot — before any later rebuild can replace the file underneath it — and reports that stamp for the rest of its life; the stamping instant and the reporting instant being hours apart is the whole point. A gist query or `gist index` consult meeting a different stamp declines to the certified cold path rather than trusting an engine it no longer shares.

  **The stamp is an mtime, so it carries an order, not just an identity** — and that is what makes retirement safe. Declining alone would have traded a wrong answer for a stranded warm tier: the daemon's idle TTL wants ten _continuous_ minutes of quiet, which a tree with ~10 coworker agents querying it never gets, so one `zig build` would have turned the warm path off for the rest of the day. The newer peer now asks the older to stop on its way out, and _only_ the newer: were mere difference enough, an old shell and a new one would take turns killing each other's daemons, where ordered the exchange converges after exactly one cold query. The protocol version is the outer order and is read straight off READY's byte zero rather than through `decodeReady` — a decoder speaks only for the layout it was compiled for, while every version has always put the version in the same place, which is what lets this release's own v8 daemons be retired rather than merely declined.

  **And the skew is now legible before it costs anything.** `gist status` grew a `resident` line — `none` / `ours` / `foreign` — answering the half of "am I ready to search fast" whose failure was previously silent, the same way `bound_here` answers it for artifacts built over another tree. The probe is read-only: status never spawns a daemon and never retires one, so running it twice cannot change what it reports; retiring a superseded daemon stays the query path's job, one cold answer later.

  **Two peers are deliberately exempt.** The answer keep never checks the stamp, because `relate` and `irregex` dial gist's socket by design and three binaries from one build are three different files — and it is sound there, since the daemon renders no kept answer and `cli/reprise.zig` already folds the caller's own build into the key. The Python and Rust bindings don't check it either (no comparable image; they report `unknown`, which abstains) — though both were pinned two versions behind and silently cold, and are now back on the shared contract with READY's new fixed 29-byte header.
- Every function in this package is annotated, public and private alike, and every consumer's type checker has been ignoring all of it. PEP 561 says annotations inside an installed package are invisible unless the package ships a `py.typed` marker, and this one never did. The work was done and then hidden: `mypy` run against code importing this package got `Any` for the whole API and reported nothing wrong.

  The marker is there now, and hatchling ships it because it sits inside the package directory. There is a test for it too, because the failure mode is silent in both directions - nothing here breaks when it goes missing, and nobody downstream is told.
- Every in-process parity test in the Python binding — 73 of them, the whole
  `test_ffi_parity` and `test_cursor` surface — was skipping with
  `libirgx/cffi unavailable`, and a suite that reports 119 passed / 73 skipped
  reads as green. Two causes, both artifacts of the repo split.

  `cffi` is deliberately not a runtime dependency: the in-process tier is an
  accelerator and fails open to the subprocess without it, which is what keeps the
  shipped wheel pure-Python. Inside the originating monorepo it arrived anyway,
  transitively, from the sibling cffi kernels; a standalone checkout has no such
  sibling, so the tier went
  dark everywhere at once. It is now a test-only dependency, which is where it
  always belonged — the runtime contract is unchanged.

  With the tier awake, 19 of those tests failed: the cursor drove
  `gist_engine_open` / `gist_cancel_*`, and the engine had moved down into
  libirgx as `irgx_engine_*`. Retargeted onto the substrate's spelling; the
  symbols resolve through libgist's own handle because libgist links libirgx by
  rpath, so the engine a cursor reads is the one the binding opened — no second
  implementation, which is the whole reason the engine moved.

  192 passed, nothing skipped.
- Every workflow checkout of a sibling package now carries `token: ${{ secrets.ECOSYSTEM_TOKEN || github.token }}`, matching the pattern `blast` already used. The default `GITHUB_TOKEN` is scoped to the repository running the job, so a checkout of a *private* sibling 404s on a runner no matter how correct the rest of the job is; four of this repo's jobs check out `irregex`, and `irregex` is private. The fallback is what makes this safe to land ahead of the secret: with no `ECOSYSTEM_TOKEN` configured the expression collapses to the default token and the behavior is exactly what it was, so a fork still fetches whatever is public and gets a legible 404 on whatever is not, rather than a mystery failure inside a build step. This is wiring, not a grant; the secret itself does not exist on any of the four repositories or at the organization level yet, so the private-sibling checkouts stay red until someone creates it or the sibling goes public.
- Persisted artifacts — and the resident daemon's socket — now record the tree
  they were built over, and every accelerator declines when that binding names a
  different one. A `GIST_DIR` aimed at a second checkout used to serve that
  tree's content-shard bytes as this tree's, hide a real hit behind a foreign
  freshness anchor, walk a phantom directory that exists only over there (the
  `No such file or directory` + `-uu` misdiagnosis), and answer warm from the
  other tree's resident session. It now answers live and correct, `gist status`
  names the tree the artifacts actually describe, and `gist index` re-binds.
- Reconciled every prose number that quotes the Dominance-and-Fit Certificate with the freshly minted artifact: the package and research READMEs carried a two-mint-old corpus (20,492 files / 195.8 MiB) and win range (2.10x-7.76x, 1.97x-23.57x) where the certificate now reads 20,660 files / 204.6 MiB and 5.78x-8.93x, TESTING.md quoted a Layer C roofline placement of 29.1 GB/s / 35% where the re-mint measures 61.6 GB/s / 77%, and the certify README's system-time figures predated the race-corpus scope fix. Each quoted number is now backed by a freshness sentinel that breaks on the next re-mint, and the csearch rival floors in ratio_baseline.json were refreshed to bound the currently measured loss instead of failing against a stale one.
- The Go binding's linter moved into the job that has the substrate checked out.

  It was living in `discipline`, which opens by saying it needs neither `../irregex` nor a gist binary - and means it, because a contributor who mistyped a heading should learn that in seconds rather than after a matrix compiles. But golangci-lint typechecks, and this module's `go.mod` replaces the substrate with `../../../irregex/bindings/go`, so from a lone checkout it failed on a missing replacement directory rather than on any Go it was asked to judge. The `go` job already clones both repositories and sets up the toolchain, so the lint costs nothing extra there and now reads real code.
- The Go index lifecycle suite gave each corpus a private artifact home, which is only half of the isolation: a resident session left over from another tree is still reachable, and this suite is about what a lifecycle verb writes to disk in *its* home, not about warm dispatch. It now stands the daemon down for the duration.

  That did not account for the whole flake. The residue was an intermittent `gist status: exited -1`, which the improved child-tier diagnostic in irregex has since named a **segmentation fault** in `readGenerationFile` under `status` — a real pre-existing crash, tracked separately, not the noise it was taken for.

  Module floor lowered to `go 1.24` alongside irregex.
- The Go index suite had a test split in two on a false premise, and the half that
  was supposed to run everywhere could not run anywhere.

  The reasoning was that reading a fresh artifact home should be gist's own code,
  so it was pulled out of the relate-dependent test to stop it skipping on public
  CI. It is not gist's own code. `Corpus.Atlas` reads `relate status --json` -
  relate produces the artifacts *and* the document reporting whether they are
  ready - so the extracted half failed outright rather than passing:

  ```text
  --- FAIL: TestAtlasReportsNothingReadyWhenNothingIsBuilt
      atlas: irregex: no gist/relate/blast binary found: RELATE_BIN is unset,
      relate is not on PATH, and no build exists at any of: ...
  ```

  The two halves are back together, with a skip that names the real reason. What
  changed is that the skip is no longer where the story ends: relate's CI builds
  both sides and drives this suite with the binary present, so the assertion gist
  cannot check is checked by the repository that can. Verified on x86_64 Linux in
  both shapes - green with relate absent, and a genuine pass with it present.

  Every other missing-binary arm in the module stays fatal. Those all resolve
  `gist`, which CI builds, so a miss there is a broken environment rather than an
  absent capability.
- The Python binding's whole `test_cursor` surface — 19 tests — killed the
  interpreter outright in a side-by-side dev tree. Not a failure, a SIGSEGV: the
  first `Engine.search` went into `gist_search_cursor` and never came back.

  The process was mapping two engines. `libgist` links `libirgx` dynamically
  and carries a loader-relative rpath, so it binds the copy staged beside itself
  — the one gist's own build produced. Importing `irregex` maps one eagerly too,
  and its loader resolves the engine out of the `irregex` checkout, on the
  deliberate rule that a package's library lives in that package's `zig-out/lib`.
  Both rules are right on their own. Together, in a tree where both checkouts are
  built, they name two different files: a product configures its dependency
  itself, so the sibling's own copy is a different build of the same source. A
  handle minted by one engine then gets read by the other's code, which is
  undefined behavior rather than a decline — macOS binds two-level, so it never
  even reaches the accidental first-wins rescue ELF would give.

  The substrate loader can't fix this, because it has no way to know a product is
  in the room. So gist names the copy its own library binds, before anything
  imports `irregex`. An explicit `$IRGX_LIB` still wins — a caller who names an
  engine meant that engine — and an installed prefix, where both libraries sit in
  one directory, resolves to the file that loader would have picked anyway.

  213 passed.
- The competitive race now scopes gist and rg to the same logical corpus the
  indexed rivals see. Both run under `--no-ignore-vcs` for a deterministic
  multi-root oracle set, but that also discarded every nested `.gitignore` — so
  they alone walked ~2,488 build artifacts the root `.gitignore` never names
  (Elixir `_build`/`deps`/`cover` beam output, Electron `out/`). Those files are
  pruned by `gist index`, so they never enter `paths.list` and never reach
  csearch: the "indexed twin" was racing a strict subset of gist's corpus, and
  every one of those files fell off both the elide oracle and the content shard
  into a live `openat`+`read`. Re-applying them as the glob equivalent of the
  `XDIRS` set the other no-gitignore tools already get cuts gist's `literal-rare`
  cell 1.21x and its system time by a third, with the rg-equality oracle still
  byte-identical across the literal, regex, PCRE, and count fields.
- The cross-language contract parity gate stopped running when the bindings moved into this repo, and nobody could tell, because its failure mode is a skip. Each binding embeds the canonical contract's load-bearing constants so an installed package carries no dependency on a repo file, and a parity test reads `contract/search_api.toml` and asserts the mirror matches — the standard shape, and the only thing keeping four independent copies of the same numbers honest. The tests located the TOML at a fixed depth (`../../contract/` from `bindings/rust`), which was right while the bindings sat beside the kernel in the monorepo and wrong the moment they were extracted here, where the contract stayed behind with the kernel in a sibling checkout. An unreadable contract is a legitimate state — a published crate ships without one — so every assertion took the documented skip branch and the gate went silently dead. The Python locator was worse: it had been off by one directory since before the split, so that mirror was never gated at all.

  The path is now found by climbing rather than counting. Each ancestor is probed twice — `contract/` for the in-repo layout and `irregex/contract/` for a sibling checkout — with `IRGX_CONTRACT` overriding both, and a genuine absence still skipping. Turning it back on caught the drift it exists to catch on the first run: the engine has been `0.3.0` since an automated release bumped `src/root.zig`, while the contract and all three binding mirrors still said `0.2.0`, and the Rust crate additionally still advertised the Python distribution as `billy-irregex` after the rename to `gist`. Both are corrected, and the contract's `engine_version` picked up the release marker its two siblings already carried so the bot moves all three together instead of leaving this one a minor behind.
- The discipline job's shell linter is pinned now, like everything else it runs.

  Every other tool in that job is a Python distribution installed at an exact version into uv's isolated environment, so the job's verdict moves when we move it and not when a tool ships a release. ShellCheck was the one exception and came with the runner image, which meant a runner carrying an older build could report a finding nobody here caused - SC2317 against a `trap`-invoked cleanup that newer ShellCheck reads correctly. Pinning `shellcheck-py` closes the gap over all thirty-six tracked scripts.
- The freshness sweep now prunes with the **same `Ignore` engine that decides admission**, which makes `relate status` **13× faster** (4.19 s → 321 ms). The sweep's job is to name every file changed since the index anchor, and it ended with `retainAdmitted` — the ignore engine — discarding whatever the corpus would never have admitted. But the walk that fed it only pruned on directory _basenames_, so it paid full metadata cost for entire trees the very next step was guaranteed to throw away. Over this repo it stat'd **241,818 files** to describe a **21,106-file** corpus; `upstream/` alone accounted for **206,289** of them — gitignored, never admitted, never skipped, 85% of the walk spent on an answer that was already known.

  The fix is to ask the question earlier rather than to add a second filter: `expandOneLevel` now loads each directory's ignore rules as it descends and drops a child subtree before it becomes a `WorkItem`. That required teaching the work queue which positional root an item descends from — `Ignore` scopes its ancestor tier per root (`scopeToRoot`), so a shared engine has to know which root it is deciding under — and `prunedDir` mirrors `Ignore.admitsPath`'s ancestor discipline so a subtree is pruned on exactly the grounds it would later have been rejected on.

  Pruning a walk is the kind of change that silently loses files, so it is checked rather than argued: the sweep still reports the same changed set (1765 paths against 1764 on the pre-change tree — the drift is live coworker edits, not the filter), and `bench/gates/index_elision_parity.sh` re-proves `index == --no-index` including its freshness cases, alongside `bench/gates/freshness_fs.sh` for unreadable directories and foreign artifacts. The `sweep`, `fresh`, `bulkstat`, and `ignore` unit suites pass unchanged.

  This is a walk that got cheaper, not a corpus that got smaller: the pruned subtrees were never part of the answer.
- The in-process `count` and `files` faces dropped the context window before
  searching, which undercounts when `-m` is also in play.

  Dropping the window is normally free: a context row is not a match, so a face
  that only wants matching lines saves itself the callbacks by asking for none.
  The exception is an after-window under a cap. rg stops *selecting* at the cap
  but keeps searching that match's after-context window, and a match found inside
  it counts - so `-c -m1 -A1` over a file with two adjacent hits is 2, not 1.
  Zeroing the window meant the second line was never looked at.

  The window now survives when the request carries a cap, and the two faces read
  `kind` to tell a match row from a context row instead of counting every row
  that arrives. Before-context is still dropped unconditionally: a line behind a
  match was already offered to the matcher on its own account, so it can never
  add a match.

  The C header said context and inverted selections carry zero submatches. That
  stopped being true when the record stream started painting spans from each
  line's own content, which is what rg does. It now says to read `kind`, never
  the submatch count, to classify a row.
- The packaging gate now reads libgist's export table instead of hiding a file and
  watching what happens.

  The invariant `build.zig` states is about names: libgist links libirgx so that it
  does not restate `irgx_*`, which is what lets a host load libgist and librelate
  together and still see one engine ABI. The gate used to check that by staging both
  libraries, deleting the substrate, and requiring the load to fail. That is a proxy,
  and it turns out to be a proxy for the build machine rather than for the invariant -
  Zig records the dependency's cache directory as a runtime search path, and
  `ZIG_LOCAL_CACHE_DIR` makes that path absolute on CI while it stays relative on a
  dev machine. An absolute one resolves the deleted library straight back out of the
  build cache, so the check asserted the invariant locally and nothing at all on
  Linux CI, where it had been failing.

  It reads `nm` now, which answers the actual question. Deliberately not `dlsym`: a
  handle resolves its dependencies too, so asking a loaded libgist for
  `irgx_engine_open` succeeds by finding libirgx's copy - the very thing under test.
  Three gates replace the one: libgist exports none of the substrate's names, it
  carries a loader-relative search path (the property that makes the shipped shape
  loadable, previously indistinguishable from a build-cache path that happened to
  resolve), and the same probe run over libirgx proves it can see an engine
  vocabulary when one is really there.

  What is deliberately not asserted is that libgist records libirgx as a needed
  dependency. That record is the linker's decision rather than this repository's:
  ELF drops an `--as-needed` library that no undefined symbol needs, so a product
  whose statically linked Zig already satisfies everything records nothing, while
  Mach-O keeps the entry regardless. The sibling products disagree on exactly that
  line today from identical link calls, which is the proof it was never a contract.
  Absent redefinition is what makes the vocabulary single; the dependency table only
  ever explained it, and it is reported in the failure message for that reason.

  Nothing in the build changed - the boundary was already sound. Each product
  statically links the engine's Zig code, because that is what linking a Zig module
  means, and the FFI layer allocates through `std.heap.c_allocator`, so a row minted
  inside one copy and freed inside the other crosses one process-wide malloc heap.
- The published wheel asks for `irregex>=1.0.0,<2` instead of a bare `irregex`.

  Unbounded, the resolver satisfied it with `irregex==0.1.0` - the pre-rename placeholder on the index, which has no `irgx` module in it at all. So `pip install gist-search` installed two packages and then failed on line 20 of `gist/__init__.py`, importing a name the dependency it just fetched has never exported. The floor is 1.0.0 because that is where `irgx` starts existing; the ceiling is the same fact from the other side, since 1.0.0 is where the substrate froze the C ABI and the `irgx` surface and a 2.0 is by definition free to move both. This is a face over an ABI, not a consumer of a loose utility.

  The release gate that reads the built wheel's `Requires-Dist` now asserts the bound as well as the name, and reads that line with `packaging` rather than string surgery. Those two are the same discovery: it was finding the name by splitting on whitespace, which works for a bare `irregex` and stops working the instant a specifier is attached, because `irregex<2,>=1.0.0` has no space in it. Adding the bound made the gate report the dependency missing. A requirement's own grammar is what the index reads, so that is what the gate reads. Four shapes are rejected as intended - a bare name, a ceiling with no floor, a `file://` direct reference, and a requirement on the wrong distribution. It was passing on a requirement that could resolve to something unusable, which is the shape of gate worth strengthening: the floor-install step downstream did catch the broken import, but only because a version old enough to prove it happens to be published. An unbounded requirement is wrong either way, and a release cannot be taken back.
- The rgsuite's tracked `results.json` no longer churns on every re-run. Four mined cases (`ignore_git_multi_root_order`, `ignore_rgignore_multi_root_order`) walk two roots whose visit order is genuinely nondeterministic — measured over 40 runs each, gist drew the two orders 24/16 and ripgrep 26/14 — which is exactly why ripgrep's own suite asserts them with `eqnice_sorted!` rather than `eqnice!`. The scorer already honored that oracle in its verdict (`cmp=sort` sorted-line equality is a full PASS), but it recorded a `detail` of whichever side the coin landed on, so a committed artifact ~10 agents share picked up a spurious diff roughly every other run. A `cmp=sort` case now records the oracle it was judged at, unconditionally. Buckets are untouched — PASS 409 / ORDER 0 / FAIL 0 on both engines, verified byte-identical across twelve consecutive suite runs, where six of the previous six disagreed.
- The test runner is pinned by url and hash instead of assumed to sit beside this
  repository.

  `.brigade = .{ .path = "../brigade" }` resolves on a machine that happens to have
  the sibling checked out, and nowhere else - so a fresh clone, and CI, could not
  build this package at all. brigade is a published package now
  (github.com/The-Billy-Company/brigade), pinned the way the vendored engines
  already were.

  The co-developed siblings stay path deps on purpose: those change together with
  this repository and a checkout beside it is the point. A test runner does not,
  so this repository chooses its version deliberately.
- The warm-tier certificate CSV is now written with a real CSV writer instead of a naive comma join. One probe pattern is the regex `\w{3,8}`, whose brace comma landed unquoted in the middle of the `pattern` field and silently shifted every column after it on that row — so any consumer parsing `certify_warm.csv` read `regex-dense-scan`'s timings out of the wrong columns. The published bundle is regenerated with the pattern correctly quoted; no measurement changed.
- The warm-vs-cold parity tests asserted a cross-file record order neither tier
  promises. The warm engine canonicalizes to a `pathLess` total order; the cold
  walk emits in the filesystem's `readdir` order. On a machine where `readdir`
  comes out sorted the two agree by accident, which is why this passed on macOS
  and on the x86 box and failed on CI. `test_cursor` now pins the cold walk with
  the documented `--sort path`, and the three `test_ffi_parity` sites that forgot
  the file's own `_by_file` grouping use it. Every field of every record is still
  compared; only the free inter-file order is no longer asserted.
- Three READMEs and one source comment said the baked completion menu carries 239
  file types. The registry has grown since that number was written and
  `gist --type-list` now prints 241, so every one of them understated the menu the
  generator actually bakes. The comparison they draw is unchanged, because the 224
  bare names ripgrep offers and the 233 encodings gist bakes are both still exact.
- Three binding READMEs pointed at the substrate with a relative path — `../../../irregex/bindings/rust` and friends — which only resolves when someone happens to have irregex checked out beside this clone. That was true on the machine the monorepo split ran on and false for every reader on GitHub, where the link simply 404s. They address the repository now, so the link works from a clone, from the web, and from a tarball alike. The Rust wiring example also stopped claiming irregex `0.1.0`; `Cargo.toml` has asked for `1.0.0` since the version bump.
- Three composed-face tests in the Go binding still named the scope they search
  with the monorepo path this package was extracted from, so in the extracted repo
  they searched a directory that does not exist.

  The blast test failed outright, which is how this was noticed. The two pack
  tests were worse: an empty scope yields no picks, and "no picks" reads as a
  clean answer rather than as a test that never ran. They now derive the scope
  from the tree - the kernel is the nearest ancestor holding a `build.zig`, the
  binding is this package's own directory - and both resolve correctly whether
  the kernel sits at a repo root or nested inside a larger tree, which is the
  same dual-layout rule the cold-binary probe already followed.

  The containment assertion was rewritten to compare resolved paths rather than a
  string prefix, so it stays meaningful when the scope is the repo root.
- Two release gates were running their stdlib scripts through the project environment, so they needed a sibling checkout the release job has no reason to clone.

  Both are a dozen lines of `pathlib` and `tomllib`: one reads the declared version to compare against the tag, the other reads the built wheel's `Requires-Dist` to prove the shipped dependency resolves from the index rather than from a path. Neither imports anything outside the standard library, but `uv run` without `--no-project` syncs the project first - and syncing means resolving the `[tool.uv.sources]` entry that points `irregex` at `../../../irregex/bindings/python`, which is exactly the development-only entry the second gate exists to catch. So the gate against a path reference shipping could not run without one.

  The version check is guarded on a tag ref, which is why a manual dry run never reached it; it would have failed the actual release. `--no-project` on both, and the reason is written down beside them.
- `--version` / `-V` answers on **stdout** for all three faces, as ripgrep's
  does. It had been going to the diagnostic channel, so `gist --version` read
  back empty from anything that captured only stdout — `$(gist --version)`, a
  CI provenance step, an editor asking which binary it is talking to — while
  looking perfectly fine in a terminal, where both streams land on the same
  screen. A version that was asked for is an answer, not a diagnostic. The
  Python and Rust bindings already read whichever stream carried it, so they
  keep working against older binaries.
- `-U '\Abaz'` matched `baz` in the middle of a file, and `-U '\z'` reported nothing against a file whose last line has no terminator — both because a haystack anchor was being read against a line instead of the buffer. `-U` alone does not choose ripgrep's whole-buffer searcher; the line terminator belonging to the pattern does, and `\A`/`\z` touch no terminator. rg forces the multi-line path for them anyway, twice over — `non_matching_bytes` removes `\n` for `Look::Start | End` under a standing FIXME, and `ConfiguredHIR::line_terminator` returns `None` when the HIR `contains_anchor_haystack` (ripgrep#2260) — because the line searcher would hand `\A` a fresh haystack per line and quietly demote it to `^`. `Regex.readsNewline` became `claimsNewline` and now counts that third way to claim the terminator, so the buffer anchors reach the searcher that can honor them.

  The buffer's far edge came with it. An empty match at `body.len` is a phantom only behind a terminator, where it claims a line that does not exist; an unterminated tail has a real last line flush against `\z`, and rg frames it (`rg -U '\z'` answers `aaa` over `aaa` and nothing over `aaa\n`). The whole-buffer walk also no longer opens a search AT the end, matching rg's `while !slice[pos..].is_empty()` — `body.len` is a place a match may land, never a place one is looked for.

  Proven by a new haystack-anchor lane in `bench/rgsuite/flags.py`: three tail shapes (terminated, unterminated, single unterminated line) crossed with seven output frames, since the model choice is invisible in the plain frame but surfaces as a match tally under `-c`, a column under `--vimgrep`, and a line set under `-v`. Two shapes are named as still short of rg rather than omitted — a nullable `\A` pattern (rg's searcher re-slices on every resume, so `\A` re-anchors and the whole file frames as one block) and an empty match on an unterminated EOF in a span frame (rg's printer discards it, then falls back to printing the block verbatim).
- `libgist` was not loadable outside the tree that built it. Linking the substrate records the dependency's own build output directory as an rpath, and that path is a *relative* `.zig-cache/o/<hash>` — true on the machine that produced it, meaningless anywhere else — so a consumer's `dlopen("libgist.dylib")` failed with `Library not loaded: @rpath/libirgx.dylib` before a single call reached the engine. `build.zig` now adds a loader-relative rpath (`@loader_path`, `$ORIGIN` off macOS), making the shape we actually ship — every library in one lib directory — the loadable one, without naming an absolute path we do not own.

  This hid behind the bindings, which load the substrate first: once `libirgx` is in the process, the loader satisfies a later `@rpath` reference from the already-loaded image by install name. Every binding worked; only an honest standalone consumer failed, which is the one case nothing tested.

  So `tests/test_packaging.py` now stages both libraries into a directory and opens the product **in a child process with a clean environment**, from an unrelated working directory — a same-process check would inherit exactly the rescue that hid this. Mutation-proven: deleting the loader-relative rpath from the built dylib fails the gate. Its sibling asserts the complement, that removing the substrate still breaks the load, so the fix cannot be mistaken for a product that quietly carries its own engine.
- `libirgx.a` was copied into the install prefix with `cp
  ../irregex/zig-out/lib/libirgx.a`, which reads a different build than the one
  gist is being compiled against. Under `-Dtarget=x86_64-linux-gnu` that put this
  laptop's Mach-O archive into a Linux prefix, where the symbols still carried
  their leading underscores and nothing could link against it - and even natively
  it needed someone to have run `zig build` in the sibling checkout first, at
  whatever optimize mode they happened to pick.

  The reason it was a `cp` was real: the engine's archive is an install-file
  product of the irregex package rather than a named artifact, so
  `dep.artifact("irgx")` cannot see it. It is now published over there as a named
  lazy path and taken from the dependency graph, so it is built to order for this
  target.

  The ELF `libgist.a` also stops registering a second build artifact named
  `gist`. The dylib already owns that name, and a duplicate makes a dependent's
  `dep.artifact("gist")` ambiguous enough to panic the build runner - in the
  DEPENDENT, never here, and only on the arm macOS does not take, so it would
  have stayed invisible on a laptop while no Zig consumer could build on Linux.
  Both arms install the archive as a file now, the way the macOS arm already did
  for its own alignment reasons.
- `relate` now signs its diagnostics as `relate:` instead of `gist:`. The engine hardcoded the product name at every diagnostic site, so a bad knob passed to the `relate` binary was reported as `gist: note: ignoring GIST_HYPERLINK=…` — naming a program the user was not running and sending them to the wrong `--help`. The kernel grew a brand seam (`irregex.Brand`, read from the root module at comptime), and `relate`'s entry point now declares `.{ .name = "relate" }`. Only the name moves: the knob namespace stays `GIST_*` and the artifact directory stays shared, because this binary reads the index and atlas the `gist` binary writes. The `gist` binary keeps the default identity, so its output is byte-identical — `--help`, `--schema`, `--version`, `--generate`, and searches over a fixed tree all verified unchanged. The thirteen places that still spell `gist` outright are all inside `src/surface/face/gist/`, where naming the product is the point.


## [0.2.0] - 2026-07-24

### Added

- A `flagbench` micro-profiler (`zig build flagbench`) that isolates and times
  the single hot function each of the flags agents reach for most adds — `-i`
  (the caseless required-literal gate against its case-sensitive twin, the
  ratio being the case-insensitivity tax), `-n` (line-number integer→decimal
  formatting), and `Emitter.file` in each emit mode: `-v` invert, `-l`
  files-with-matches, `-c` count, `-o` only-matching, `-w` word-regexp, and
  `-r`/`-rn` replace — over the real rg-style corpus, best-of-N to escape clock
  noise, with hardware cycle counts when run under a PMU. Every profile whose
  hot function this change touched self-checks byte-identity as it runs (a
  scalar caseless oracle for `-i`, `{d}`-vs-`writeDecimal` for `-n`, an
  independent reference invert emit for `-v`, and a line-hit oracle for the
  `-l`/`-c` emit rewrites), so an optimization that drifts output fails the
  bench rather than slipping to review; `-o`/`-w`/`-r` byte-identity stays the
  CLI parity suite's job. It also carries conservative regression floors — the
  caseless tax and `writeDecimal` speedup as same-run ratios (jitter cancels),
  the emit-mode throughputs as absolutes far below observed — advisory by
  default and blocking under `zig build flagbench -- --gate`, wired into
  `bench/gates/ci_order.sh` so a lost optimization fails CI's performance phase
  instead of silently regressing.
- A count-mode lane in the resident-session certificate (`bench/session/`), the
  warm analog of the new cold `-c` race. The `gist-bench session` harness now
  replays its slate over the same warm daemon connection a second time in count
  mode — the protocol already carries `.count`, so the daemon answers each with
  its `countLines` tally (grep `-c` semantics) — and emits `session_count.csv`.
  `certify_session.sh` pairs each warm `-c` p50 with a ripgrep-cold `-c` timing
  and reports a geomean count speedup + a per-needle table in
  `CERTIFICATE_SESSION.md` (`session_count_macro.csv`). Because `-c` scans
  every candidate whole with no first-hit short-circuit, it is the harder proof
  the resident-index win survives more per-file work: on an armed macOS box the
  warm count path measures ~137× over ripgrep cold — enormous, and honestly
  narrower than files-mode's ~693× for exactly that reason. The lane is
  **reported, not gated** (absolute count latency is box-specific;
  `gate_session.py` still enforces only the files-mode armed floor), and
  `d_count`/`rg_count` carry the same not-like-for-like caveat as
  `d_files`/`rg_files` — the daemon counts over its own live watcher-reconciled
  corpus while rg re-walks, so the speedup is the claim, not count equality
  (exact parity stays the hermetic Zig suite's job).
- A cross-language eligibility parity suite
  (`bindings/python/tests/test_classify_parity.py`) now pins Python's
  `session.warm_eligible` predicate to the Zig `request.zig::classify`
  authority. Both are projections of one contract — which requests answer warm
  — over different inputs (request fields vs an rg argv), so they cannot share
  code, only agree. The suite lowers each request to its real argv, reads the
  built binary's `GIST_DEBUG_WARM` verdict, and asserts both sides land on the
  same declared eligible/ineligible outcome across every accepted clause and
  every ineligible dimension — anchored so it can never pass by both
  mislabeling the same shape, so the two can never drift.
- A release is now gated on the Certificate of Optimality being freshly
  re-minted and attached on **both** the Mac and the Linux machine
  (`bench/certify/check_release.py`). Cold-CLI dominance is machine-specific,
  so per-platform bundles publish under `artifact/<platform-id>/`
  and Town Crier refuses the release until both are present, valid, and
  current.
- A second emit lane in the cold field race (`bench/races/coldquery.sh`): after
  the existing `-l` files-with-matches lane, the same needle spread —
  guaranteed miss, very-selective, medium, common, and the 2-byte-punct
  fallback — now also races in `-c` per-file count mode against the unindexed
  grep-`-c` field (rg/ugrep/ag/GNU-grep/git-grep). Where `-l` short-circuits at
  the first hit per candidate, `-c` scans every candidate whole and tallies, so
  it's the harder proof that gist's trigram-index pruning still dominates when
  per-file work rises — and it does: ~8× geomean vs rg, won every query against
  every unindexed scanner, mirroring the `-l` lane. gist's `-c` is byte-parity
  with rg's (already gated by the CLI matrix + `flagbench`), so the timed gist
  cell stays oracle-gated against rg exactly like `-l`; a count-set drift
  aborts the race instead of publishing a bogus speedup. Both indexed rivals
  are absent by construction — zoekt exposes no per-file `-c`, and csearch's
  `-c` is a total-match tally rather than grep's per-line-per-file count, so
  neither is an apples-to-apples count oracle. Rows land in
  `.local/gist-compete/cold_count.csv`.
- Added **Layer D of the Certificate of Optimality — the algorithmic lower
  bound** (`bench/lowerbound/`): a fail-closed byte-touch audit proving gist
  sits at the information-theoretic floor, verified structurally against an
  independent single-pass reference on the real 160 MiB corpus — the fused
  byte-class DFA touches each candidate byte **exactly once** (`passes ≡
  1.0000`, no memchr-then-rescan double traffic; KMP'77 / Boyer-Moore'77 Ω(n)
  verify floor), the SIMD literal path reads **≤** the floor, and the trigram
  prefilter prunes as much as 95.65% of the corpus untouched before verify
  (Cox'12). 11/11 classes at the floor; the gate is proven non-tautological by
  fault injection (a single extra byte-read per line trips `exit 1`).
- Added Layer B (port-optimality) of the Certificate of Optimality:
  `bench/portcert/` cross-compiles byte-faithful copies of gist's two hot loops
  (`simd.contains`, the byte-class DFA transition) to two real reference
  microarchitectures — AMD Zen 4 (`znver4`) and Arm Neoverse V2 (`neoverse-v2`,
  AWS Graviton4 / Google Axion) — and scores each with `llvm-mca` for its
  static port-pressure bound (cycles/byte), splicing a `## Layer B` section
  into `CERTIFICATE.md` and a machine-readable `portcert.json` the roofline
  layer consumes. The probes are drift-guarded (`probes_test.zig` asserts
  bit-identical results vs the real functions), and Layer B is a static-only
  certificate over cross-compiled cores because LLVM has no real scheduling
  model for any Apple CPU (all map to the 2013 Cyclone model; LLVM #63698); it
  degrades gracefully to a documented skip when `llvm-mca` is not installed.
- (in `irregex`) Added a zero-copy emit transport to the warm `gist serve` daemon: a large…
- Added the gist operational-envelope matrix under `bench/evaluate/`:
  a closed-verb evaluator (`run`/`verify`/`compare`/`brief`) over the regimes
  frozen in `contract/performance_evidence.toml` — lifecycle, resource, scale,
  and concurrency — that reuses the existing race registry (`_compete.sh`),
  hyperfine harness, and certificate statistics rather than re-encoding them.
  It is the operational complement to the Certificate of Optimality, which owns
  cold/warm query dominance, cycles/byte, rg drop-in correctness, and the
  optimality layers: the matrix measures only the envelope the certificate does
  not — index build + incremental refresh cost, footprint (index/corpus ratio,
  peak RSS, scan throughput), scaling shape, and concurrent-load qps/tail — and
  never re-times or restates a certificate number. Absolute build ms, RSS, and
  qps stay machine-local while the index/corpus footprint ratio and scaling
  shape are the only cross-machine gates; a byte-exact parity-vs-ripgrep
  precondition (both engines) guards each lane before its timings are trusted.
  Bundles are machine-labeled and published only from a clean tree; an
  unmeasurable value is an honest null, never fabricated. Each run first
  freezes the scoped corpus into an immutable same-volume snapshot
  (`GIST_CORPUS_ROOT`) so a live ~10-agent coworking tree cannot churn under a
  capture, and carries `_compete.sh`'s uncapped-output env contract
  (`GIST_UNCAP=1`) into every command so gist's default output budget can't
  clip a repo-wide result and desync the ripgrep oracle. An idle-gated path to
  a self-hosted GPU box borrows it for a second x86_64-linux datapoint over a
  pinned-key transport, never raw ssh and never stopping its day job.
  (see also: irregex)
- CREST's production proof now fixes and pins the class-run optional-seam false
  negative against the real matcher, records all ASCII/Unicode ×
  case-sensitive/caseless differentials, corpus identities, and every raw
  timing sample behind `crest.csv`, and ships a stdlib-only release-evidence
  packager. Clean-tree packages bind one Git revision, source archive, test and
  benchmark receipts, machine/cache metadata, and a `git show`-rendered
  monograph through fail-closed SHA-256 manifests, detached hashes, and exact
  path/byte/mode reproduction from the claimed Git object.
- Closed the certificate's PMU truth gap. New Layer B′
  (`bench/portcert/portbound.zig`, `zig build portbound` → `gist-portbound`):
  runs the same drift-guarded hot-loop probes as Layer B's static llvm-mca
  bound natively under the PMU, minting a measured-on-this-machine cycles/byte
  (`simd_contains`, throughput) and cycles/step (`dfa_step`, recurrence
  latency) with full provenance — CPU brand via `machdep.cpu.brand_string`, a
  P-core note (USER_INTERACTIVE QoS + measured effective GHz), and the PMU
  source — spliced into `CERTIFICATE.md` as its own subsection alongside (not
  replacing) the znver4/neoverse-v2 static bounds, with the unmarked production
  `simd.contains` timed alongside as a marker-overhead cross-check. PMU state
  is now a first-class fail-closed certificate fact: without root the artifacts
  state "cycles/byte: cross-checked (reference cores), NOT measured on this
  machine" and name the exact `sudo` rung, never converting wall-clock to
  cycles via an assumed frequency. `pmu.zig`'s dlsym plumbing collapsed to
  comptime symbol tables + one resolve loop (init-time only; counter reads
  unchanged at exactly two per measured window).
- Extend the Certificate of Optimality to the narrower surfaces that previously
  carried no first-class evidence: the `--rank` lane (Layer A — no-fabrication,
  coverage, def-boost, codegen-demote, bounded overhead, and beats-rg where the
  trigram prefilter prunes the corpus; saturating needles are bound by the
  overhead claim instead), Layer F (codex self-index — sub-entropy searchable
  space, n-free O(m) count, byte-exact decode, cento self-recognition), and
  Layer G (relate — retrieval-by-description-length boundary, recall@1, and
  anti-redundant pack). Each is fail-closed and gated by `check_artifacts.py`;
  the warm tier is upgraded to a per-class Mann-Whitney dominance verdict.
- New Go binding (`bindings/go/`) over the pull-cursor C ABI — a cgo wrapper
  linking the self-contained `libgist.a`, in its own `go.mod` so it never
  enters a consumer's `CGO_ENABLED=0` static build. A warm `Engine` opened
  over roots (none = the rootless CWD walk)
  runs many `Search(ctx, Request)` queries, each materializing a pull `Cursor`
  driven scanner-style (`Next`/`Match`/`Err`) or via a Go 1.23 `All()`
  range-over-func; the cursor refills an internal batch under the hood, paying
  the cgo crossing once per 64 records. Cancellation and deadlines flow
  straight from the `context.Context`: a watcher goroutine trips a native
  cancel token the engine observes at the next record boundary, torn down
  before the token frees, so a canceled ctx surfaces as `ctx.Err()` and a long
  scan on one goroutine is abortable from another. Records are copied into
  Go-owned `Match` values that outlive both handles; `ErrUnsupportedPattern`
  (test with `errors.Is`) wraps a lookaround/backreference the linear engine
  declines, never a dead process. Every handle has an idempotent `Close` plus a
  GC finalizer. Tests use the certified `gist --json` binary as a cross-face
  oracle and skip cleanly when none resolves.
- Python bindings gain a result-side aggregation API: gist.summary() searches
  then buckets matches, and gist.tally() groups any Match sequence by a named
  axis (file/dir/ext/match) or a custom callable, ranked by count. It is
  contract-safe (does not widen SearchRequest) and pure over the engine's
  results.
- Python bindings gain gist.rank(): the engine's definition-first --rank view
  as typed Ranked rows carrying the engine's own def/use/gen classification
  (RankKind) — a symbol's declaration ahead of its call sites, codegen demoted.
  The classification is read from the engine, never reclassified in Python, so
  aggregation can exclude generated files without forking the classifier.
- Rust crate gains gist::rank(): the engine's definition-first --rank view as
  typed Ranked rows carrying the engine's own def/use/gen classification
  (RankKind) — a symbol's declaration ahead of its call sites, codegen demoted.
  The classification is read from the engine, never reclassified in Rust, so
  aggregation can exclude generated files without forking the classifier.
  Reaches parity with the Python face.
- Rust crate gains the same result-side aggregation API as the Python face:
  gist::summary() searches then buckets matches, and gist::tally()/tally_by()
  group any Match sequence by a named Axis (File/Dir/Ext/Match) or a custom
  Fn(&Match) -> String, ranked by count. It is contract-safe (does not widen
  SearchRequest) and pure over the engine's results.
- (in `irregex`) Structured stderr guidance channel for agents…
- The Certificate of Optimality gains Layer E — the crest sieve: a fail-closed,
  measured proof that gist closes the literal-free class-repetition blind spot
  (the Layer A `regex-classcount` cand%=100% hole) every trigram-family index
  concedes, with a count-cousin ablation proving the forced run is the
  necessary condition. Minted by `zig build crest` and spliced by
  `certify_crest_report.py`; the reproducibility gate now requires the Layer E
  section + `crest.csv` sidecar.
- The Python bindings now ship `gist.ensure_serve` and the
  `gist.opening_session` context manager: a batch caller
  opens one warm `Session` — auto-spawning a detached `gist serve` daemon when
  none is listening (herd-safe, `GIST_NO_AUTOSERVE`-gated, fail-open to cold) —
  so its multi-query loop rides the resident UDS path instead of re-paying the
  cold subprocess + index-mmap startup per call. Its first consumers were batch
  documentation-freshness and lint file scans in the originating monorepo.
- The Python package now drives the in-process C session ABI
  over cffi (`irregex/_ffi.py` ABI-mode `dlopen` of `libirregex.{dylib,so}`),
  so a persistent `Session` serves eligible queries WARM inside the host
  process — no subprocess, no Unix socket. Unlike the rootless UDS transport
  (files/count only), it streams full `Match` records and opens explicit
  `SearchRequest.paths` as C root arrays, giving `Session.run` a scoped warm
  path; `files`/`count`/`absent` prefer it too, each byte-identical to the cold
  `gist --json` stream (records, `-l`, `-c`). It is fail-open by construction:
  `_ffi` returns `None` (→ UDS daemon, then cold subprocess) when the shared
  library or `cffi` is absent, the ABI version disagrees, the corpus can't
  open, or the pattern is unsupported (`IRREGEX_STALE`) — so `cffi` stays
  OPTIONAL and the wheel stays pure-Python and dependency-free (opt out with
  `GIST_NO_FFI`, override the library with `GIST_LIB`). Handles are bounded and
  keyed by `(process CWD, roots)`, preventing scope reuse; each
  `gist_search` runs over its own per-call arena, so overlapping calls can't
  corrupt one another's scratch. Proven by `tests/test_ffi_parity.py` (FFI ≡
  cold: records, files, count, explicit relative/file/absolute roots,
  read-your-writes, deletion reconcile, unsupported→cold, ABI parity).
- The Rust `gist` crate gained an opt-in `native` feature exposing an
  in-process warm `Engine`/`Cursor` over the pull-cursor C ABI, the
  graduation rung beside the default subprocess transport.
  `Engine::open(roots)` holds a warm corpus; `search`/`run` return a pull
  `Cursor` implementing `Iterator<Item = Result<Match>>` (plus `batches(n)` to
  amortize the FFI crossing), with a thread-safe `CancelToken` and
  per-operation `Run` budgets (deadline, `max_results`) honored at record
  boundaries. Records are copied into owned `Match` values, so they outlive
  both handles; a materialized cursor is independent of the engine. Every
  failure is the crate's typed `Error` — a pattern outside the linear engine is
  `Error::UnsupportedPattern`, an option the ABI can't carry (glob/type
  scoping, multiline, a non-linear engine) is the new `Error::Unrepresentable`
  — never a `die()`ed host. Its `build.rs` links the self-contained
  `libirregex` resolved beside the kernel or at `$GIST_LIB_DIR`; the default
  crate still links no native archive and lifts out cleanly for the OSS
  release. A `--features native` parity test asserts the warm cursor's records
  are byte-identical to the certified cold subprocess.
- The content-transform flags (`-z`/`--search-zip`, `--pre`/`--pre-glob`,
  `-E`/`--encoding`, `--binary`/`-uuu`) now carry permanent regression coverage
  in the Certify Benchmark. `bench/rgsuite/transforms.py run` is a
  hand-authored differential vs ripgrep over minted fixtures (compressed blobs
  per container, UTF-16/Latin-1 text, a NUL-bearing file, a `gzip -dc "$1"`
  preprocessor) — byte-for-byte on `-z`/`-E`/`--pre`, and `rg -a` as the oracle
  for `--binary`'s deliberate whole-file superset — each case also asserting
  indexed == `--no-index`, run once per engine; it is wired into the
  correctness phase of `bench/gates/ci_order.sh`. `transforms.py bench` adds a
  blocking `-z` speed floor: gist's in-process `std.compress` decode of
  gzip/zstd/xz must stay ~2×+ faster than ripgrep's
  fork-a-decompressor-per-file (`--floor-rg`, conservative vs the real ~4-15×
  so jitter never false-trips), wired into the perf phase.
  `bench/races/searchzip_headtohead.sh` adds ugrep to the `-z` field over a
  nested compressed corpus. A pure `pipeline.transformsRidePipeline` seam +
  unit test pins the routing contract (`-z`/`-E` ride the parallel engine,
  `--pre`/`--binary` stay serial) so a future edit can't silently drop `-z` to
  the serial path.
- The fail-closed cold certificate gains a twelfth class, `regex-litalt`
  (`panic|0x`) — the sparse sub-trigram pure-literal alternation that was the
  table's one documented loss (0.93×) before the fused `containsAny`
  equivalence path. The class is wired through the shared probe registry
  (`bench/harness/probes.zig`, so Layers A and D pick it up by construction),
  `certify.sh`, `ratio_regress.py` (committed floor 1.15×), and
  `check_artifacts.py`. The republished committed certificate reads **12 win ·
  0 parity · 0 loss** vs official ripgrep (hyperfine 20 runs + 3 warmup, 95%
  bootstrap-CI medians, Mann-Whitney p<0.001 on every class), with
  `regex-litalt` at 1.66×; Layer D's byte-touch audit holds all 12 classes at
  the Ω(candidate-bytes) floor.
- The four remaining figure scripts now read committed data instead of
  transcribing it. `gist_cold_field.py`, `gist_warm_dominance.py`, and
  `gist_regex_matrix.py` read `bench/races/artifact/{cold,warm,regex}.csv`
  (reproducible snapshots published from `bench/races/*.sh`);
  `gist_scan_progression.py` reads `bench/races/artifact/scan_progression.json`
  (curated PMU / optimization history). All fail loud if the data is missing,
  so a figure can never be silently drawn from stale numbers —
  `check_artifacts.py --dataviz` now passes on all five gist figures. This also
  fixes a CSV-injection bug in `regex_headtohead.sh`: patterns containing
  commas (`\w{3,8}`, `[a-f0-9]{2,}`) were written unquoted, splitting into
  extra columns and corrupting `regex.csv`; the pattern field is now quoted,
  and the figure parser skips any non-numeric cell.

  The committed race data (Apple M2, ~15.3k-file worktree) confirms the split
  the macro certificate found: gist's WARM resident path dominates (rg 807×,
  git grep 1158×, 20/20), while its COLD literal and regex CLI lose to the
  whole field (rg ~0.3×; csearch/zoekt ~0.1–0.4×) — the per-query freshness
  `stat()`-walk cost. The regenerated `assets/gist-*.png` figures now show this
  honestly.
- (in `irregex`) The index loader now fails closed on a corrupt blob, and the benchmark-timer…
- The irregex verbs ship as their own product face: a `relate` binary
  (`similar` / `dups` / `patterns` + `--schema`) built from
  `src/cli/relate/main.zig` over the same kernel, corpus policy, and persisted
  trigram index as `gist` — one engine, two faces. The install step places
  both (`~/.local/bin/{gist,relate}`); the Python bindings drive the verbs
  through `relate` (`RELATE_BIN` override); the `gist` CLI sheds them with a
  redirect stub (exit 2) rather than a silent literal search, and its
  `--schema` marks the three verbs moved.
- The resident (warm) session now serves scoped searches it previously punted
  back to the cold path: an explicit `ROOT…` path argument and `-g`/`-t`
  glob/type filters. A new additive `query_ext` wire opcode carries the
  request's
  roots, include/exclude globs, and file-type set alongside the pattern;
  `request.classify` parses them into a borrowed `ScopeArgs` scratch that
  aliases
  `argv`, the daemon admits a query only when its requested roots are a subset
  of
  the roots it already serves (`ResidentSession.servesScope`), and prunes
  candidates daemon-side through the very same `PathFilter.admits` the cold
  walk
  uses — so a scoped warm hit is byte-identical to cold, just without the
  per-query trigram-index + corpus load. Measured ~5× on `-l` against a cold
  no-index walk of the same scope.
- The resident daemon now enforces a per-query wall-clock budget
  (GIST_QUERY_BUDGET_MS, default 30s), armed under the session lock and sampled
  at strided checkpoints in the O(corpus) walks. A runaway or client-abandoned
  scan is declined to the cold path instead of pinning the single daemon thread
  the coworker fleet shares; the fast path stays zero-cost (embedders/FFI
  remain unbudgeted). The hosted API's RunOptions cancel/timeout_ns now also
  bound the doc scan (not just the record boundary): a cooperative gather halt
  honors them cleanly — the cursor keeps its partial results, no Stale — so a
  rare-pattern or invert scan that never reaches an emit is abortable too,
  while max_results stays record-boundary-only.
- Two committed gates keep the rgsuite report and the index-size claims honest.
  `bench/rgsuite/check_results.py` fails the build if the rgsuite README's
  bucket counts or supported-surface parity drift from the committed
  `results.json` (the exact README-vs-results drift the audit found), if any
  FAIL case carries a `null`/empty `detail`, or — without `--allow-fail` — if
  there is any FAIL at all, so a not-zero-FAIL suite is always explicit.
  `bench/gates/index_size_accounting.py` measures the FULL on-disk gist cache
  (`index.gist` posting blob + `paths.list` + the `built.ns` freshness anchor),
  emits `index-sizes.json`, and can `--assert-total-under-csearch`, so any
  "smaller than csearch" comparison cites gist's total cache rather than the
  posting blob alone.
- Warm resident session eligibility for `-q`/`--quiet` and `-m N`/`--max-count
  N`,
  byte-identical to cold. `-q` becomes an existence early-halt: the daemon
  walks
  the corpus only until the first match, answers a single matched bit, and the
  client prints nothing and sets the exit code (0 found / 1 not) — the no-match
  hint stays silent, exactly as cold's quiet path. `-m N` caps matching lines
  per
  file (per-file reset) across `-c`, `-l`, and the default line emit, mirroring
  rg's `-m0` = match-nothing (exit 1) at the session boundary. The v2 query
  flags
  byte now carries `quiet` (bit 6) and `max_count` (bit 7) live alongside
  `smart_case`/`word`; `max_count` is the first flag with a payload — a `u64
  LE`
  cap written immediately after the flags byte — and `decodeQuery` fails closed
  on
  a truncated cap (BadFrame → decline → cold). The engine branches once at the
  top
  of each face (a comptime-generic count cap; the warm line renderer routes the
  cap
  through cold's own `Emitter`), leaving the uncapped hot loops byte-for-byte
  unchanged. Python `SearchRequest.max_count` becomes `int | None` so the falsy
  `-m0` is distinguishable from unset. Both flags are UDS- and FFI-eligible:
  the
  size-checked `gist_search` options contract carries quiet plus the
  `u64` per-file cap. Smart-case is
  FFI-eligible too: C carries the raw bit and Zig's `effectiveIgnoreCase`
  remains
  the sole Unicode uppercase authority. Explicit path scopes also route through
  FFI's existing root-array ABI; Python bounds and keys handles by `(cwd,
  roots)`
  so one request can never reuse another scope's corpus. Explicit Unicode/ASCII
  mode is FFI-eligible as well, lowered into the shared `CompiledQuery` rather
  than reimplemented by the binding. `engine="auto"` now tries FFI for
  linear-compatible patterns and treats `IRREGEX_STALE` as the existing signal
  to fall through to cold PCRE2. Invert-match (`-v`) is now FFI-eligible: the
  resident stream scans every live document, selects only lines with zero
  spans,
  and keeps quiet/max-count/files/count semantics byte-identical to cold.
  Context
  windows are FFI-eligible too, with explicit match/context record kinds. C ABI
  1
  starts with one coherent options and match shape; its Zig layout
  lives in `runtime/ffi/contract.zig`, separate from session execution. The UDS
  protocol version is unchanged (bits 6/7 were reserved).
- `--rank` now answers from the resident session instead of falling back to
  cold. The daemon ranks over its in-memory `LiveFile` set
  (`renderRanked`/`renderLive`) — a symbol's definition ahead of its call
  sites,
  generated files demoted — reusing the same chunk transport as plain warm line
  output. `request.classify` mirrors cold's last-explicit-wins `--rank[=k]`
  semantics and declines the combination of `--rank` with context
  (`-A`/`-B`/`-C`), which has no meaning in a ranked view. Output matches
  cold's
  ranked cap; measured ~2× over the cold no-index baseline.
- `-A`/`-B`/`-C` context windows now render warm. `request.classify` accepts
  the
  short forms (glued `-A2` and separated `-A 2`), the long forms
  (`--after-context`/`--before-context`/`--context`, `=`- or space-joined),
  folds
  them with cold's precedence (`after = A ?? C`, `before = B ?? C`), and
  declines
  non-decimal or missing values. The `query_ext` opcode gained a
  back-compatible
  context trailer (protocol v4 — older daemons tolerate its absence via
  `takeContext`), and the warm `lines` renderer reuses the cold
  `output.Emitter`
  for in-file windows plus cold's inter-file `--` separator, forcing serial
  emission on context queries so the cross-file separator state stays exact.
  Byte-identical to `gist --sort path` under an uncapped output
  (`GIST_UNCAP=1`); measured 4–6× on narrow context queries over the cold
  no-index baseline.
- (in `irregex`) `-P`/`--pcre2` selects a vendored PCRE2 10.47 JIT backend…
- `bench/certify/check_artifacts.py` — a certificate-reproducibility gate that
  defines what a third-party-reproducible macro certificate must contain and
  fails until it does. `--artifacts` requires the certificate output dir to
  hold every file needed to regenerate the result (`CERTIFICATE.md`,
  `certify.csv`, `certify_macro.csv`, raw hyperfine JSON, `machine.json`,
  `tool-versions.txt`, `corpus-manifest.tsv`, `command-log.txt`) and every
  metadata key a reviewer needs (cpu_model / cpu_count / ram_bytes / os /
  kernel / filesystem, the zig/rg/csearch/zoekt/hyperfine versions, git_commit,
  corpus_file_count, corpus_total_bytes); it exits 2 (not 1) when no
  certificate has been produced yet. `--dataviz` enforces figures-from-raw: it
  fails if any `gist_*.py` figure script still transcribes numbers
  ("transcribe" / "hardcoded" / "manual") or never actually reads its committed
  source CSV — currently flagging all five, which stay transcribed pending a
  committed certificate run. Producing that committed run (and then converting
  the figure scripts to read it) needs the full field — rg + csearch + zoekt +
  hyperfine.
- `bench/gates/ci_order.sh` — the canonical gist CI order as one runner:
  correctness before performance. Every correctness gate (`zig build test`,
  rgsuite parity, line-output parity, index-elision parity, the fail-closed
  contract, freshness) runs first, and the performance certificate
  (`certify.sh` + the certificate-artifacts and index-size checks) runs ONLY
  after they ALL pass — a benchmark verdict over unproven behavior is
  untrustworthy, so perf is skipped with a clear message when any correctness
  gate fails or when the field tools (rg/csearch/zoekt/hyperfine) aren't
  installed. `--gates-only` skips the compile for a fast orchestration check;
  `--allow-known` treats the tracked rgsuite FAILs as non-blocking so a
  developer can still reach the perf phase.
- `bench/gates/freshness_fs.sh` — the live-filesystem half of the "no false
  negatives under stated assumptions" claim (`corpus/fresh_test.zig` only
  unit-tests the `widen` set algebra). It builds the index ONCE, then mutates a
  real corpus and requires the index-accelerated `gist rg -l` to equal `rg -l`
  on the live tree (rg = ground truth) after each change: a new file under the
  indexed root, an edited indexed file that gains the needle, a deleted file
  (dropped), a renamed file (old path gone / new path found), and — notably —
  two preserved-mtime edits (an append and a same-size overwrite, each with the
  exact pre-edit mtime restored) that gist STILL finds, because it re-verifies
  live bytes rather than trusting mtime alone. One tracked divergence is
  reported without failing the gate: an unreadable directory is a SILENT
  traversal failure — gist exits 0 with empty stderr where rg exits 2 with a
  "Permission denied" warning, so a skipped directory currently produces an
  unsignalled false negative (candidate bug: the freshness/walk layer should
  report traversal errors).
  (see also: irregex)
- `bench/gates/line_parity.sh` — a committed line-output parity gate proving
  `gist rg -n --no-heading` is byte-for-byte identical to `rg -n --no-heading`
  over a frozen corpus, case by case (the committed `equality.sh` only proves
  file-SET soundness via `rg -l`, not line output). 22 core cases pass
  byte-identical — literal, `-F`, multi-`-e`, context `-A/-B/-C`, `-o`,
  `-c`/`--count-matches`, `-w`, `-i`, `-x`, empty-line, `-r` captures,
  `--crlf`, `--hidden`, `--no-ignore`, non-UTF-8 `-a`, `--max-columns-preview`,
  and paths containing a colon, a space, or a leading dash. Unsupported flags
  (`-U`, `-P`) must fail loud (exit >= 2), never silently accept-and-differ.
  Four divergences are documented and tracked without failing the gate: a
  **candidate bug** where `gist -g <glob>` includes hidden/ignored files that
  `rg` keeps filtered (default hidden/ignore parity is otherwise exact — only
  `-g` overrides it); the known rgsuite f917 FAIL (`--trim` +
  `--max-columns-preview` + `--color`); and the two documented
  byte/ASCII-vs-Unicode-default boundaries (word boundary `\b` and `-i` case
  folding on non-ASCII). `--sort path` is passed to both sides so multi-file
  output has one deterministic order, making a raw compare a true byte diff.
- `bench/session/` certifies the honest warm-product path: a persistent client
  dialing a `gist serve` daemon once over a Unix socket and replaying a slate
  over
  that warm connection. A new `zig build bench -- session`
  mode
  times the real client→daemon round-trip (daemon on its own thread, one reused
  connection); `certify_session.sh` pairs each needle with ripgrep-cold and
  writes
  `session_macro.csv` + `session_meta.json`; `gate_session.py` (`make
  bench-gist-session`) enforces the armed-path geomean floor and is report-only
  on
  platforms with no watcher backend (every query pays the reconcile freshness
  tax).
  Even unarmed on macOS it measures **7.2× geomean over ripgrep-cold** — rg
  re-walks and re-scans the whole tree each call while the warm client pays
  only
  the reconcile plus an in-RAM index query. `ci_order.sh` runs the committed
  session gate alongside the cold ratio gate in the performance phase.
- `certify.sh` now emits a **committed, reproducible** certificate. Beyond
  `CERTIFICATE.md` + `certify_macro.csv` it writes the full provenance a third
  party needs to regenerate the numbers — `machine.json` (CPU / RAM / OS /
  kernel / filesystem / git commit / corpus file-count + byte-count),
  `tool-versions.txt`, `corpus-manifest.tsv`, `command-log.txt`, and the raw
  per-cell `hyperfine` JSONs — and `CERT_PUBLISH_DIR=… certify.sh` publishes
  the set to a committed dir (`bench/certify/artifact/`, gated by
  `check_artifacts.py`). `gist_certify_forest.py` now reads `certify_macro.csv`
  at render time instead of transcribing it, and `certify.sh`'s field-tool
  version capture is hardened (falls back to `installed`). Requires bash 4+
  (uses `mapfile`) and the field (rg / csearch / zoekt / hyperfine).

  **The first committed run refutes the "9 win / 2 loss" claim on this
  hardware.** On an Apple M2 over the 15,265-file worktree, the fresh-process
  cold-CLI certificate reads **0 win / 0 parity / 11 loss** vs ripgrep: gist's
  cold query is ~2–3× _slower_ than `rg` across every class (gist `pgxpool` 639
  ms vs rg 200 ms; csearch 19 ms, zoekt 57 ms), because the per-query
  corpus-wide freshness `stat()` walk over 15k files dominates the cold path —
  the residual the README downplayed is, here, larger than the index-pruning
  win. The published `9 win / 2 loss` was machine/corpus-specific (or stale);
  the cold-CLI claim does not reproduce on this box. (gist's warm in-process
  kernel, `gist-bench`, is a separate path and not measured by this
  certificate.) This is precisely why the certificate now ships with
  `machine.json` provenance instead of a transcribed table.
- (in `irregex`) `gist index` now emits a **content shard** (`corpus/index/content/shard.zig`,…
- `gist status --json` now exposes a versioned lifecycle snapshot for Python,
  Rust, and agent consumers, derived from the same data model as the human
  report
  so callers no longer need to parse status prose.
- `ratio_regress.py` + `ratio_baseline.json` gate gist's cold gist/rg speedup
  floors (principia-style ratios). The hermetic `--committed` mode reads the
  published `certify_macro.csv`; `GIST_BENCH=1 make bench-gist-ratio`
  optionally
  remeasures live. The certificate artifact is republished under
  `bench/certify/artifact/` (**11 win / 0 parity / 0 loss** vs ripgrep on Apple
  M4 Max) so README cold-dominance claims are evidence again, and `ci_order.sh`
  runs the ratio gate after the bundle integrity check.
- (in `relate`) `relate search <text>` — compression-as-search retrieval, hand-rolled. The…

### Changed

- (in `irregex`) **The two search engines merged into one.** `gist`'s certified ripgrep-parity…
- (in `irregex`) **Trigram index switches from a flat `(trigram,doc)` pair table to a CSR…
- A bare `zig build` now installs only the product surface — the `gist` +
  `relate` CLIs and the C-ABI static/dynamic libraries — instead of also
  compiling the six measurement-lab executables (`gist-bench`, `relate-knn`,
  `codex-scale`, `gist-roofline`, `gist-lowerbound`, `gist-portbound`). Each
  lab exe still installs via its named step (`zig build bench`, `zig build
  roofline`, …) and the new `zig build lab` umbrella installs all six;
  `certify_session.sh` builds the lab step explicitly. Cuts the default
  rebuild to 4 artifacts from 10.
- (in `irregex`) Beat ripgrep on the single-file line-scan modes by adopting the two things…
- Committed certificate carries all four layers (A–D), and minting is one
  command: `make bench-gist-certify` (or `certify.sh`, which auto-splices
  B/B′/C/D). `check_artifacts.py` fail-closes if any layer section or side-car
  is missing; `CERT_SUDO=1` prompts once for measured kperf cycles.
- Gist `research/gist/PRIOR_ART.md` covers gist-face citations only (rg peers,
  trigram/indexed neighbors, matcher/ranking ancestry). Shannon–Manzini /
  FM-index
  codex literature stays in the relate dossier.
- Move gist's prior-art / scope essay into research/gist/ (CLAIM + PRIOR_ART +
  TESTING), matching the crest research dossier layout; delete the package-root
  PRIOR_ART.md.
- Replaced the README's two pre-CSR-index-rewrite figures (`gist-competitive`,
  `gist-field-race`) with four new ones driven by a full fresh run of the
  seven-tool field race and the fail-closed certificate:
  `gist-cold-field` (11-needle cold literal range + win rate),
  `gist-warm-dominance`
  (warm-session geomean/miss plus a 50-query session-time comparison),
  `gist-regex-matrix` (all 22 regex tiers × all 7 tools), and
  `gist-certify-forest`
  (median + 95% CI forest plot for the fail-closed certificate). The
  certificate's
  2 previously-flaky-export classes finished clean on re-run: gist now goes
  9 win · 2 loss vs ripgrep across all 11 probe classes (up from 8/3
  pre-rewrite),
  and edges out zoekt on cold-query geomean (1.09×) for the first time — the
  accompanying prose numbers throughout the Benchmarks section were updated to
  match.
- Reworked Layer C from an overstated saturation claim into a matched roofline
  ladder that separates pure-read bandwidth, dual-window instruction/load cost,
  contiguous production scanning, and corpus fragmentation. The certificate now
  calls 35% of the measured DRAM roof material headroom and requires 80% before
  reporting a near-roof result.
- Scrubbed the last project-specific hardcoding out of the kernel for OSS-clean
  defaults. The artifact home is `GIST_DIR`-relocatable (default
  `.gist`; every derived path — index, atlas, shelf, anchor,
  daemon socket — resolves through `corpus.outDir()` / `corpus.ArtifactPath`,
  and the Python/Rust bindings honor the same env). The skip-dir policy is now
  generic-only: `derived-out` left the comptime baseline (34 cross-ecosystem
  names — VCS, package caches, build output), and per-tree extras ride
  `GIST_SKIP` (env, `:`/`,`/space separated) or `<GIST_DIR>/skips.list` (one
  name per line, `#` comments) — both scope only the corpus walks (index build,
  freshness, relate); rg-mode search keeps pure gitignore parity and ignores
  them. A consuming monorepo seeds its own `derived-out` into `skips.list` at
  install time.
  The bench harness follows suit: `_compete.sh`/`multipattern.sh`/`race.sh`
  resolve their corpus scope via `GIST_ROOTS` → published-corpus roots when
  present → the whole tree, mirroring `corpus.resolveRoots`.
  (see also: relate)
- Stop loading the persisted trigram index when every positional root is an
  explicit regular file (`gist PAT file.txt`, or several named files). The
  index
  answers exactly one question — _which of the WALKED files can't match, so
  skip
  reading them_ — but a named file is read no matter what the trigrams say, so
  loading + decompressing the index and reading the freshness anchor was pure
  launch-time tax that only a directory walk ever amortizes.
  `indexElisionWanted`
  now stats each root up front (one syscall apiece, dwarfed by the load it
  avoids) and declines the oracle when all roots are regular files; the mixed,
  directory, and implicit-CWD-walk cases keep it unchanged. The companion
  `file_needle` whole-file presence gate is likewise dropped for a lone
  explicit
  file, where it only re-faulted the body the mode's own scan already reads.

  Output-neutral by construction — index elision only ever ELIDES reads that
  provably can't match, so reading the named file instead changes cost, never
  results (`--files-without-match` still lists a no-match named file either
  way).
  `bench/rgsuite` `run.py` stays 409/409 on both engines.

  Measured on a 48 MB single-file corpus (warm page cache, resident daemon
  off),
  gist vs `rg` — the index-load tax was ~1.5 ms of every explicit-file query:

  - `-c pgvector` (sparse): rg was 1.29× FASTER → now gist **1.80×** faster.
  - `pgvector` matches (sparse): rg was 1.32× faster → now gist **1.77×**
  faster.
  - `-c CREATE` (dense): **2.33×**; plain matches **2.01×**; `-n` **1.88×**.
  - `--json` clears the same bar it did on the walk: single-file dense
    **5.26–6.60×**, 48 MB sparse **~1.98×**; repo-wide **3.17–4.22×**.

  Startup-bound tiny/sparse single-file queries stay below 2× because there the
  whole cost is the OS process spawn both tools pay identically — and gist's
  cold
  start is now already under `rg`'s (`--version` 1.6 ms vs 2.1 ms; tiny-file
  search 1.9 ms vs 2.8 ms, **1.49×**).
- The Python binding now exposes PCRE2/automatic engine selection, multiline
  and Unicode matching semantics in `SearchRequest`; typed index and capability
  lifecycle APIs; and daemon/session/index generations on reusable sessions.
  Structured-match parity now covers complete records, while rank correctly
  reflects the engine's live fallback when no index exists.
- The Python binding now imports as irregex and exposes search and kinship
  through one package-wide API; the Gist and Relate CLI identities remain
  unchanged.
- The benchmark + differential-parity oracle is now **ripgrep 15.2.0**
  everywhere (local `rg`, the pinned `upstream/ripgrep` checkout, every
  doc/count/comment). Re-mining 15.2.0's `tests/*.rs` grew the self-contained
  spec from 441 → **446** invocations, and `gist rg` clears the whole supported
  surface at ripgrep's own assertion bar on both walk engines: **409/409 =
  100%** (0 ORDER, 0 FAIL, 16 NA, 21 SKIP). Two miner-fidelity fixes keep the
  score honest and deterministic rather than papering over 15.2.0's new cases:

  - **Comparison-bar classification** now mirrors the macro a block asserts
  stdout with: a block that never byte-asserts (`eqnice!`) but checks output
  via `assert!(got.contains(…))` is order-agnostic, like
  `eqnice!(sort_lines(…), …)`. This fixes 15.2.0's new multi-directory
  ignore-order tests (#3320/#3376, `ignore_git_multi_root_order` /
  `ignore_rgignore_multi_root_order`) and the `f411`/`r2944` probes, whose own
  bar is substring presence, not byte order — holding them to byte-exact
  spuriously flapped PASS↔ORDER on the genuinely nondeterministic parallel
  walk.
  - **Unreproducible fixtures are SKIP, not scored.** A record whose fixture
  the miner could not fully build (a non-empty `skip` on an otherwise-`ok`
  record) is credited out-of-band instead of diffed against an incomplete tree.
  This claims 15.2.0's `r3275_git_global_config_env` (#3275,
  `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM`): its determinism rides a
  `format!`-built config embedding a run-time absolute `excludesFile` path the
  self-contained spec can't template — and, materialized or not, it is the same
  design boundary as `r3179` (global/machine-external git config is state a
  monorepo locator must not read), so gist declines it by design.

  Verified by `python3 bench/rgsuite/run.py` (both engines, stable across
  repeat runs), the strict `bench/rgsuite/check_results.py`, and `zig build
  test`.
- The flags agents reach for most get hot-path rewrites, each byte-identical to
  before (rg parity re-proven end-to-end, plus a per-function self-check).
  `-n`: line/column/byte-offset formatting drops `std.fmt.bufPrint("{d}")` for
  a specialized two-digit-table itoa (`writeDecimal`) on the
  one-call-per-emitted-line prefix path — ~2× the integer→decimal throughput.
  `-v`: the no-context invert emit no longer routes through the full
  match+context two-pass (an `idx` list, a `lines.len` match bitmap + memset, a
  `windowStart` re-walk, and an always-0 `firstCol`); a one-pass `invertPlain`
  streams every gate/engine-rejected line straight out — ~+20% invert-emit
  throughput. `-i`: the caseless SIMD gate now folds via bit 5 (`b | 0x20`)
  with a per-anchor mask (`0x20` for a letter, `0` for a non-letter — so
  non-letter anchors stay exact with no spurious survivors), collapsing the old
  four-compare/two-OR window to two ORs, two compares, and a single mask
  reduction. The enumeration + replace emits follow the same "drop the format
  machinery on the per-file hot path" pattern: `-l` (`emitPathOnly`) and
  `-c`/`--count-matches` (`bufTally`, now via `writeDecimal`) replace their
  bare `"{s}{s}"`/`"{d}{s}"` `print` calls with raw appends, and the
  `-r`/`--replace` template expander (`expandInto`, the path grep-muscle-memory
  `-rn` actually lands on — ripgrep parses `-rn` as `--replace=n`) copies each
  literal run between group refs in one `appendSlice` instead of a byte at a
  time.
- The warm resident session (`src/runtime/session/resident.zig`) and the cold
  CLI (`src/runtime/cold/engine/serial.zig`) now share the compiled-query core
  instead of each re-deriving it: resident's inline
  `Matcher`/`fileMatches`/`countLines`/`escapeLiteral` and its literal-vs-regex
  candidate dispatch collapse into one `answer` over
  `engine.query.CompiledQuery`, and the cold `trigramFilter` prunes by the same
  `regexPrefilter` (required literal, else alternation cover) — so warm and
  cold cannot drift on which literals are safe to prune by or on what matches.
  `session.request.Mode` now aliases the engine's `Mode`, unifying the
  classifier, wire protocol, and compiled query on one enum. Behavior is
  unchanged (resident parity, read-your-writes, and deletion tests stay green).
  (see also: irregex)
- Tighten Python/Rust gist bindings and session protocol; refresh bench/certify
  READMEs and search_api contract after the CSR index rewrite.
- Tighten the `--json` record encoder's per-record hot path — three
  output-identical shaves that compound across a match-dense stream:

  - **Path object cached once per file.** A file's `begin`, every `match`/
    `context`, and its `end` all repeat the identical path; each record was
    re-running full UTF-8 validation + the SIMD string escape on it. `pathData`
    now encodes the `{"text":…}`/`{"bytes":…}` object once and every record
    appends the cached bytes — O(1) path work per file instead of O(records).
  - **Hand-rolled unsigned integer writer** (`writeUint`) for the four
    per-submatch integers (`line_number`, `absolute_offset`, `start`, `end`),
    shedding `std.fmt.format`'s writer-vtable indirection on the hottest
  fields.
  - **ASCII fast-path for the string encoder** (`asciiOnly`): a SIMD high-bit
    scan proves valid UTF-8 without the full validator (ASCII ⊂ UTF-8) for the
    overwhelmingly common all-ASCII line/path/match span.

  Byte-identical to ripgrep by construction — `bench/rgsuite` `run.py` stays
  409/409 on both engines, and a `sort -u` set-compare of the normalized record
  stream matches `rg --json` across sparse/dense/`-n`/multi-word patterns.

  Measured on a 48 MB single-file corpus, gist vs `rg --json` (fresh process,
  resident daemon off): dense `id` **7.74× → 8.19×**, `NOT NULL` 6.60× →
  **6.84×**,
  `CREATE` 5.26× → **5.56×**, sparse `pgvector` 1.95× → **2.06×**. Repo-wide
  `--json` stays **3.2–4.2×** (walk-bound: it still rides the cold parallel
  walk,
  not the warm resident index — the remaining structural lever).
- Two changes that let the parallel engine win the high-hit path-list race
  (`\w{3,8} -l` — the dense-class trigram blind spot where nearly every file
  matches) on Linux, where cheap `open`/`mmap` had left gist scaling-bound
  behind ripgrep. **(1) Coalesced path-list output.** `-l`/`--files` used to
  take the shared sink mutex and issue a raw `write(2)` per matching file; a
  scan that lists ~every file (20k on the whole-repo corpus) therefore
  serialized every worker behind one lock and syscall storm — the parallel
  `\w{3,8} -l` walk scaled only ~1.4× from 1→6 workers. Each worker now batches
  its `path+terminator` records into a private ~64 KiB buffer (`bufferPath`)
  and flushes them in one locked `Sink.emitFilesChunk` write, so the
  lock+syscall is a per-chunk cost, not per file. Output stays contiguous per
  worker and order-free by the files-list contract (the rgsuite harness already
  treats path order as a soft diff), and the batched match count is byte-exact
  — `-l` file count equals `-c`'s nonzero-file count, and the emitted set is
  identical across 1/6/16 workers. **(2) OS-aware worker topology.** The
  six-worker ceiling (and its selective-run halving) is a macOS mitigation —
  there the walk serializes in the kernel on the `vm_map` fault lock over the
  mmap'd content shard and on syspolicyd/vnode locks at `open`/namei, so past a
  small pool more threads only add contention (measured flat 6→16 on the shard
  path, slower on the open path). Every other OS has a scalable fault + open
  path and ripgrep saturates all logical CPUs, so `defaultWorkerCount` now
  returns `ncpu` off macOS instead of idling more than half the cores on an
  8-core/16-thread box. macOS behavior is unchanged; `GIST_WORKERS` and `-j`
  still override.
- Two serial floors sitting UNDER the already-parallel cold read are gone. (1)
  `readCandidates` now BORROWS each kept file's body straight from its shard
  arena instead of serially duping the whole kept corpus into the query arena —
  the read arenas ride to process exit (the cold engine is one-shot: `run` owns
  a single query arena and every terminal path `std.process.exit`s after emit),
  deleting a ~½-GB single-threaded memcpy for zero copies. (2) `fileMatchStats`
  (the `--stats` tally) gained the required-literal SIMD gate every other mode
  already used: a body or line without the literal every match must contain
  holds zero matches, so one `contains` replaces a full NFA sweep of it. Output
  is byte-identical throughout (verified against pre-change references and
  serial↔parallel). Measured on this corpus (`--no-index`): `--stats 'fn '`
  dropped 340 → 133 ms parallel and 652 → 157 ms serial (4.2×), and the copy
  removal shaves ~25–30 ms off every full-read mode.
- `--sort`/`--sortr path` now rides the fused parallel walk instead of the
  serial engine. The streaming sink can't globally order, so ordered runs
  previously fell to the serial path — a single-threaded gather walk plus a
  concurrent index-freshness walk that traversed the tree twice, leaving `gist
  -l --sort path` ~1.6x SLOWER than ripgrep 15.2 (the redundant freshness walk
  cost more than the index it validated saved). Workers now hold each rendered
  fragment in their arena keyed by path (already arena-lived, so zero copies)
  rather than racing it to stdout, and `run` orders the whole result once
  (`emitSorted`) — a parallel walk+read+match+inline-index-elision feeding one
  final sort. The ordered emit replays through the SAME `Sink`, so
  heading/context separators and the matched-files exit code stay
  byte-identical to the serial oracle, just sorted. Ascending path takes
  `serial.pathLess` (rg's `Path::cmp`, valid for single/implicit root where
  rg's per-argv-root walker order collapses to it); descending is the global
  mirror for any root count. Time keys (modified/accessed/created), `--files`,
  `--json`, and multi-root ascending stay on the serial engine. Result: a
  `gist -l --sort path` search for a high-match symbol went from 935 ms to 36
  ms — **34.8x faster**
  than rg 15.2 (content `--sort path` 26x); non-sorted paths and the stat-only
  `--files --sort` listing are unchanged.
- `--stats` and `--files-without-match` now ride the fused parallel walk
  instead of the serial collect-then-shard path. Both were hard-declined by
  `eligible` (cross-file tally / inverted success predicate), so they paid a
  single-threaded gather walk plus a sharded emit — leaving `gist --stats` /
  `--files-without-match` ~1.5× slower than ripgrep 15.2 on the Linux corpus.
  Workers now own the modes directly: `--files-without-match` is the invert of
  `-l` (emit on a miss; index elision _is_ a miss → emit without reading; the
  `fast_l` prefix proof skips the tail without emitting when a match is already
  settled), and `--stats` streams the match body like any content mode while
  summing a per-worker `grepfile.Stats` into one trailing block (same fold
  shape as the `--json` summary — `files_with_match` / `bytes_printed` stamped
  from the sink after join). A whole-file gate miss still tallies a zero-hit
  searched file (binary cutoff via `committedPrefix`), so the stats block stays
  byte-identical to the serial oracle. Result on the Linux corpus vs rg 15.2:
  `--stats` 919 ms vs 2.13 s (**2.3×**), `--files-without-match` 997 ms vs 2.04
  s (**2.0×**); `-l` and the sorted fused path are unchanged.
- `relate patterns` now index-elides its reads: when every pattern yields a
  sound trigram prefilter and the roots sit inside the indexed corpus, it
  unions per-pattern candidates through the persisted index (freshness-widened,
  root-scope gated before the read) and attributes only those files in parallel
  shards — the same elide-only contract as the single-pattern engine, identical
  answers proven against the `gist -l` oracle. The 10-pattern relocator-shaped
  slate on the live corpus drops from ~1.2 s (10× sequential `gist -l`) to ~195
  ms attributed (`bench/races/multipattern.sh`), ~6× faster with attribution
  the fused alternation cannot give at any speed.

### Fixed

- (in `irregex`) **Finished the search-engine unification the previous entry started.** The…
- Benchmark harness now fails closed on hard errors, and the crate's
  parity/certificate claims are reconciled with the committed artifacts.
  `bench/races/_compete.sh` (`hf_mean`), `bench/certify/certify.sh`
  (`bench_one`, which also had a trailing `|| true`), and
  `bench/gates/scan_regress.sh` masked non-zero exits: the `{ … ; } 2>&1 | wc
  -l` drain neutralized a needle-miss exit 1 _and_ a hard failure (exit ≥ 2 —
  unknown flag, crash, bad regex, unreadable path), so hyperfine could time a
  failure path as a fast search; and `scan_regress`'s warm-up ran the fresh
  binary against a non-matching needle behind a trailing `true`, so a failed
  rebuild (exit 1, indistinguishable from the no-match) was papered over and a
  stale binary got benchmarked. All three now pre-check the real exit code (0/1
  valid, ≥ 2 hard-fails the cell; a gist failure aborts the certificate) and
  the scan-regress warm-up uses the non-running default install step so a build
  failure is unambiguous. Separately, `README.md`, `bench/rgsuite/README.md`,
  and `--schema`'s `flag_surface` are corrected to match the committed
  `results.json`: supported-surface parity is **98.6% (275 PASS / 3 ORDER / 4
  FAIL / 38 NA / 121 SKIP)**, not zero-FAIL; the "byte-for-byte drop-in" /
  "every rg flag keeps working" / reproducible "9 win · 2 loss" / "30.1 MiB
  smaller than csearch" claims are scoped to the supported surface (with the
  raw certificate still uncommitted); the file-set (`equality.sh`) vs
  line-output (`rgsuite`) gate distinction is made explicit; and the freshness
  guarantee is stated under its local-filesystem assumptions.
- Certificate assembly now copies Crest's canonical raw aggregate into the
  release bundle instead of expecting the obsolete output path.
- Closed the last supported-surface divergences between `gist rg` and ripgrep
  15.2.0: the mined differential suite now scores **409/409 = 100%** on _both_
  walk engines (parallel and serial), zero FAIL, zero deferred entries.

  - **`--include-zero` / `--no-include-zero`** (last-wins) are honored across
    `-c`/`--count` and `--count-matches`: a searched file with no match now
  emits
    its `path:0` line like rg, so the two flags round-trip. Zero-count output
    disables the whole-file match gate and index read-elision (a file provably
    without a match must still be _named_), and the request is routed to the
    serial engine so every candidate is accounted for; exit status stays 1 when
    nothing matched.
  - **NUL-bearing patterns** are rejected under default binary detection
  exactly
    where rg's `regex::ban` rejects them — a pattern that _literally_ contains
  a
    NUL byte (`Regex.bansByte`: a singleton `{0}` consume state), not one that
    merely _can_ match NUL (`.`, a range) — while `-a`/`--text` and
  `--null-data`
    still allow it. The ban rides the linear engine only; PCRE2 (`-P`) keeps
  rg's
    PCRE2 semantics.
  - **Inline `(?-m)` / `(?s)` under `-U`** now reshape whole-buffer matching:
    multiline mode and the `^`/`$` line-anchor behavior are tracked separately,
  so
    `gist -U '(?-m)…'` anchors to the buffer and `(?s)` lets `.` cross
  newlines,
    matching rg instead of being silently inert.
  - **PCRE2 whole-buffer multiline lookahead** — `(?s)alpha(?=.*bar)` and
  friends
    operate over the entire multiline buffer in normal, count, and files-only
    modes (JIT and interpreter agree), locked by adverse backend tests.
  - **Ancestor-ignore parity**: ignore files in the directories _between_ CWD
  and
    an explicitly-named positional root are now loaded
  (`Ignore.loadRootAncestors`,
    rg's `add_parents`), an escaped trailing slash (`foo\/`) marks a rule
  dir-only
    without leaking the backslash into the glob, and a leading `**/` in an
  anchored
    ancestor rule floats depth-independently instead of being stripped.
  - **`--schema` authority** advertises the real flag catalog at
    `src/exec/cold/argv/args.zig:flag_catalog` (was a stale
  `runtime/cold`
    path), proven by a compile-time `@embedFile` assertion so it cannot drift
  again.

  Verified by `python3 bench/rgsuite/run.py` (both engines), the strict
  `bench/rgsuite/check_results.py` (no `--allow-fail`), and `zig build test`.
  (see also: irregex)
- Fixed a drift risk between Layer A (`certify.zig`) and Layer D
  (`lowerbound.zig`) of the Certificate of Optimality: the eleven probe-class
  definitions were hand-duplicated across the two files. Extracted them into a
  single shared `bench/harness/probes.zig` module both layers import, so the
  certificate's layers can no longer silently diverge. Also wired Layer C
  (roofline) and Layer D (lowerbound) into `build.zig` as `zig build
  roofline`/`zig build lowerbound` (previously unwired source with no
  executable target) and added the Layer B probe-vs-production differential
  test to `zig build test`.
  (see also: irregex)
- Index publish is now generation-atomic (`gens/<id>/` + `pair.gen`) so
  concurrent
  loaders never observe a mixed `index.gist`/`paths.list` pair; persist tests
  cover
  torn-stage and concurrent-load regressions. Certificate provenance requires
  `machine.git_commit ==` clean HEAD (`check_artifacts.py --require-head`); the
  committed artifact is stubbed pending republish. README parity language no
  longer
  counts ORDER as byte-identical, and documents `--sort`/`--sortr` as
  accepted-but-ignored.
- Index-elision parity now compares the byte-exact line multiset, preserving
  duplicate and content checks without treating the parallel engine's
  worker-discovery order as semantics. Daemon socket tests now always send
  shutdown before joining, and the wedged-daemon regression proves timeout
  causally through a short test-only deadline instead of scheduler-sensitive
  wall-clock bounds. Full certificate cells retain diagnostics and retry once
  from scratch after a transient tool failure, while persistent failures remain
  excluded and visible. The full A–D mint again builds its k-NN lab and takes
  the documented non-PMU fallback when sudo is disabled. Its docs now bound the
  claim to cold exact search and measured ripgrep dominance, distinguish
  wider-field context and exploratory dirty runs from publishable evidence, and
  generate citations to the current production kernels.
- Keep the fail-closed certificate freshness check resilient to Markdown
  wrapping.
- Make indexed lint searches worktree-safe and harden safety gates.
- Restore the trailing newline on bench/rgsuite/results.json so the
  editorconfig gate passes.
- Serial-engine `-l`/`--files-with-matches` no longer lists binary files
  (Mach-O, `.png`, `.dmg`, `.pak`) that ripgrep and the parallel engine
  correctly reject. Root cause: `grepfile.emitRegion` rendered a binary file's
  committed prefix through `Emitter.file`/`buffer`, but left the emitter's
  `[base, body_end)` window on the WHOLE body — so the fused `-l` doc-match
  read past rg's NUL cutoff and matched bytes in the discarded tail
  (`-c`/`-o`/plain/`--stats` were unaffected: count is suppressed earlier and
  the others render the `lines` slice). `emitRegion` now re-points the window
  at exactly the rendered region — an empty committed prefix collapses
  `body_end == base`, disabling every fused path. The evaluator's 12-class
  `parity_lane` now passes 12/12 on both the parallel and serial
  (`GIST_NO_PARALLEL`) engines; the shared fix also closes the same latent hole
  for tail-NUL binaries on the parallel engine, and the `walked -l` regression
  test now sets the emitter window production-identically so it guards against
  a recurrence.
- The compact enumeration modes — `-l`/`--files-with-matches`, `-c`/`--count`,
  `--count-matches`, `--files-without-match`, and `--files` — are now exempt
  from the soft ~25k-token context cap (only the hard OOM ceiling remains), so
  they return the COMPLETE, reproducible set. The parallel work-stealing engine
  emits in worker-discovery order (intended rg-parity, an ORDER-bucket soft
  pass), and truncating that unordered stream at the soft cap silently returned
  a nondeterministic SUBSET of files run-to-run — the same `gist -l foo`
  yielding different results each invocation (e.g. 1692/1694/1692 lines), which
  breaks caching and agent reproducibility. It also made the truncation
  notice's own "try `-l`/`-c`" advice hollow. The full-content modes (default,
  `-o`, context, `--json`) keep the cap — their volume is its reason, and their
  truncation is already ordered — and an explicit `GIST_MAX_OUTPUT_TOKENS` is
  still honored as a deliberate opt-in bound. Applied to both the cold engine
  (`serial.run`) and the warm client (`tryWarm`) so the two never disagree on
  which files `-l` returns; a new `Opts.enumeration` predicate carries the
  parser-contract test, and `corpus.exemptSoftCap` lifts only the default
  guard.
- The parallel engine's end-of-walk elision drain no longer forfeits the
  crest/trigram prune when the loader lands a hair late.
  `flushPending(final=true)` sampled `LazyElide.ready` once and, if the
  concurrent oracle hadn't finished, re-read the _entire_ deferred backlog with
  that stale verdict — the cold-page-cache race, where the fast metadata walk
  defers every file before the 39 MiB index has faulted in from disk, so a
  broad selective scan (`[0-9a-f]{8}`, sieve-pruned 94%) collapsed to a full
  read (~1.0× vs `--no-index`) even though the oracle became ready microseconds
  into the drain. The drain now re-polls `ready` per file, so a loader that
  loses the walk by a whisker still elides the long tail instead of reading it:
  once the flip is observed, every remaining unchanged non-candidate is
  skipped. It never idles (the rejected alternative — blocking on the oracle —
  measured 1.5× slower on warm `libs`-sized scopes), so the page-cache-warm
  path is untouched (the re-poll branch is inert when the oracle is already
  ready), and the result set stays byte-identical to `--no-index` (elision
  soundness is timing-independent — `Elide.skip` still refuses any file the
  build anchor can't prove unchanged). Measured on a cold-simulated drain (100
  ms oracle load, disk-bound reads): 319 ms → 198 ms (1.61×), recovering the
  same prune win the serial engine already banked; a truly cold page cache
  lands the oracle even earlier in the long disk-bound drain, so the recovered
  fraction is larger.
- The parallel fused engine now takes the line-free literal fast path
  (`Emitter.fileLit`) for every eligible per-file emit, not just `-l`. Its only
  short-circuit was `fast_l` (files-only); a pure-literal
  `-c`/`--count-matches`/`-o`/`-n`/plain query fell through to `collectLines` +
  `Emitter.file`, so each worker split every candidate into a line array and
  ran the per-line engine — even though a literal carries no `\n`, making
  candidate line ⟺ matching line and the engine redundant. `emitBody` now
  mirrors the serial engine's per-file dispatch exactly: when `!multiline and
  litFastEligible()` it runs `fileLit` (rg's candidate-jump searcher —
  `indexOfAnyPos` hit→hit, line bounds via memchr, count without the Pike VM)
  and skips the line split entirely; the fast path's guards already exclude
  context/invert/passthru/replace/stats, so output stays byte-identical
  (oracle-gated against ripgrep in the cold `-c` race). This closes the regime
  where the trigram index can't prune (ubiquitous literals like
  `func`/`import`/`})`): the count lane went from ~3.8× the CPU of the list
  lane — losing to rg at ~0.6× — to parity with it, so on the 20-core ext4
  Anvil box `gist -c` now beats rg cold 4/4 at 1.2× geomean (`func -c` 52.8 ms
  → 26.6 ms) instead of losing.
- Use Python 3.14 multi-exception syntax in the warm-tier report helper.
- `bench/rgsuite/run.py` now writes `results.json` with a trailing newline, so
  a suite re-run no longer regenerates the editorconfig final-newline violation
  the earlier one-off file fix papered over.
- (in `irregex`) `gist --rank` now honors ripgrep's default binary-file policy, so the ranked…
- `index_size_accounting.py` now emits schema_version 2 (`posting_bytes` /
  `path_bytes` / `freshness_bytes` / `required_bytes` / `workspace_bytes` +
  `required_files`), matching `check_artifacts.py` — certificate/verify outputs
  stay in `workspace_bytes` and no longer inflate the cache total. Unblocks
  publishing a HEAD-bound certificate bundle.

## [0.1.0] - 2026-07-01

### Added

- **Bench harness** (`bench/bench.zig`): real-corpus build/footprint, on-disk
  persistence timing, and full-pipeline (filter+verify) latency p50/p95/p99 for
  an adversarial slate. gist beats ripgrep on every query over the identical
  corpus (5.7× worst case → ~140,000× for a rare miss).
- **Equality oracle** (`bench/equality.sh`, `bench/bench.zig` `verify` mode):
  gist emits its verified matching-file set per pattern + the exact indexed
  file
  list; the script runs `rg` (and `rg (?-u)` for regex) over that identical
  list
  and diffs. Proven over 16,509 files / 125 MiB: 945 adversarial+random
  literals
  (3 seeds) + 88 regexes → **zero false negatives, zero false positives**.
- (in `irregex`) **Latent Pike `.skip` soundness fix** (`src/regex.zig` `eol_empty`). The DFA…
- (in `irregex`) **No-prefilter regex → direct live-tree scan** (`bench/scan.zig`, dispatched…
- (in `irregex`) **Regex scan accelerators** (`src/regex.zig`, split into…
- **Second baseline: `ag` (the_silver_searcher)** in all three race scripts
  (`bench/headtohead.sh`, `coldquery.sh`, `regex_headtohead.sh`) — a new
  `ag … column`, an `rg≷ag` direct-matchup column, and an "ag faster than rg on
  N/M" tally. `ag` runs on its honest fastest path: `--path-to-ignore
  .gitignore`
  hands it the root ignore set `rg` reads for free (its own walk reads ignore
  files only *inside* the search paths, so without it `ag` grinds through the
  gitignored ~99 GB — 0.46 s scoped vs minutes unscoped). Columns auto-skip if
  `ag` is not installed. Measured over 37 queries (17.1k files): `gist` wins
  all
  but one; `rg` beats `ag` on **36/37** (`ag` ~1.6–2.1× behind on every
  literal,
  warm + cold, and 15/16 regexes). `ag`'s lone win is the prefilter-less 2-byte
  mixed alternation `panic|0x` — `ag` 483 ms vs `rg` 675 ms (**1.40×**), the
  same
  pattern where gist's Pike VM is weakest (1173 ms).
- **Seven-tool competitive field + indexed rivals** (`bench/_compete.sh`,
  rewritten `coldquery.sh` / `regex_headtohead.sh` / `headtohead.sh`): the race
  now spans every level. Beyond the unindexed scanners (`rg`, `ag`, plus new
  `ugrep`, GNU `grep`, `git grep`) gist is benched against the two mature
  *indexed* searchers — **csearch** (Russ Cox's Google Code Search, gist's
  direct
  trigram ancestor) and **zoekt** (Sourcegraph's production indexed search). A
  shared `_compete.sh` registry defines the field, the per-tool fastest-honest
  invocations, and the index builds; csearch indexes gist's **exact** corpus
  file
  list (`paths.list`) for an apples-to-apples trigram-vs-trigram race, zoekt
  the
  roots tree under the heavy ignore set. Output adds geomean-speedup + win-rate
  summaries (split indexed/unindexed) and per-race CSVs. Two correctness fixes
  in
  the harness: every command's output is drained (`… | wc -l`) so ugrep's lazy
  multithreaded `-l` actually scans (it short-circuits when stdout is
  discarded)
  and a needle miss (grep exits 1) no longer aborts hyperfine.
- (in `irregex`) **`rg --json` emits ripgrep's JSON Lines record stream — was a fail-loud…
- (in `irregex`) Initial scaffold mirroring the sibling kernel packages' conventions: `build.zig`…

### Changed

- **Benchmark certify harness (`bench/certify.sh`) reformatted** to the repo
  shell style (2-space indent, one statement per line) and the macroscopic
  probe loop straightened so each class benches `gist` plus every competitor in
  a single pass. No change to the emitted `CERTIFICATE.md`, the macro CSV, or
  the bootstrap-CI / Mann-Whitney stats path.
- (in `irregex`) **CLI collapses six competitor-shaped verbs into three real ones, on a native…
- (in `irregex`) **Cold / first-query win** (`bench/cli.zig`, `bench/coldquery.sh`): a…
- **Data-parallel verify** (`bench/bench.zig`): candidate verification and the
  <3-byte full-scan fallback fan out across 16 threads with **byte-balanced**
  sharding (equal bytes per thread, not equal file count — a few large files
  can't stall one worker while the rest idle). `func(` 14.9 ms → 3.1 ms, `func`
  12.0 ms → 3.7 ms, `})` full scan 59 ms → 7.2 ms.
- **Head-to-head harness** (`bench/headtohead.sh`): gist warm p50 vs `rg`'s
  *fastest* mode (native parallel walk, warmed, hyperfine median-of-8) per
  query.
  gist wins **every** query **47.6×–58,000×** (worst case the 2-byte `})`
  full-scan fallback at 47.6×).
- **Race-free oracle** (`bench/equality.sh`, `verify` mode): the corpus is
  regenerated live by coworker agents, so reading a file once for gist's index
  and again for rg could see two versions (it did — a transient `\w+Request`
  "mismatch" on a file regenerated mid-run). `verify` now dumps a **byte-exact
  snapshot** of the indexed bytes and points rg at the snapshot, so any diff is
  a
  real semantic disagreement. Re-proven: **660 literals + 176 regexes across 4
  seeds, 0 FN / 0 FP**.
- (in `irregex`) **The engine now lives entirely under `src/`, split into concern-scoped…

### Fixed

- (in `irregex`) **Query results now go to stdout, diagnostics to stderr** (`bench/cli.zig`,…
