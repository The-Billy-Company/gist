---
doc_radar:
  occurrences:
    - description: "the shared certificate registry has twelve active query classes"
      file: bench/apparatus/harness/probes.zig
      pattern: '^    \.\{ \.class = '
      equals: 12
  sentinels:
    - description: "the full mint automatically splices the Layers B through F pass"
      file: bench/certificate/mint/mint.sh
      contains: 'CERT_OUT="${OUT}" bash "${HERE}/splice.sh"'
    - description: "the full mint wires the --rank and relate lanes into the certificate"
      file: bench/certificate/mint/mint.sh
      contains: ['bash "${HERE}/rank.sh"', 'bash "${HERE}/relate.sh"']
    - description: "the layers pass mints the codex self-index proof (Layer F)"
      file: bench/certificate/mint/splice.sh
      contains: 'report/codex.py'
    - description: "the release gate requires a certificate on both the Mac and the Linux machine"
      file: bench/certificate/guard/release.py
      contains: ['"darwin": "Mac"', '"linux": "Linux"']
    - description: "Town Crier (package changelog) gates the irregex release on the cross-machine certificate"
      file: towncrier.toml
      contains: "guard/release.py"
---

# bench/certificate

The **published claim** (was `certify/`). The microscopic half of the Layer-A
dominance certificate (`zig build certify`, single-threaded cycles/byte) lives in
`irregex/bench/apparatus/harness/`; this bucket proves the
_end-to-end_ claim a user actually cares about: for every regex class ripgrep
supports, gist's cold fresh-process query is **at parity or faster than
ripgrep**, established with a real statistic — not a single mean.

That cold claim covers the shared 12-class literal/regex probe registry. The
**narrower surfaces the header used to disclaim now each carry their own
fail-closed section**, so no claim ships without a receipt: the **warm
resident-daemon tier** (`mint/warm.sh` + [`../dominance/session/`](../dominance/session/README.md))
is the single home for the "warm is Nx faster" claim; the **`--rank` lane**
(`mint/rank.sh`) certifies the definition-first shape rg cannot express
(no-fabrication + coverage + def-boost + codegen-demote + bounded overhead +
beats-rg where the prefilter prunes); **Layer F** (via `mint/splice.sh` →
`relate/bench/bounds/codex/`) proves the codex self-index is
compressed, searchable, and byte-exact decodable; and **Layer G**
(`mint/relate.sh`) certifies the relate face's retrieval-quality contract +
boundary — explicitly _not_ a dominance claim. `--include-zero` and composed
`irregex` remain outside this certificate even when their correctness is proved
elsewhere.

| Folder                        | Role                                                                                                                        |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| [`mint/`](mint/README.md)     | the minting scripts — `mint.sh` (the one entry point) + the `splice`/`warm`/`rank`/`relate`/`crest` lanes                   |
| [`report/`](report/README.md) | the splicers — `stats.py` (the statistics kernel) + one `<x>.py` per certificate section                                    |
| [`guard/`](guard/README.md)   | the gates between a mint and a release — `layers.py` · `artifacts.py` · `release.py` · `ratio.py` (+ `ratio_baseline.json`) |
| [`ledger/`](ledger/README.md) | the certificate's memory — `ledger.py` · `ledger.jsonl` · `LEDGER.md`                                                       |
| `artifact/`                   | FROZEN — the committed, reproducible certificate bundle; per-platform mints live in `artifact/<platform-id>/`               |

The 12 classes are byte-identical to `../apparatus/harness/certify.zig`'s probes,
so the macroscopic table here and the microscopic table there map 1:1 by class
name. The verdict is **fail-closed** — a WIN needs a lower median _and_
Mann-Whitney `p<0.05`; every class is shown, losses and the indexed-twin
(csearch/zoekt) context included. Unlike the selective-needle cold sweep in
[`../dominance/races/`](../dominance/races/README.md), the probe classes here
deliberately include the **saturating** patterns (`})`, `;$`, `\w{3,8}`, a UUID
class, the sub-trigram pure-literal alternation `panic|0x`) where the trigram
prefilter admits _every_ file — the cases the competition is built to win. Two of
those saturating classes no longer saturate: the sliver tier (Layer J) brings
`})` to 49.18% and `panic|0x` to 37.42% of corpus bytes, so the trigram directory
is no longer the whole story for a sub-trigram needle. `;$`, `\w{3,8}`, and the
UUID class still admit every file.

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
  contention, the same ceiling `fresh/journal.zig`'s header records.
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
# One command — Layers A–G. mint.sh mints A (micro + macro + warm + --rank),
# auto-sudo for PMU when available, then splice.sh splices B–F and the relate
# face (Layer G) before publish.
bash bench/certificate/mint/mint.sh                              # B–F refresh (fast)
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 bash bench/certificate/mint/mint.sh  # full mint + publish

# from package root
RUNS=20 bench/certificate/mint/mint.sh   # default RUNS=20 WARMUP=3; raise RUNS to tighten CIs
# publish a committed bundle (clean, stable checkout/worktree only):
CERT_PUBLISH_DIR=bench/certificate/artifact bash bench/certificate/mint/mint.sh
# local exploratory mint from uncommitted bytes (not publishable evidence):
CERT_ALLOW_DIRTY=1 bash bench/certificate/mint/mint.sh
# B–F only (when Layer A already exists):
bash bench/certificate/mint/splice.sh
python3 bench/certificate/guard/ratio.py --committed   # hermetic floor check
GIST_BENCH=1 python3 bench/certificate/guard/ratio.py                     # + live remeasure
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
an M4 Max shows a clean sweep vs ripgrep). So a release is only
allowed to claim optimality once the certificate has been re-minted on **each**
supported architecture and attached. `guard/release.py` is the fail-closed
check a release process should run before cutting a version — it refuses unless
a valid certificate exists for **both** the Mac and the Linux machine:

```bash
python3 bench/certificate/guard/release.py          # → 0 only when both machines are covered
python3 bench/certificate/guard/release.py --json   # per-platform coverage + speeds
```

The layout is **additive** — the flat `artifact/` stays the current-machine mint
(the Mac today); the Linux mint publishes into its own per-platform subdir, and
an explicit `artifact/<platform-id>/` always wins over the flat dir for its
platform:

```bash
# On the Mac (flat bundle, unchanged):
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 bash bench/certificate/mint/mint.sh
# On the Linux box (Anvil / x86_64) — publish beside it, do not overwrite:
CERT_PUBLISH_DIR=bench/certificate/artifact/linux-x86_64 bash bench/certificate/mint/mint.sh
```

Each bundle must pass `guard/artifacts.py` (internal reproducibility). Its
recorded `git_commit` is **provenance, not a condition** — surfaced so a human
can trace a number back to a tree, never resolved or compared, and never a
reason to fail. An audited emergency override is a deliberate skip of this
gate in the consumer's release tooling — not something this package ships.

## Mint ledger — the certificate's memory

A mint **rewrites the whole certificate**, and Layers B–G are spliced back
afterward by separate reporters. That makes every certificate honest on its own
and amnesiac about the last one: a re-mint that improves eight numbers looks
exactly like one that also drops a layer. When that happened, the loss only
surfaced days later as a documentation pin failing far from its cause.

`ledger/ledger.py` is the memory. Every publish appends a row — corpus, the
layers actually carried, the verdict tally, the cold and crest geomeans — keyed
by a digest of `CERTIFICATE.md`, so a re-mint is never silent and the history is
readable in [`ledger/LEDGER.md`](ledger/LEDGER.md):

```bash
python3 bench/certificate/ledger/ledger.py                            # survey: is the certificate on disk recorded?
python3 bench/certificate/ledger/ledger.py verify              # fail-closed on unrecorded drift
python3 bench/certificate/ledger/ledger.py verify --require-layers  # …and on an incomplete mint
python3 bench/certificate/ledger/ledger.py list --limit 10     # the look-back
python3 bench/certificate/ledger/ledger.py show latest         # one mint in full
```

`verify` fails on **unrecorded drift** — a certificate on disk that no row
describes. A missing layer is always _reported_ but only fails under
`--require-layers`, because the two have different remedies: `record` clears
drift, while only re-splicing the layer clears a gap. Keeping them separate
means the fix the gate prints is always one that actually clears it.

`record` runs automatically from `mint/mint.sh` and `mint/splice.sh` on publish;
`backfill` reconstructs rows from the certificate's git history. Because rows are
read from the certificate document itself, a historical mint replays exactly as
it was published rather than borrowing today's side-cars.
