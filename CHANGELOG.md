# Changelog

All notable changes to `gist` (the product chassis; ships the `gist` and
`relate` binaries) are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions track
`build.zig.zon`.

<!-- towncrier release notes start -->

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
