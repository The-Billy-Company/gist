# gist ⇄ ripgrep drop-in proof (`rgsuite`)

This is the honest, reproducible measurement of how close gist's `rg` verb is to
a **drop-in ripgrep** on the surface it claims to support (currently **100%
supported-surface parity** — every replayed supported-surface case matches
ripgrep, with zero deferred divergences — see the scoreboard), benchmarked against real ripgrep as both
the **correctness oracle** and the **performance baseline**.

That parity figure is scoped to a denominator **ripgrep owns**: the tests it
wrote and the flags it documents. The [fuzz companion](#fuzz-companion-fuzzpy--invocations-nobody-wrote-down)
exists because that is also the ceiling of a curated denominator — it can only
hold cases someone already thought of — and it generates invocations nobody
wrote down. It still finds a small residual; that tail is carried, per root-cause
class, in `fuzz_baseline.json` and in Layer I of the certificate, and it is
ratcheted shrink-only rather than rounded off.
`run.py` replays the whole suite once per **engine** — the parallel
work-stealing walk (`pipeline.zig`, gist's default recursive-walk dispatch)
and the serial fallback (`run.zig`, forced via the internal `GIST_NO_PARALLEL`
knob) — since the two share the walk/ignore/emit machinery but not the same
code path, and a single-engine run has already once missed a real regression
(see "Two engines, one suite" below). Two tracks:

- **Track A — correctness.** Replay ripgrep's _own_ integration suite
  (`upstream/ripgrep/tests/*.rs`) against `gist rg` and diff byte-for-byte vs the
  installed `rg`. No hardcoded expected strings — ripgrep is the ground truth.
- **Track B — performance.** Race gist's indexed query path against `rg` (and
  ugrep / ag / GNU-grep / git-grep / csearch / zoekt) on the live monorepo.
  Scripts live in the sibling `races/` folder: `../races/coldquery.sh` (fresh
  process) and `../races/headtohead.sh` (warm resident index).

## Track A — correctness scoreboard

`rg 15.2.0`, 446 mined `rgtest!` cases (invocations; a multi-command `rgtest!`
mines one case per command), replayed against **both** engines:

| Bucket    | parallel (`pipeline.zig`) | serial (`run.zig`) | Meaning                                                                         |
| --------- | ------------------------: | -----------------: | ------------------------------------------------------------------------------- |
| **PASS**  |                       411 |                411 | `gist rg` stdout == `rg` stdout **at the mined test's own bar** (see below)     |
| **ORDER** |                         0 |                  0 | a byte-exact (`eqnice!`) case differing only in line order — a real hole        |
| **FAIL**  |                         0 |                  0 | a supported-surface divergence, each phase-tracked in `coverage_manifest.toml`  |
| NA        |                        14 |                 14 | unsupported **by design** (see boundaries below)                                |
| SKIP      |                        21 |                 21 | not replayable as one argv — each mapped to a companion proof / upstream reason |

**Supported-surface parity = (PASS+ORDER) / (PASS+ORDER+FAIL) = 411/411 = 100.0%
on both engines** — identical on whichever engine a given case dispatches to.
There are zero FAILs and zero deferred divergences: every supported-surface case
is replayed and matches ripgrep byte-for-byte. Together the 446 mined obligations
account completely — every case is replayed (PASS/ORDER/FAIL/NA) or claimed by
exactly one manifest entry (SKIP) — and `check_results.py` fails the build on any
orphan skip, double credit, undeferred FAIL, undocumented divergence, or README drift.

### Complete obligation accounting (no misleading denominator)

The 446 mined `rgtest!` obligations split into what the harness can drive against
live `rg` as one argv, and what it accounts for out-of-band in
`coverage_manifest.toml` (`tomllib`-parsed, gate-enforced):

- **411 replayed** — executed against real ripgrep and bucketed above
  (411 PASS + 0 FAIL); NA (14) are replayed too but fall outside the parity
  denominator as announced design refusals.
- **21 SKIP, each claimed once** by a manifest entry: **companion** (the miner
  couldn't lower a control-flow `rgtest!` to one argv, but a sibling proof —
  `flags.py`/`modes.py`/`transforms.py` — drives the same flags byte-for-byte),
  **boundary** (a purposeful decline whose adverse test is the loud exit-2
  itself), or **irreplayable** (the mined JSON can't encode the case, e.g. a
  non-UTF-8 filename).
- **0 FAIL** — the deferred list is empty; the `rich-output`, `walk-scope`, and
  `hard-paths` divergences that once lived here are all closed and now PASS.

`check_results.py` is the anti-gaming gate: it rejects a SKIP no companion
claims, a case credited twice, a FAIL missing a `[[deferred]]` entry, a stale
deferral that no longer FAILs, a FAIL/NA row with an empty `detail`, and any
drift between this README, `results.json`, and the computed parity.

Each mined case carries its upstream assertion mode (`cmp` in `spec.json`):
ripgrep's own suite pins most cases byte-exact (`eqnice!`, `cmp=plain`) but
compares **sorted lines** (`eqnice_sorted!`, `cmp=sort`) exactly where rg's
parallel dir walk makes its own output genuinely nondeterministic (empirically:
`rg --files` on those fixtures yields many distinct orders across repeated
runs). `run.py` scores each case at its oracle's own bar — sorted-line equality
is a full PASS for a `cmp=sort` case (17 such cases today), while a `cmp=plain`
case that matches only after sorting stays ORDER: a real parity hole, and the
bucket is empty. A `cmp=sort` case records the **oracle**, never which side of
the coin one run drew: on `ignore_git_multi_root_order` both tools flip between
the two root orders across repeated runs (measured over 40 runs each: gist
24/16, rg 26/14), so whether a given run also happened to match byte-exactly
says nothing about gist — recording it would only churn a tracked
`results.json` on every re-run. The parallel engine still streams each hit the instant a
worker finds it (the same EPIPE-triggered cooperative cancellation ripgrep's
printer uses, so `gist foo | head` aborts the walk) — wherever rg's own output
IS deterministic (single-dir walks, `--sort*` modes, `--files` under one root),
gist reproduces it byte-for-byte.

### Two engines, one suite (why this isn't redundant)

`pipeline.zig` (the parallel engine) landed a day after a serial-engine-only
fix closed two rg-parity gaps (`-g`/`--iglob` override, unreadable-directory
walk-error reporting) — and inherited both bugs unfixed, because its own
ignore-chain (`Ignore.skipFromVerdict`) and directory-open path were written
fresh rather than reusing the serial engine's already-fixed code. Every
recursive-walk case in this suite dispatches to the parallel engine by
default (`pipeline.eligible`), so a single-engine run of this exact suite
would have stayed green through that regression — the FAIL only surfaces when
the suite is forced onto each engine explicitly via `GIST_NO_PARALLEL`. This
is now permanent: both `run.py` and the `bench/gates/{line_parity,
freshness_fs}.sh` gates replay their whole case list once per engine.

### Design boundaries (why NA is honest, not hidden failure)

An NA is only ever assigned to a case that would _otherwise_ diverge AND whose
divergence is attributable to one of gist's stated scope boundaries — never to
excuse an in-scope bug. gist **fails loud (exit 2)** on features it can't honor,
so an NA is a deliberate, announced refusal, not a silent wrong answer. The
current boundaries:

1. **own color palette** — `--color=always` paints gist's deliberate scheme
   (bright-red underline matches, dim separators — `color.zig`), not rg's
   default; a case whose ONLY divergence is the ANSI codes is NA, and rg's
   `--crlf`+color `\r` injection artifact is deliberately not replicated.
   (`-U`/`--multiline` is no longer a boundary — the mined multiline cases run
   and PASS; see the `modes.py` companion for the deeper `-U` proof.)
2. **text/source-oriented** — gist skips binary files; no `--binary`/`-uuu`, and
   it never emits ripgrep's `binary file matches` summary line.
3. **UTF-8 / byte engine** — matching runs over UTF-8 bytes, so `-E`/`--encoding`
   **transcodes to UTF-8 up front** rather than matching in the source charset. It
   now honors rg's full `encoding_rs` label table (the single-byte pages + CJK
   gb18030/GBK, Big5, EUC-JP, Shift_JIS, EUC-KR, ISO-2022-JP), a **UTF-8/UTF-16 BOM
   is auto-detected**, and an unrecognized label still **fails loud (exit 2)**.
   Byte-exact vs rg — see `transforms.py`. (No longer an NA bucket.)
4. **one compiled engine per run** — `-i` now folds Unicode at rg's own posture
   (**simple** fold, Unicode's `C+S` mappings, so `café`⇄`CAFÉ` matches on both
   tools and `ß`⇄`SS` matches on neither); `--no-unicode` reverts to ASCII
   bytes. What remains a boundary is per-branch `(?i)` across multiple `-e`
   patterns, since gist compiles one engine for the whole invocation.
5. **RE2-style engine** — `-P`/pcre2, lookaround, backreferences (mostly SKIP).
6. **ignore scope** — the in-repo hierarchy **and** the _global_ gitignore
   (`core.excludesFile`, resolved from `$HOME/.gitconfig` / `$XDG_CONFIG_HOME/git/config`
   → default `$XDG_CONFIG_HOME/git/ignore`) are honored by default, disabled per
   tier by `--no-ignore-global` (rg-parity proven in `flags.py`, below); fd's
   `.fdignore` dialect is the one ignore source still not read.
7. **type registry** — `--type-list` is now emitted in ripgrep's exact
   presentation (lexicographic names, one line per alias, lexicographically
   sorted globs); it differs only because gist's registry is a documented strict
   _superset_ of ripgrep's — every rg type + glob present (most rows therefore
   byte-identical), plus gist-only types and per-type enrichments.

### Surface gist matches ripgrep on (all PASS)

Filename display rules (implicit / `-H` / `-I` / `--no-filename`), line numbers
(`-n`/`-N`), `-i`/`-s`/`-S` case, `-w` word (true `(^|\W)…(\W|$)` semantics, not
`\b…\b`), `-F` fixed strings, `-v` invert, `-o` only-matching (incl. zero-width
matches of a nullable pattern), `-c`/`--count`, `--count-matches` (incl. the
`--count -o` override), `-l`/`--files-with-matches`, `-L`/`--files-without-match`,
`-A`/`-B`/`-C` context (incl. `-A/-B` precedence over `-C` and `--`/`:`/`-`
framing), `-m`/`--max-count`, `-M`/`--max-columns` (omit-long-line placeholder),
`-r`/`--replace` **with `$1`/named capture groups**, `-t`/`-T`/`-g`/`--glob`/
`--iglob` type & glob scoping (incl. `!`-exclude, leading-`/` anchoring, and
`{a,b}` brace expansion), `--type-add`, **`--json`** (the full JSON-Lines record
stream), the **git ignore hierarchy** (`.gitignore`/`.ignore`/`.rgignore`,
`.git/info/exclude` incl. linked worktrees, **ancestor/parent** ignores,
`--ignore-file` precedence, and every `--ignore-file`/`--no-ignore*`/`-u`/`-uu`/
`--require-git` tier), `--path-separator`, **UTF-8/UTF-16 BOM auto-detection**,
**stdin search** (rg's `is_readable_stdin` rule: pipe/regular-file yes,
tty/`/dev/null` no), **`-U`/`--multiline` frames** (cross-line spans, `--crlf`'s
CRLF-aware `$`, `--vimgrep`'s one-line-per-match rule (rg #1866), `-r` block
replacement that preserves the block's non-matching bytes (rg #1311),
`--passthru`, `--trim`+`-M` per-fragment placeholders), `--vimgrep`'s forced
filename, and rg exit codes (0 match / 1 no-match / 2 error).

## Track B — performance (18,635 files · 155.9 MiB corpus)

Measured with hyperfine, warm page cache. gist queries its persisted trigram
index (reads only candidate files); unindexed tools re-walk the tree each call.

**Cold — fresh process** (`../races/coldquery.sh`), geomean speedup, gist wins:

| vs       |  speedup |  wins |
| -------- | -------: | ----: |
| ripgrep  | **3.3×** | 11/11 |
| git grep |     2.4× | 10/11 |
| ag       |     5.5× | 11/11 |
| GNU grep |     9.9× | 11/11 |
| ugrep    |    13.0× | 11/11 |

Selective needles reach 4–6× vs rg (e.g. `pgxpool` 6.1×); ubiquitous tokens
(`func`, `})`) approach parity — gist must read the many candidate files they hit.

**Warm — resident RAM index** (`../races/headtohead.sh`), the agent-session model
gist is built for, geomean speedup, gist wins:

| vs       |    speedup |  wins |
| -------- | ---------: | ----: |
| ripgrep  | **~1770×** | 20/20 |
| git grep |     ~1400× | 20/20 |
| ag       |     ~2640× | 20/20 |
| GNU grep |     ~5460× | 20/20 |
| ugrep    |     ~6600× | 20/20 |

The honest headline: gist is a **drop-in rg (100% supported-surface parity on
both engines, with zero remaining divergences on the mined suite and a small
shrink-only residual on the generated-invocation lane)**
that is **~3.3× faster cold** and **~1770× faster warm-resident** than ripgrep —
the "40×" claim sits comfortably between the one-shot and resident models and is
conservative for gist's intended long-lived agent-session use.

## Running it

```bash
# build the binary the suite drives
zig build            # in this repo  → zig-out/bin/gist (the CLI, `rg` verb)

# Track A — correctness (needs `rg` on PATH as the oracle)
python3 run.py                # scoreboard; exits non-zero if any FAIL
python3 run.py --list-na      # also print every NA + its reason
python3 dbg.py <test-name>…   # side-by-side rg vs gist for one case

# Track B — performance
../races/coldquery.sh               # fresh-process race
../races/headtohead.sh              # warm resident-index race
```

`spec.json` is **self-contained** (every fixture byte base64-embedded), so
Track A replays without the ripgrep checkout. Regenerate it only when bumping the
tracked ripgrep:

```bash
python3 mine.py [path/to/ripgrep/tests]   # default: <repo>/.etc/ripgrep/tests
```

## Modes companion (`modes.py`) — the `-U`/`-P` proof

`run.py` mines ripgrep's own suite, which by design defers `-U`/`--multiline`
(boundary #1) and `-P`/`--pcre2` (boundary #6) to NA/SKIP. `modes.py` is the
hand-authored differential proof for exactly those two modes now that gist
implements them — same philosophy (ripgrep is the oracle, no hardcoded expected
strings), a curated adversarial matrix instead of a mined one:

```bash
python3 modes.py run --mode multiline   # -U: cross-line spans, blank-line skip,
                                        #     zero-width anchors, dotall, crlf, -o/-v/-c/-r/--json
python3 modes.py run --mode pcre        # -P: lookaround, backrefs, negative lookaround,
                                        #     possessive/atomic, unicode toggle, catastrophic→exit-2
python3 modes.py run --mode all         # + a `core` regression slice and repo-scale gross queries
python3 modes.py bench                  # acceleration hunt: gist-idx vs gist-noidx vs rg
```

Fixtures are generated into a temp dir each run (the generator in `modes.py` is
the committed contract — nothing large is tracked). It asserts three things per
case: stdout byte-parity vs `rg`, exit-code parity (0/1/2), and that gist's
indexed path equals `--no-index` (read-elision soundness). `--mode multiline`
and `--mode pcre` are both **fully green (30/30 each)** and are wired into the
correctness phase of `../gates/ci_order.sh`, so a `-U`/`-P` regression can never
reach the perf phase. (`--mode all` additionally runs a `core` regression slice
that still carries the one pre-existing, unrelated `-tgo` type-registry
divergence — boundary #8 — so it is not itself a blocking gate.)

### Acceleration (`modes.py bench`) — the brag

`-P`/`--pcre2` rides the same parallel work-stealing walk + index-backed
read-elision as the linear default (PCRE2 with JIT, per-worker match scratch),
so a lookaround/backreference query over a **selective** literal beats ripgrep's
own `-P` outright — gist touches only the trigram candidates, rg walks and
PCRE-matches the whole subtree. Median of 3, `gist rg <q> -c services/` vs
`rg <q> -c services/` on one workstation (illustrative, machine-specific):

| query                                          | gist-idx | gist-noidx |      rg |                 gist-idx vs rg |
| ---------------------------------------------- | -------: | ---------: | ------: | -----------------------------: |
| `WalletService` (rare literal)                 |   22.1ms |     80.1ms | 119.8ms |                **5.4× faster** |
| `error` (common literal)                       |   61.8ms |     90.3ms | 148.9ms |                **2.4× faster** |
| `func \w+\(` (anchored regex)                  |   51.3ms |     82.4ms | 148.9ms |                **2.9× faster** |
| `-P func \w+\((?=.*ctx)` (lookahead, common)   |   53.4ms |     82.5ms | 114.2ms |                **2.1× faster** |
| `-P WalletService(?=[\s\S]*ctx)` (rare)        |   22.3ms |     83.2ms | 120.2ms |                **5.4× faster** |
| `-U WalletService[\s\S]{0,80}?\{` (rare)       |  154.7ms |    225.3ms | 117.1ms | 0.76× (index still elides 30%) |
| `-U import \([\s\S]*?\)` (common lazy-dotstar) |    734ms |      733ms | 153.7ms | 0.21× (honest gap — see below) |

The index win is the headline: a **rare-literal `-P` lookaround is 5.4× faster
than `rg -P`**, and every literal/anchored/common-`-P` query is 2.1–2.9× faster.
`-U`/`--multiline` is byte-for-byte correct and index-accelerated (30% read
elision on a selective literal), but runs on the **serial** engine — the
multiline emitter owns whole-buffer cross-line spans that the parallel per-file
pipeline deliberately does not, to protect its 30/30 parity — so a _common_
lazy-dotstar (`[\s\S]*?`, "import block") query trails rg's lazy-DFA. Parallelizing
the `-U` emit path is the tracked follow-up; correctness is not affected.

## Flags companion (`flags.py`) — the walk/order/ignore, stderr, and haystack-anchor proof

`run.py` mines ripgrep's suite, but almost nothing there pins the walk/order/
ignore flags gist brought online: their answers depend on file **timestamps**,
**device ids**, worker **thread counts**, and a user's **global git config** —
none of which a self-contained mined replay can freeze. Two further lanes are
unminable for a different reason: one asserts on **stderr**, which the mined
harness never reads, and one needs a **body shape** the repo's own source can't
supply. `flags.py` is the hand-authored companion for all of them, same
philosophy as `modes.py` (rg the oracle, generated fixtures, nothing large
tracked):

```bash
python3 flags.py run                    # both engines (parallel + serial)
python3 flags.py run --engine serial    # one engine
python3 flags.py bench                   # parity-at-speed over services/backend (report-only)
```

- **Ordering** (`--sort`/`--sortr` × `path`/`modified`/`accessed`, `--sort-files`)
  is proven **byte-for-byte** on a fixture whose modified/accessed stamps are
  shuffled out of path order, so a comparator that ignored its key would diverge;
  `created` pins the set (birthtime isn't settable portably). This is the exact
  gate that caught gist byte-ordering paths where ripgrep orders them
  component-wise (`Path::cmp`: `warroom/service.go` before `warroom.go`).
- **Negation last-wins** (`--heading`/`--no-heading`, `-H`/`--no-filename`,
  `-n`/`--no-line-number`, `--stats`/`--no-stats`) is pinned deterministic by
  pairing with `--sort path`, so the assertion is byte-exact.
- **`-j`/`--threads`** is proven order-invariant (`-j1` == `-jN`) and a set match
  against rg (the parallel walk streams in worker-discovery order).
- **`--no-ignore-global`** runs against a fixture `$HOME/.gitconfig` naming a
  `core.excludesFile`: honored by default, disabled by the flag, byte-parity with
  `rg` under the same env.
- **`--no-messages` / `--no-ignore-messages`** are asserted on **stderr**, which
  is the only place the flags exist. rg's own mined cases for them check the exit
  code — a gist that merely _rejected_ the flag would pass that, since rejection
  and suppression both exit 2. So this lane pins the whole triple: stderr goes
  empty while stdout and the exit class stay put. It crosses the unreadable-file
  and malformed-ignore
  producers with rg's nesting rule (`--no-messages` subsumes the ignore class)
  and last-wins re-enabling, plus a lane-isolation case proving one producer
  can't leak into the other's channel.
- **`\A`/`\z` haystack anchors under `-U`** are crossed over three tail shapes —
  terminated, unterminated, and a single unterminated line — with seven output
  frames. The mined suite has only r1878's four `\Abaz` cases on one body, and
  they ask one question: did `-U` pick rg's whole-buffer searcher? The answer is
  invisible in the plain frame but surfaces as a match tally under `-c`, a column
  under `--vimgrep`, and a line set under `-v`, so the frames are the point. Two
  shapes are **named as still short of rg** rather than dropped: a nullable `\A`
  pattern (rg's searcher re-slices at every resume, so `\A` re-anchors and the
  whole file frames as one block) and an empty match at an unterminated EOF in a
  span frame (rg's printer discards it, then prints the block verbatim anyway).

Every non-thread case also asserts the indexed path equals `--no-index`
(read-elision soundness), and the whole slate runs once per engine — so an
ordering or ignore regression can never reach the perf phase. Wired into the
correctness phase of `../gates/ci_order.sh`.

## Transforms companion (`transforms.py`) — the `-z`/`--pre`/`-E`/`--binary` proof

`run.py` replays ripgrep's mined suite over the repo's **plain** source bytes, so
it never exercises the flags that reshape a file's content before matching. Those
need fixtures a source tree can't supply — compressed blobs, UTF-16/Latin-1 text,
a NUL-bearing file, a preprocessor script. `transforms.py` is the hand-authored
companion, ripgrep the oracle (no hardcoded expected strings), same as `modes.py`:

```bash
python3 transforms.py run                 # both engines: -z/--pre/-E/--binary parity vs rg
python3 transforms.py run --engine serial # one engine
python3 transforms.py bench               # -z speed: pipeline vs serial vs rg (+ vs_rg floor)
```

- **`-z`** is proven **byte-for-byte** per container — gzip/bzip2/xz always (stdlib
  mints them), plus zstd/lz4/brotli when the system encoder is present. gist
  decodes gzip/zlib/zstd/xz **in-process** (`ingest.zig` native `std.compress`); rg
  forks a decompressor. Output must be identical; speed need not.
- **`-E`** transcoding is byte-exact on UTF-16 (LE/BE/BOM), Latin-1, and the CJK /
  legacy code pages (Shift_JIS, EUC-JP, GBK, Big5, EUC-KR) — rg's `encoding_rs` is
  the oracle; an unrecognized label fails loud (exit 2) in both.
- **`--pre`/`--pre-glob`** (a `gzip -dc "$1"` wrapper, path-scoped) match rg exactly.
- **`--binary`/`-uuu`** are gist's deliberate **superset** of rg's one-line summary
  (search the NUL file in full), so `rg -a` is the oracle for that stdout; flag-free
  binary detection is separately pinned equal to plain rg.

Every case also asserts indexed == `--no-index` (a transform disables read-elision),
and the slate runs once per **engine**. The `run` differential is wired into the
correctness phase of `../gates/ci_order.sh`; `bench` into the perf phase with a
**blocking `--floor-rg` (default 2.0×)** — gist's in-process-decode edge over rg
is architectural (~4-15×), so a conservative floor never false-trips on jitter yet
catches a real regression (e.g. a fork-per-file path). The `parallel_gain`
(pipeline vs serial) it also prints is informational — the pipeline's
directory-granular work-stealing makes it corpus-shape-sensitive; the deterministic
guard that `-z`/`-E` still ride the parallel engine is the `transformsRidePipeline`
unit test in `pipeline.zig`, not that wall-clock number. The `../races/searchzip_headtohead.sh`
race adds ugrep to the `-z` field (gist beats both rg and ugrep on the in-process
formats; bzip2 and the external-codec tail have no in-process Zig decoder).

## Surface companion (`surface.py`) — conformance with ripgrep's own denominator

Every lane above measures a set someone curated: the cases ripgrep chose to
write, the flags this harness chose to hand-author. "How mature is gist?"
deserves a denominator gist does not pick. `surface.py` reads ripgrep's
**documented** flag surface at run time — the long flags from `rg --generate
complete-bash`, the shorts plus their value grammar and short↔long pairing from
its man page — exercises each one on a fixed miniature tree, and compares both
binaries' stdout and exit code byte-for-byte:

```bash
python3 surface.py                        # human table (losses only)
python3 surface.py --json OUT.json        # machine record (Layer I)
python3 surface.py --only no-hidden -v    # one flag, every row
```

Four outcomes, and only two of them earn a point. `identical` is byte-equal
stdout and exit code. `boundary` differs for a **declared** reason — gist naming
itself, gist's superset type registry, gist's own palette — and each carries a
_residual check_ re-verified on the same run, so a boundary that has quietly
become a bug is scored as one. `divergent` (differs for no declared reason) and
`rejected` (gist exits 2 where rg accepts — a hole) both cost a point.
Conformance is `(identical + boundary) / documented`. Currently **186 of 186 =
100.0%** (177 identical, 9 declared boundaries, 0 divergent, 0 rejected).

A separate **undo-pair** lane covers the half a per-flag probe structurally
cannot see: most negations name the default, so a negation that silently no-ops
looks correct in isolation. Each pair places the negation _after_ the positive
flag it undoes, on a fixture where the two answers differ — `-uu --no-hidden`
must stop finding the hidden file. 27/27 agree with rg.

## Fuzz companion (`fuzz.py`) — invocations nobody wrote down

The third lane generates rather than curates: a random pattern (corpus literals,
generated regexes, and known catastrophic-backtracking traps), a random
composable flag set, and one of six corpora built to be hostile — invalid UTF-8
and lone continuation bytes, CRLF and lone CR, a missing trailing newline, NUL
bearers and an ELF header, a 4 MiB single line, a 100k-line file, an empty file,
24 levels of nesting, a symlink cycle, a dangling symlink, and a mode-000 file.
Then it demands byte-identical stdout and an equal exit code from live `rg`.

```bash
python3 fuzz.py --iterations 2000 --seed 1 --json OUT.json
python3 fuzz.py --corpus hostile --verbose        # one corpus, every row
python3 fuzz.py --iterations 50 --keep /tmp/tree  # persist the corpus to reproduce
```

There is no expected-output table in the file, so there is nothing to bandaid: a
divergence is resolved by changing gist, or by proving it is one of the two
declared non-divergences (`declined` — gist's linear engine refusing a construct
outside its guaranteed-linear syntax and pointing at `-P`, the same judgment
`run.py` scores NA; `both_reject` — a pattern invalid for both engines, where
agreeing on a rejection is agreement). **Robustness is measured in the same
pass**, because that is what a maturity claim actually rests on: every child gets
a hard timeout, and crash / hang / peak-RSS are recorded per iteration rather
than hoped for.

### The residual, and why it is published rather than resolved to zero

Every unresolved failure is classed by the **shape** of the disagreement —
derived from the two byte streams, not from the argv that produced them, so the
same defect lands in the same bucket across seeds. The run prints that table and
writes it to the JSON record as `residual` / `residual_total`:

| class                         | the disagreement                                         |
| ----------------------------- | -------------------------------------------------------- |
| `line-count`                  | one output holds lines the other does not                |
| `line-content`                | same number of lines, one line's bytes differ            |
| `trailing-bytes`              | lines agree; the trailing terminator does not            |
| `exit-code`                   | byte-identical output, different exit code               |
| `timeout-rg` / `timeout-gist` | one binary hit the per-child wall; the suffix says which |
| `crash-rg` / `crash-gist`     | one binary died on a signal                              |

A shape may compose with `+exit` when the exit codes disagree too.

`fuzz_baseline.json` is the committed floor, and the certificate's Layer I
reporter (`bench/certificate/report/scanner.py`) gates on it **shrink-only**:
the total may not grow, no single class may grow, and a class the baseline does
not name fails the mint even when the total went down — a new root cause is news
even when the arithmetic improved. Refresh the baseline only in the same PR as
the fix that lowered it; lifting it to go green is the ratchet equivalent of
bandaging a test.

Publishing the tail is the point. A generated-invocation lane whose residual is
zero has stopped being adversarial, and the earlier arrangement — an optional
`--fuzz` flag feeding a gate that refused on any divergence — meant the only way
a real run could mint the certificate was to leave this lane out of it.

## Files

| File            | Role                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spec.json`     | frozen, self-contained mined spec (446 `rgtest!` invocations)                                                                                                                                                                                                                                                                                                                                                          |
| `mine.py`       | regenerates `spec.json` from a ripgrep checkout                                                                                                                                                                                                                                                                                                                                                                        |
| `run.py`        | differential runner + honest scoreboard (the gate)                                                                                                                                                                                                                                                                                                                                                                     |
| `modes.py`      | hand-authored `-U`/`-P` differential proof (the modes `run.py` defers)                                                                                                                                                                                                                                                                                                                                                 |
| `flags.py`      | hand-authored differential proof for what the mined suite can't pin: the walk/order/ignore flags (`--sort`/`--sortr`/`--sort-files`, `-j`/`--threads`, `--one-file-system`, `--no-ignore-global`, negation last-wins — timestamp/device/thread/global-config dependent), the `--no-messages`/`--no-ignore-messages` **stderr** lane, and `\A`/`\z` haystack anchors under `-U` across three tail shapes × seven frames |
| `transforms.py` | hand-authored `-z`/`--pre`/`-E`/`--binary` content-transform differential proof + the `-z` pipeline-vs-serial-vs-rg speed floor (the flags `run.py` can't mine from plain source)                                                                                                                                                                                                                                      |
| `surface.py`    | conformance over ripgrep's **own** documented flag surface, read from `rg --generate` + its man page at run time; scores identical / declared-boundary / divergent / rejected, plus the adverse undo-pair lane. Feeds Layer I of the certificate                                                                                                                                                                       |
| `fuzz.py`       | differential fuzzer — random (pattern × flags × hostile corpus) triples against live rg, with crash / hang / peak-RSS measured in the same pass                                                                                                                                                                                                                                                                        |
| `dbg.py`        | single-test side-by-side inspector                                                                                                                                                                                                                                                                                                                                                                                     |
| `results.json`  | last `run.py` per-test verdicts (regenerated each run)                                                                                                                                                                                                                                                                                                                                                                 |
