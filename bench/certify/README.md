---
doc_radar:
  occurrences:
    - description: "the shared certificate registry has twelve active query classes"
      file: pkg/kernels/irregex/bench/harness/probes.zig
      pattern: '^    \.\{ \.class = '
      equals: 12
  sentinels:
    - description: "the full mint automatically splices the Layers B through F pass"
      file: pkg/kernels/irregex/bench/certify/certify.sh
      contains: 'CERT_OUT="${OUT}" bash "${HERE}/certify_layers.sh"'
    - description: "the full mint wires the --rank and relate lanes into the certificate"
      file: pkg/kernels/irregex/bench/certify/certify.sh
      contains: ['bash "${HERE}/certify_rank.sh"', 'bash "${HERE}/certify_relate.sh"']
    - description: "the layers pass mints the codex self-index proof (Layer F)"
      file: pkg/kernels/irregex/bench/certify/certify_layers.sh
      contains: 'certify_codex_report.py'
    - description: "the release gate requires a certificate on both the Mac and the Linux machine"
      file: pkg/kernels/irregex/bench/certify/check_release.py
      contains: ['"darwin": "Mac"', '"linux": "Linux"']
    - description: "Town Crier (chronicle) gates the irregex release on the cross-machine certificate"
      file: pkg/tools/support/chronicle/packages.py
      contains: "check_release.py"
---

# bench/certify

The **macroscopic** half of the Layer-A optimality certificate (see
`../README.md` § "Certificate of Optimality"). The microscopic half
(`zig build certify`, single-threaded cycles/byte) lives in
[`../harness/`](../harness/README.md); this half proves the _end-to-end_ claim
a user actually cares about: for every regex class ripgrep supports, gist's
cold fresh-process query is **at parity or faster than ripgrep**, established
with a real statistic — not a single mean.

That cold claim covers the shared 12-class literal/regex probe registry. The
**narrower surfaces the header used to disclaim now each carry their own
fail-closed section**, so no claim ships without a receipt: the **warm
resident-daemon tier** (`certify_warm.sh` + `../session/`) is the single home for
the "warm is Nx faster" claim; the **`--rank` lane** (`certify_rank.sh`) certifies
the definition-first shape rg cannot express (no-fabrication + coverage +
def-boost + codegen-demote + bounded overhead + beats-rg where the prefilter
prunes); **Layer F**
(`certify_codex.sh` via `../codex/`) proves the codex self-index is compressed,
searchable, and byte-exact decodable; and **Layer G** (`certify_relate.sh`)
certifies the relate face's retrieval-quality contract + boundary — explicitly
_not_ a dominance claim. `--include-zero` and composed `irregex` remain outside
this certificate even when their correctness is proved elsewhere.

| File                         | Role                                                                                                                                                                                                     |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `certify.sh`                 | full A–G mint: Layer A micro (+ optional sudo PMU) + macroscopic field race + warm tier + `--rank` lane + relate (Layer G), auto-calls `certify_layers.sh`                                               |
| `certify_layers.sh`          | Layers B/B′/C/D/E/F — build lab bins, measure, splice; the half that used to be a manual checklist. `make bench-gist-certify` default                                                                    |
| `certify_stats.py`           | a stdlib mirror of `../harness/stats.zig` — per-class bootstrap-CI median + Mann-Whitney verdict, splices the table into `.local/gist-verify/CERTIFICATE.md`                                             |
| `certify_warm_report.py`     | Layer A warm-tier splicer — per-class Mann-Whitney dominance of the resident daemon over cold gist + rivals                                                                                              |
| `certify_rank_report.py`     | Layer A `--rank` lane splicer — fail-closed no-fabrication/coverage/def-boost/demotion/overhead/selective-beats-rg from `certify_rank.sh`                                                                |
| `certify_crest_report.py`    | Layer E splicer — renders the fail-closed crest-sieve pruning/speedup table from `crest.csv` (`zig build crest`) into the certificate                                                                    |
| `certify_codex_report.py`    | Layer F splicer — fail-closed decodability/sub-entropy space/n-free count/cheap reload/self-recognition from the `codex-scale` JSONL (`../codex/`)                                                       |
| `certify_relate_report.py`   | Layer G splicer — fail-closed relate boundary + recall@1 + pack + short-recall from `certify_relate.sh`                                                                                                  |
| `check_artifacts.py`         | reproducibility gate — required files + Layer B–G headers/side-cars + corpus hashes + tool identities + raw-cell matrix                                                                                  |
| `ratio_regress.py`           | principia-style **ratio** regression — committed `certify_macro.csv` vs `ratio_baseline.json` floors; optional live remasure behind `GIST_BENCH=1`                                                       |
| `ratio_baseline.json`        | min gist/rg cold speedup floors (hardware cancels; refresh after a deliberate republish)                                                                                                                 |
| `check_release.py`           | **release gate** — refuses a release until a valid certificate is attached for **both** the Mac and the Linux machine; run by Town Crier (`changelog build`)                                             |
| `ledger.py`                  | **mint ledger** — appends one row per published certificate (corpus, layers carried, verdict tally, geomeans); `verify` fail-closes on an unrecorded re-mint, `--require-layers` also on a dropped layer |
| `LEDGER.md` / `ledger.jsonl` | the look-back itself: rendered table + append-only machine record, written by `ledger.py` (never hand-edited)                                                                                            |
| `artifact/`                  | committed, reproducible certificate bundle (`CERT_PUBLISH_DIR=… certify.sh` / `CERT_PUBLISH=1 make bench-gist-certify`); per-platform mints live in `artifact/<platform-id>/`                            |

The 12 classes are byte-identical to `../harness/certify.zig`'s probes, so the
macroscopic table here and the microscopic table there map 1:1 by class name.
The verdict is **fail-closed** — a WIN needs a lower median _and_
Mann-Whitney `p<0.05`; every class is shown, losses and the indexed-twin
(csearch/zoekt) context included. Unlike the selective-needle cold sweep in
`../races/`, the probe classes here deliberately include the **saturating**
patterns (`})`, `;$`, `\w{3,8}`, a UUID class, the sub-trigram pure-literal
alternation `panic|0x`) where the trigram prefilter admits _every_ file — the
cases the competition is built to win.

## The three cold cells csearch/zoekt win, and why they stay won

The cold macro tier has gist behind csearch on `literal-rare` and `regex-dotted`,
and level with zoekt on `literal-punct2`. That gap is **the price of live truth,
measured — not an unoptimized path.** Do not re-open it without new evidence
against the following:

- **It is not the search kernel.** Layer D certifies gist at the
  information-theoretic floor on all three classes. A query whose index prunes
  _every_ file still costs ~55 ms / ~170 ms system time; adding the real work of
  scanning 13.8 MiB and returning 546 matches costs **3.5 ms more**. Essentially
  all of it is fixed cost paid before any matching.
- **It is the freshness metadata, and the walk is already fused.**
  `descent.zig` takes ONE pass, choosing `bulkstat.listOneLevel`
  (name+type+mtime+ctime in one `getattrlistbulk` per directory) when freshness
  is live and `listNamesOnly` otherwise. Names-only over the same tree is
  ~12.5 ms; the timestamps are the rest. There is no second traversal to remove.
- **It is at the platform floor.** Widening the pool makes it worse, not better
  (measured 8 workers 57 ms · 16 workers 61 ms · 24 workers 120 ms) — VFS
  contention, the same ceiling `tree/journal.zig`'s header records.
- **The journal cannot rescue the cold path _here_.** FSEvents historical replay
  is exact-or-refuse and would let the walk drop to names-only, but on a
  ~10-agent tree it delivered 246 entries before hitting its 75 ms budget with
  `doubt=none` — clean data, just streamed too slowly — while the fallback walk
  resolved 1,158 changed files in 354 ms. Replay is ~8× _slower_ than the walk it
  would replace, so wiring it into the query path is a pessimization.

csearch spends tens of ms of system time to gist's ~170 ms because it never consults
the filesystem: it answers from its index and goes silently stale. gist's answer
to the same workload is the **warm tier**, where the resident daemon holds an
armed watcher, skips the walk without giving up live truth, and beats csearch by
a 19.4× geomean while winning all 12 classes against every rival. Closing these
three cold cells means giving up the guarantee that makes gist correct.

Each timed cell is all-or-nothing. A transient tool failure retains its
diagnostic and retries the complete warmup/run set once; a persistent failure
stays visible and the cell is excluded rather than fabricated. Gist itself is
the subject, so any gist failure aborts the mint.

```bash
# One command — Layers A–G. certify.sh mints A (micro + macro + warm + --rank),
# auto-sudo for PMU when available, then certify_layers.sh splices B–F and the
# relate face (Layer G) before publish.
make bench-gist-certify                              # B–F refresh (fast)
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify  # full mint + publish

cd pkg/kernels/irregex
RUNS=20 bench/certify/certify.sh        # default RUNS=20 WARMUP=3; raise RUNS to tighten CIs
# publish a committed bundle (clean, stable checkout/worktree only):
CERT_PUBLISH_DIR=bench/certify/artifact bash bench/certify/certify.sh
# local exploratory mint from uncommitted bytes (not publishable evidence):
CERT_ALLOW_DIRTY=1 bash bench/certify/certify.sh
# B–F only (when Layer A already exists):
bash bench/certify/certify_layers.sh
python3 bench/certify/ratio_regress.py --committed   # hermetic floor check
GIST_BENCH=1 make bench-gist-ratio                   # + live remeasure
```

A full mint must see immutable corpus bytes. Use a clean checkout or isolated
worktree; do not certify the actively changing coworking tree. The manifest
hashes detect mutation late, but a benchmark that races file creation/removal
is already invalid before that gate.

That is why a manifest row is a promise — _these exact bytes produced the timings
above_ — and why the default mint **aborts** when a corpus file vanishes or
changes while being hashed. `CERT_ALLOW_DIRTY=1` relaxes only the promise's
scope, never its honesty: a churned file is _dropped_ from the manifest instead
of hashed loosely, counted in `machine.json` as `corpus_unstable_files` (with a
capped `corpus_unstable` path sample), so the bundle says exactly which bytes it
cannot vouch for. It stays fail-closed above 1% churn — past that the corpus
moved too much to certify at all. The point is that a coworker's `rm` costs you
a manifest row, not the half hour of measurement already in hand.

## Release gate — a certificate on every machine

Cold-CLI dominance is **machine-specific** (an M2 mint once showed 0 wins where
an M4 Max shows a clean sweep vs ripgrep — see ADR-320). So a release is only
allowed to claim optimality once the certificate has been re-minted on **each**
supported architecture and attached. `check_release.py` is what Town Crier
([`chronicle`](../../../../tools/changelog/README.md)) runs before it will cut an
irregex release — `changelog build` refuses unless a valid certificate exists
for **both** the Mac and the Linux machine:

```bash
# What `make changelog-build PKG=irregex VERSION=x.y.z` enforces automatically:
python3 bench/certify/check_release.py            # → 0 only when both machines are covered
python3 bench/certify/check_release.py --json     # per-platform coverage + speeds
```

The layout is **additive** — the flat `artifact/` stays the current-machine mint
(the Mac today); the Linux mint publishes into its own per-platform subdir, and
an explicit `artifact/<platform-id>/` always wins over the flat dir for its
platform:

```bash
# On the Mac (flat bundle, unchanged):
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify
# On the Linux box (Anvil / x86_64) — publish beside it, do not overwrite:
CERT_PUBLISH_DIR=bench/certify/artifact/linux-x86_64 bash bench/certify/certify.sh
```

Each bundle must pass `check_artifacts.py` (internal reproducibility). Its
recorded `git_commit` is **provenance, not a condition** — surfaced so a human
can trace a number back to a tree, never resolved or compared, and never a
reason to fail. `CHRONICLE_SKIP_RELEASE_GATE=1` (or `changelog build
--skip-release-gate`) is the audited emergency override.

## Mint ledger — the certificate's memory

A mint **rewrites the whole certificate**, and Layers B–G are spliced back
afterward by separate reporters. That makes every certificate honest on its own
and amnesiac about the last one: a re-mint that improves eight numbers looks
exactly like one that also drops a layer. When that happened, the loss only
surfaced days later as a documentation pin failing far from its cause.

`ledger.py` is the memory. Every publish appends a row — corpus, the layers
actually carried, the verdict tally, the cold and crest geomeans — keyed by a
digest of `CERTIFICATE.md`, so a re-mint is never silent and the history is
readable in [`LEDGER.md`](LEDGER.md):

```bash
make bench-gist-ledger                            # survey: is the certificate on disk recorded?
make bench-gist-ledger ARGS="verify"              # fail-closed on unrecorded drift
make bench-gist-ledger ARGS="verify --require-layers"  # …and on an incomplete mint
make bench-gist-ledger ARGS="list --limit 10"     # the look-back
make bench-gist-ledger ARGS="show latest"         # one mint in full
```

`verify` fails on **unrecorded drift** — a certificate on disk that no row
describes. A missing layer is always _reported_ but only fails under
`--require-layers`, because the two have different remedies: `record` clears
drift, while only re-splicing the layer clears a gap. Keeping them separate
means the fix the gate prints is always one that actually clears it.

`record` runs automatically from `certify.sh` and `certify_layers.sh` on
publish; `backfill` reconstructs rows from the certificate's git history.
Because rows are read from the certificate document itself, a historical mint
replays exactly as it was published rather than borrowing today's side-cars.
