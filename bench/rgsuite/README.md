# gist ⇄ ripgrep drop-in proof (`rgsuite`)

This is the honest, reproducible measurement of how close gist's `rg` verb is to
a **drop-in ripgrep** on the surface it claims to support (currently **96.5%
supported-surface parity** with every remaining divergence explained and
phase-tracked — see the scoreboard), benchmarked against real ripgrep as both
the **correctness oracle** and the **performance baseline**.
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

`rg 15.1.0`, 441 mined `rgtest!` cases (invocations; a multi-command `rgtest!`
mines one case per command), replayed against **both** engines:

| Bucket    | parallel (`pipeline.zig`) | serial (`run.zig`) | Meaning                                                                          |
| --------- | ------------------------: | -----------------: | ------------------------------------------------------------------------------- |
| **PASS**  |                       391 |                391 | `gist rg` stdout == `rg` stdout **at the mined test's own bar** (see below)      |
| **ORDER** |                         0 |                  0 | a byte-exact (`eqnice!`) case differing only in line order — a real hole         |
| **FAIL**  |                        14 |                 14 | a supported-surface divergence, each phase-tracked in `coverage_manifest.toml`   |
| NA        |                        16 |                 16 | unsupported **by design** (see boundaries below)                                 |
| SKIP      |                        20 |                 20 | not replayable as one argv — each mapped to a companion proof / upstream reason  |

**Supported-surface parity = (PASS+ORDER) / (PASS+ORDER+FAIL) = 391/405 = 96.5%
on both engines** — identical on whichever engine a given case dispatches to. The
14 FAILs are not hidden behind a shrunken denominator: each is an explained,
adverse-tested divergence recorded once in `coverage_manifest.toml` and tracked
to the deferred entry that owns its fix. Together the 441 mined obligations account
completely — every case is replayed (PASS/ORDER/FAIL/NA) or claimed by exactly
one manifest entry (SKIP) — and `check_results.py` fails the build on any orphan
skip, double credit, undeferred FAIL, undocumented divergence, or README drift.

### Complete obligation accounting (no misleading denominator)

The 441 mined `rgtest!` obligations split into what the harness can drive against
live `rg` as one argv, and what it accounts for out-of-band in
`coverage_manifest.toml` (`tomllib`-parsed, gate-enforced):

- **405 replayed** — executed against real ripgrep and bucketed above
  (391 PASS + 14 FAIL); NA (16) are replayed too but fall outside the parity
  denominator as announced design refusals.
- **20 SKIP, each claimed once** by a manifest entry: **companion** (the miner
  couldn't lower a control-flow `rgtest!` to one argv, but a sibling proof —
  `flags.py`/`modes.py`/`transforms.py` — drives the same flags byte-for-byte),
  **boundary** (a purposeful decline whose adverse test is the loud exit-2
  itself), or **irreplayable** (the mined JSON can't encode the case, e.g. a
  non-UTF-8 filename).
- **14 FAIL, each claimed once** by a **deferred** manifest entry naming the plan
  phase that closes it (`rich-output`, `walk-scope`, `hard-paths`).

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
is a full PASS for a `cmp=sort` case (5 such cases today), while a `cmp=plain`
case that matches only after sorting stays ORDER: a real parity hole, and the
bucket is empty. The parallel engine still streams each hit the instant a
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
4. **ASCII case-folding** — `-i` folds ASCII only; no Unicode case folding, and
   no per-branch `(?i)` across multiple `-e` patterns.
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

The honest headline: gist is a **near-drop-in rg (96.5% supported-surface parity
on both engines, with every remaining divergence explained and phase-tracked)**
that is **~3.3× faster cold** and **~1770× faster warm-resident** than ripgrep —
the "40×" claim sits comfortably between the one-shot and resident models and is
conservative for gist's intended long-lived agent-session use.

## Running it

```bash
# build the binary the suite drives
zig build            # in pkg/kernels/irregex  → zig-out/bin/gist (the CLI, `rg` verb)

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

## Flags companion (`flags.py`) — the `--sort`/`-j`/`--one-file-system`/global-ignore proof

`run.py` mines ripgrep's suite, but almost nothing there pins the walk/order/
ignore flags gist brought online: their answers depend on file **timestamps**,
**device ids**, worker **thread counts**, and a user's **global git config** —
none of which a self-contained mined replay can freeze. `flags.py` is the
hand-authored companion for exactly those, same philosophy as `modes.py` (rg the
oracle, generated fixtures, nothing large tracked):

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

## Files

| File            | Role                                                                                                                                                                                                                                                              |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spec.json`     | frozen, self-contained mined spec (441 `rgtest!` invocations)                                                                                                                                                                                                     |
| `mine.py`       | regenerates `spec.json` from a ripgrep checkout                                                                                                                                                                                                                   |
| `run.py`        | differential runner + honest scoreboard (the gate)                                                                                                                                                                                                                |
| `modes.py`      | hand-authored `-U`/`-P` differential proof (the modes `run.py` defers)                                                                                                                                                                                            |
| `flags.py`      | hand-authored walk/order/ignore-flag differential proof (`--sort`/`--sortr`/`--sort-files`, `-j`/`--threads`, `--one-file-system`, `--no-ignore-global`, negation last-wins) — timestamp/device/thread/global-config dependent, so the mined suite can't pin them |
| `transforms.py` | hand-authored `-z`/`--pre`/`-E`/`--binary` content-transform differential proof + the `-z` pipeline-vs-serial-vs-rg speed floor (the flags `run.py` can't mine from plain source)                                                                                 |
| `dbg.py`        | single-test side-by-side inspector                                                                                                                                                                                                                                |
| `results.json`  | last `run.py` per-test verdicts (regenerated each run)                                                                                                                                                                                                            |
