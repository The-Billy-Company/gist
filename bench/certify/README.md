---
doc_radar:
  occurrences:
    - description: "the shared certificate registry has twelve query classes"
      file: pkg/kernels/irregex/bench/harness/probes.zig
      pattern: '\.class = '
      equals: 12
  sentinels:
    - description: "the full mint automatically splices Layers B through D"
      file: pkg/kernels/irregex/bench/certify/certify.sh
      contains: 'CERT_OUT="${OUT}" bash "${HERE}/certify_layers.sh"'
---

# bench/certify

The **macroscopic** half of the Layer-A optimality certificate (see
`../README.md` § "Certificate of Optimality"). The microscopic half
(`zig build certify`, single-threaded cycles/byte) lives in
[`../harness/`](../harness/README.md); this half proves the _end-to-end_ claim
a user actually cares about: for every regex class ripgrep supports, gist's
cold fresh-process query is **at parity or faster than ripgrep**, established
with a real statistic — not a single mean.

That claim covers the shared 12-class literal/regex probe registry and no
broader surface. `--include-zero`, warm daemon traffic, `relate`, and composed
`irregex` are outside this certificate even when their correctness is proved
elsewhere.

| File                  | Role                                                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `certify.sh`          | full A–D mint: Layer A micro (+ optional sudo PMU) + macroscopic field race, then auto-calls `certify_layers.sh` before publish                              |
| `certify_layers.sh`   | Layers B/B′/C/D — build lab bins, measure, splice; the half that used to be a manual checklist. `make bench-gist-certify` default                            |
| `certify_stats.py`    | a stdlib mirror of `../harness/stats.zig` — per-class bootstrap-CI median + Mann-Whitney verdict, splices the table into `.local/gist-verify/CERTIFICATE.md` |
| `check_artifacts.py`  | reproducibility gate — required files + Layer B/C/D headers/side-cars + corpus hashes + tool identities + raw-cell matrix                                    |
| `ratio_regress.py`    | principia-style **ratio** regression — committed `certify_macro.csv` vs `ratio_baseline.json` floors; optional live remasure behind `GIST_BENCH=1`           |
| `ratio_baseline.json` | min gist/rg cold speedup floors (hardware cancels; refresh after a deliberate republish)                                                                     |
| `artifact/`           | committed, reproducible certificate bundle (`CERT_PUBLISH_DIR=… certify.sh` / `CERT_PUBLISH=1 make bench-gist-certify`)                                      |

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
# One command — Layers A–D. certify.sh mints A (micro + macro), auto-sudo for
# PMU when available, then certify_layers.sh splices B/B′/C/D before publish.
make bench-gist-certify                              # B–D refresh (fast)
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify  # full mint + publish

cd pkg/kernels/irregex
RUNS=20 bench/certify/certify.sh        # default RUNS=20 WARMUP=3; raise RUNS to tighten CIs
# publish a committed bundle (clean, stable checkout/worktree only):
CERT_PUBLISH_DIR=bench/certify/artifact bash bench/certify/certify.sh
# local exploratory mint from uncommitted bytes (not publishable evidence):
CERT_ALLOW_DIRTY=1 bash bench/certify/certify.sh
# B–D only (when Layer A already exists):
bash bench/certify/certify_layers.sh
python3 bench/certify/ratio_regress.py --committed   # hermetic floor check
GIST_BENCH=1 make bench-gist-ratio                   # + live remeasure
```

A full mint must see immutable corpus bytes. Use a clean checkout or isolated
worktree; do not certify the actively changing coworking tree. The manifest
hashes detect mutation late, but a benchmark that races file creation/removal
is already invalid before that gate.
