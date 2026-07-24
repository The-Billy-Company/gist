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

| File                       | Role                                                                                                                                                                          |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `certify.sh`               | full A–G mint: Layer A micro (+ optional sudo PMU) + macroscopic field race + warm tier + `--rank` lane + relate (Layer G), auto-calls `certify_layers.sh`                    |
| `certify_layers.sh`        | Layers B/B′/C/D/E/F — build lab bins, measure, splice; the half that used to be a manual checklist. `make bench-gist-certify` default                                         |
| `certify_stats.py`         | a stdlib mirror of `../harness/stats.zig` — per-class bootstrap-CI median + Mann-Whitney verdict, splices the table into `.local/gist-verify/CERTIFICATE.md`                  |
| `certify_warm_report.py`   | Layer A warm-tier splicer — per-class Mann-Whitney dominance of the resident daemon over cold gist + rivals                                                                   |
| `certify_rank_report.py`   | Layer A `--rank` lane splicer — fail-closed no-fabrication/coverage/def-boost/demotion/overhead/selective-beats-rg from `certify_rank.sh`                                     |
| `certify_crest_report.py`  | Layer E splicer — renders the fail-closed crest-sieve pruning/speedup table from `crest.csv` (`zig build crest`) into the certificate                                         |
| `certify_codex_report.py`  | Layer F splicer — fail-closed decodability/sub-entropy space/n-free count/cheap reload/self-recognition from the `codex-scale` JSONL (`../codex/`)                            |
| `certify_relate_report.py` | Layer G splicer — fail-closed relate boundary + recall@1 + pack + short-recall from `certify_relate.sh`                                                                       |
| `check_artifacts.py`       | reproducibility gate — required files + Layer B–G headers/side-cars + corpus hashes + tool identities + raw-cell matrix                                                       |
| `ratio_regress.py`         | principia-style **ratio** regression — committed `certify_macro.csv` vs `ratio_baseline.json` floors; optional live remasure behind `GIST_BENCH=1`                            |
| `ratio_baseline.json`      | min gist/rg cold speedup floors (hardware cancels; refresh after a deliberate republish)                                                                                      |
| `check_release.py`         | **release gate** — refuses a release until a valid, current certificate is attached for **both** the Mac and the Linux machine; run by Town Crier (`changelog build`)         |
| `artifact/`                | committed, reproducible certificate bundle (`CERT_PUBLISH_DIR=… certify.sh` / `CERT_PUBLISH=1 make bench-gist-certify`); per-platform mints live in `artifact/<platform-id>/` |

The 12 classes are byte-identical to `../harness/certify.zig`'s probes, so the
macroscopic table here and the microscopic table there map 1:1 by class name.
The verdict is **fail-closed** — a WIN needs a lower median _and_
Mann-Whitney `p<0.05`; every class is shown, losses and the indexed-twin
(csearch/zoekt) context included. Unlike the selective-needle cold sweep in
`../races/`, the probe classes here deliberately include the **saturating**
patterns (`})`, `;$`, `\w{3,8}`, a UUID class, the sub-trigram pure-literal
alternation `panic|0x`) where the trigram prefilter admits _every_ file — the
cases the competition is built to win.

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

## Release gate — a certificate on every machine

Cold-CLI dominance is **machine-specific** (an M2 mint once showed 0 wins where
an M4 Max shows a clean sweep vs ripgrep — see ADR-320). So a release is only
allowed to claim optimality once the certificate has been re-minted on **each**
supported architecture and attached. `check_release.py` is what Town Crier
([`chronicle`](../../../../tools/changelog/README.md)) runs before it will cut an
irregex release — `changelog build` refuses unless a valid, current-to-history
certificate exists for **both** the Mac and the Linux machine:

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

Each bundle must pass `check_artifacts.py` (internal reproducibility) and its
recorded `git_commit` must belong to the released line of history (`--pin <sha>`
locks it to an exact release commit; `--max-age-commits N` bounds staleness).
`CHRONICLE_SKIP_RELEASE_GATE=1` (or `changelog build --skip-release-gate`) is the
audited emergency override.
