---
doc_radar:
  sentinels:
    - description: "evaluator keeps its closed verb set + contract-bound schema"
      file: bench/dominance/evaluate/evaluate.py
      contains: ['sub.add_parser("run"', 'sub.add_parser("verify"', 'sub.add_parser("compare"', 'sub.add_parser("brief"']
    - description: "verifier enforces the parity precondition + fail-closed operational gates"
      file: bench/dominance/evaluate/report.py
      contains: ["_verify_parity_gate", "_verify_operational", "verify_claims"]
---

# `bench/evaluate/` — the gist operational-envelope matrix

The [Dominance-and-Fit Certificate](../../certificate/) is the deep, narrow proof of how
good and how measurably bounded Gist is **at full speed**: cold fresh-process
dominance vs ripgrep, single-thread cycles/byte, the warm resident-daemon tier,
rg drop-in correctness, and the port/roofline/lower-bound/crest layers. This
module is its **operational complement** — the envelope the certificate does not
measure: index **lifecycle** cost (build + incremental refresh), **resource**
footprint (index/corpus ratio, peak RSS, scan throughput), **scaling** shape,
and **concurrency** (aggregate qps + tail under many-agent load).

It never re-times cold/warm query dominance or restates a correctness number —
those live in the certificate, and duplicating them here would only invite
drift. It is one closed-verb CLI over the regimes frozen in
`irregex/contract/performance_evidence.toml`,
reusing the existing race registry (`_compete.sh`), the hyperfine harness, and
the certificate statistics rather than re-encoding them.

## The core policy

**Absolute latency is machine-specific and is never gated across machines.** A
bundle records absolute numbers for its own machine only. What travels between
machines — and what the aggregate report compares — is hardware-invariant by
construction: the **resource ratio** (index bytes / corpus bytes) and **scaling
shape**. Absolute build ms, RSS, and qps stay machine-local. Byte-exact
correctness vs the ripgrep oracle is a per-run **precondition** (parity before
timing), not a published dominance claim — that is the certificate's rgsuite.
There is no universal millisecond floor.

## Verbs

```bash
python3 bench/dominance/evaluate/evaluate.py run       # measure THIS machine → bundle + report
python3 bench/dominance/evaluate/evaluate.py run --publish   # commit a verified, clean-tree bundle
python3 bench/dominance/evaluate/evaluate.py verify    # hermetic: check committed bundles + claims (CI path)
python3 bench/dominance/evaluate/evaluate.py compare --a A/bundle.json --b B/bundle.json
python3 bench/dominance/evaluate/evaluate.py brief     # digest of committed bundles
python3 bench/dominance/evaluate/evaluate.py run --foreign   # adds the foreign-corpus scale lane
```

## Regimes (measurement lanes)

Cold/warm query dominance is deliberately **absent** — that is the certificate's
Layer A. These are the operational lanes it does not measure:

| Regime        | What it times                                               | Cross-machine gate     |
| ------------- | ----------------------------------------------------------- | ---------------------- |
| `lifecycle`   | full build, first query, incremental add/edit/delete/rename | —                      |
| `resource`    | peak RSS, index/corpus ratio, scan throughput               | index/corpus **ratio** |
| `scale`       | latency + build across foreign corpora (size × shape)       | curve **shape**        |
| `concurrency` | aggregate qps + tail latency at bounded workers             | —                      |

Every lane is gated on a **byte-exact parity precondition vs rg on BOTH engines**
(parallel + serial) first — a build-sanity check that this gist produces
rg-identical results before its timings are trusted, not a published correctness
claim. A value that cannot be measured is recorded as an honest null (surfaced in
the report), never fabricated, never dropped from the denominator.

## Files

- [`evaluate.py`](evaluate.py) — CLI + on-disk bundle schema; orchestrates the lanes.
- [`regimes.py`](regimes.py) — the measurement lanes (reuse `_compete.sh`, hyperfine, `certify_stats`).
- [`provenance.py`](provenance.py) — machine / corpus / tool capture (importable, shared).
- [`report.py`](report.py) — hermetic verify + claim freshness + aggregate + compare.
- [`artifact/`](artifact/) — committed, verified per-machine bundles + `REPORT.md`.
- `test_evaluate.py` — adverse tests over the verifier + aggregator.

## Publication

Raw per-run output lands in `.local/gist-evaluation/<machine-id>/` (gitignored).
`run --publish` copies a **contract-verified, clean-tree** `bundle.json` into
`artifact/<machine-id>/` and regenerates `artifact/REPORT.md`. A dirty tree is
refused at publish and the bundle is flagged `exploratory` so it can never
masquerade as evidence. Mac-arm64 and Anvil-linux-x86_64 stay in separate
per-machine directories — never averaged into one blended number.

See `irregex/contract/engine.toml`
and the certificate's [`certificate/README.md`](../../certificate/README.md).
