---
doc_radar:
  occurrences:
    - description: "every declared CLI shape is one [[shape]] row in matrix.toml"
      file: bench/conformance/shapes/shapes.toml
      pattern: '\[\[shape\]\]'
      equals: 27
    - description: "the literal set keeps a degenerate-selection case (selector blind spot)"
      file: bench/conformance/shapes/shapes.toml
      pattern: 'select = "degenerate"'
      min: 1
  sentinels:
    - description: "the driver reuses the certificate's stats (never a second impl)"
      file: bench/conformance/shapes/shapes.py
      contains:
        - "import stats as S"
        - 'sub.add_parser("parity")'
        - 'sub.add_parser("gate")'
---

# gist/bench/matrix — the CLI-shape admission matrix

The races and the certificate prove gist beats the field on a handful of
regex _classes_. This folder proves it across the **shape** dimensions a
real invocation turns on — `mode` (linear / `-U` / `-P`), match `flags`,
walk `scope`, `emit` shape, `select`ivity, and pattern `kind` — with the
plan's discipline: **parity before speed, every divergence declared.**

`matrix.toml` is the machine-readable matrix: one `[[shape]]` row per
supported CLI shape, each carrying the real flags, a corpus pattern of known
selectivity, its parity `bar`, and its performance `expect`ation.
`matrix.py` lowers every row into an actual argv and drives it three ways —
gist cold-indexed, gist cold-unindexed (`--no-index`), and ripgrep — so
eligibility and index-elision are **measured, not inferred**.

```bash
python3 matrix.py parity                 # correctness gate: gist-idx == gist-noidx == rg
GIST_BENCH=1 python3 matrix.py bench --publish   # measure + refresh floors/certificate
python3 matrix.py gate                   # assert committed per-shape floors (hermetic)
python3 matrix.py bench --only <id> --runs 20     # re-measure one shape (no publish)
```

## The three subcommands

- **`parity`** — asserts `gist-idx == gist-noidx == rg` at each row's bar
  (`set` / `lines` / `count`) plus exit-class parity. Fail-closed: any
  unexpected divergence is a hard error. This is the correctness gate, and it
  is what earns a shape the right to a performance verdict.
- **`bench`** — times gist cold-indexed vs ripgrep with the **same**
  bootstrap-CI + Mann-Whitney machinery the certificate uses
  (`certify/certify_stats.py`, imported — the statistics are defined once,
  never re-implemented). One fail-closed `win`/`parity`/`loss` verdict per row;
  `--publish` refreshes `matrix_baseline.json` (floors), `matrix.csv` (rows),
  and `CERTIFICATE_MATRIX.md`.
- **`gate`** — asserts the committed per-shape floors hermetically (no
  re-timing), mirroring `session/gate_session.py`. Floors are conservative:
  a `win` row's floor is 0.75× its measured speedup (≥1.0); a `parity` row
  holds a fixed 0.75× band. `--live` re-benches first (opt-in, `GIST_BENCH=1`).

## The one honest asymmetry — declared losses are report-only

A row may be born `expect="loss"`. The gate reports it but never fails on it,
so a **known** hole can never be hidden by an aggregate win — and can never be
mistaken for a regression either. Today there are **no declared losses** —
every shape is `expect="win"`. The two former holes fell to design, not
declaration:

- **`multiline-*`** (`-U`) once ran on the serial engine, forfeiting the
  parallel walk. Now `-U` rides the parallel per-file pipeline and an
  assertion-free multiline pattern answers from the byte-class DFA at
  O(1)/byte, so even the _common_ lazy-dotstar (`[\s\S]*?`) row wins.
- **`pcre-backref-files`** once scanned the whole corpus with raw PCRE2 like
  rg does (no extractable required literal). The PCRE2 shadow gate
  (`src/kernel/regex/pcre2/shadow.zig`) rewrites the pattern into a
  linear over-approximation whose DFA rejects what backtracking would have
  choked on — and whose required literal feeds the trigram index.

Should a future shape be born a loss, correctness still gates it (parity must
pass); when the design catches up, flip `expect` to `win`/`parity` and the
gate starts enforcing a floor.

## Selector quality is a dimension, not a footnote

`select` used to mean only "how many true matches" — `rare` = few, `common` =
many. That single label carries two independent costs, and the conflation hid a
real defect: the literal kernel picks two byte offsets of the needle to filter
64-byte blocks on, and the selection **collapsed to the adjacent pair `(0,1)`**
for any needle whose bytes all had equal corpus rarity — which is most lowercase
identifiers. Measured cost: **18.1 GB/s literal scan where 35.5 GB/s was
achievable** on code, and **13.1 vs 33.4 GB/s** on prose. In the shipped binary
the needle `stepSec` (7 B, few matches) ran **41% slower** than `pgxpool` (7 B,
~19x more true matches) — vastly more real work, less time.

**The suite did not catch it, and that is the interesting part.** Two holes:

- **The class was represented by its best case.** `pgxpool` was the only "rare
  literal", and it is a *lucky* needle — `pg` is a genuinely rare digraph, so it
  selects a good pair and looks fast. A degenerate needle was never asked.
- **The suite could not tell the two costs apart.** Degenerate needles *were*
  present (`error` here, `func` in the scanner lane) but labelled `common`, so
  their slowness was charged to having many true matches rather than to the
  prefilter failing. Nothing in the table could separate "slow because there is
  real work" from "slow because the prefilter collapsed".

So `select` now names the **prefilter's signal**: `selective` (a discriminating
rare byte exists), `degenerate` (every byte ties — no signal), `head-rare` /
`tail-rare` (exactly one rare byte, at a known end), with `rare`/`common` kept as
the legacy match-volume labels so committed floors stay readable.

### The standing requirement on the literal probe set

> The literal probes must **span the needle space**, and must always include at
> least one **degenerate, low-match** case. A degenerate needle with few true
> matches is the only shape whose slowness has a single possible cause: there is
> no real work to blame it on, so it can only be the prefilter. Removing
> `literal-degenerate-files` / `literal-selective-control-files`, or collapsing
> the same-class runs, is a **coverage regression** — not a cleanup. The
> `min: 1` freshness assertion above is the mechanical half of this rule; this
> paragraph is the half that says why.

Read the pair as a **ratio**, never as two absolute numbers: trap and control are
both 7 bytes and differ only in prefilter signal, so a healthy kernel keeps them
close (the trap may be marginally slower — `-l` early-exits per matching file and
the trap matches fewer files). The defect put them 41% apart the wrong way.

**And only from pairwise-interleaved samples.** Whichever needle is timed first
pays a colder page cache, and on this tree that position effect alone moves the
ratio across the alarm line: back-to-back blocks gave 1.031 with the trap first
and 0.984 with the control first, and a cold start put the *same healthy binary*
at 1.384 — indistinguishable from the 1.41 defect signature. Sampled alternately
against each other: **1.007**. So never compute this ratio by dividing two rows of
a results table; sample the trap and the control in one alternating loop.

One honest limit: **the cold-indexed lane here cannot see the timing defect.**
The trigram index elides most of the corpus for a low-match needle, so the scan
kernel barely runs — measured on this tree, trap/control is 1.04 indexed vs 1.00
un-indexed. The timing isolation therefore lives in the no-index scanner lane
(`bench/dominance/races/scanner.sh`, `SELECTOR_PROBES`); what these rows earn *here*
is **parity** — a selector that picks the wrong offset pair is a correctness bug
before it is a speed bug, and `matrix.py parity` is where that surfaces.

## Why cold-indexed vs rg (not warm here)

This matrix certifies the **cold-process product path** against ripgrep. The
**in-process ceiling** (`races/headtohead.sh`) and the **resident-product
path** (`session/`) are certified separately and kept distinct in prose and
artifacts — no path's number is ever quietly borrowed for another's claim.
