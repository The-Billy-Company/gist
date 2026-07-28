---
doc_radar:
  occurrences:
    - {file: pkg/kernels/irregex/bench/rgsuite/results.json, pattern: '"bucket": "PASS"', equals: 411}
    - {file: pkg/kernels/irregex/bench/rgsuite/results.json, pattern: '"bucket": "FAIL"', equals: 0}
    - {file: pkg/kernels/irregex/bench/rgsuite/results.json, pattern: '"bucket": "NA"', equals: 14}
    - {file: pkg/kernels/irregex/bench/rgsuite/results.json, pattern: '"bucket": "SKIP"', equals: 21}
    - {file: pkg/kernels/irregex/bench/matrix/matrix.toml, pattern: '\[\[shape\]\]', equals: 19}
  sentinels:
    - file: pkg/kernels/irregex/bench/gates/ci_order.sh
      contains:
        - "rgsuite parity (check_results.py)"
        - "CLI-shape matrix parity (matrix.py)"
        - "warm session floors (gate_session.py --committed)"
        - "CLI-shape matrix floors (matrix.py gate)"
    - description: "canary for the Layer C roofline placement quoted in §6 — a re-mint moves it, and breaking here is the signal to restate it"
      file: pkg/kernels/irregex/bench/certify/artifact/CERTIFICATE.md
      contains: "61.6 GB/s = 77% of the 79.8 GB/s single-core pure-read roof"
---

# Gist — the evidence story

Gist has several independent evidence layers. The tracked ripgrep replay is
**fully green**: 411/411 scoreable mined cases pass on each walk engine, with
zero deferred divergences. This document distinguishes a passing parity proof
from complete accounting of the surface.

The properties under test are:

1. **Index-elision identity** — the indexed cold path must equal
   `--no-index` wherever acceleration applies.
2. **Oracle parity** — a harness may claim ripgrep parity only for rows that
   actually match the live `rg` oracle at that harness's declared comparison
   bar.
3. **No false negatives from acceleration** — trigram and crest filters may
   skip only proven non-candidates; changed files are reconciled from current
   bytes.
4. **Transport identity** — eligible resident and FFI requests must preserve
   the authoritative cold answer; declining to cold is valid.
5. **Correctness before performance** — the default `ci_order.sh` path skips
   performance when a correctness gate fails. Its explicit `--allow-known`
   development option remains for historical workflows; the tracked rgsuite
   currently has no failures to bypass.

---

## 1. Unit + integration (rides `zig build test`)

Kernel, corpus, index, search, runtime, and CLI packages carry Zig tests for
the load-bearing rules: trigram extraction, query planning, freshness
overlay, crest sieve (see also [`../crest/TESTING.md`](../crest/TESTING.md)),
rank fusion inputs, argv catalog buckets, resident/cold parity, daemon
lifecycle, watcher behavior, and FFI smoke (real C compile/link/run against
`libirregex`).

Reproduce from `pkg/kernels/irregex/`:

```bash
zig build test
```

---

## 2. Ripgrep differential oracle — `bench/rgsuite/`

The mined suite compares Gist with a live `rg` oracle rather than copying
ripgrep's expected output. Parallel and serial walk engines are scored
separately because they have distinct implementations; their totals are not
added together.

The tracked ripgrep 15.2.0 snapshot contains 446 invocations **per engine**:

| bucket | count | meaning                                                   |
| ------ | ----: | --------------------------------------------------------- |
| PASS   |   411 | Gist matches the oracle at the upstream test's own bar    |
| ORDER  |     0 | byte-exact case differs only by order                     |
| FAIL   |     0 | in-scope divergence                                       |
| NA     |    14 | deliberate, documented product boundary                   |
| SKIP   |    21 | accounted companion, boundary, or irreplayable obligation |

Supported-surface parity is therefore **411/411 = 100%**.
`check_results.py` proves that every PASS/NA/SKIP is accounted for and that the
README and result artifact agree; with zero FAIL rows the strict gate passes
without `--allow-fail`.

Companion suites exercise surfaces the mined replay cannot freeze cleanly:

- `modes.py`: multiline and PCRE2, currently 30/30 each;
- `flags.py`: sorting, thread count, filesystem scope, global ignores, and
  last-wins toggles, once per walk engine;
- `transforms.py`: preprocessing, binary handling, transcoding, and compressed
  inputs, once per walk engine.

Reproduce from `pkg/kernels/irregex/bench/rgsuite/`:

```bash
python3 run.py
python3 check_results.py --allow-fail  # accounting check; known FAILs remain failures
python3 modes.py run --mode multiline
python3 modes.py run --mode pcre
python3 flags.py run --engine both
python3 transforms.py run --engine both
```

---

## 3. CLI-shape admission matrix — `bench/matrix/`

The mined replay is broad by upstream test case; the matrix is broad by
invocation shape. Its 19 declared rows span engine mode, output form, walk
scope, selectivity, and pattern kind. `parity` drives every row through three
real argv paths and compares at the row's declared set/lines/count bar:

```text
gist indexed == gist --no-index == rg
```

```bash
python3 bench/matrix/matrix.py parity
python3 bench/matrix/matrix.py gate
```

The committed performance gate currently declares no losses — every shape is
an enforced win (the former report-only holes, literal-free PCRE2
backreferences and the two multiline shapes, fell to the shadow gate and the
parallel multiline DFA). A future declared loss would stay report-only:
correctness parity always gates; only a known performance loss is non-blocking.

---

## 4. Permanent gate order — `bench/gates/`

`ci_order.sh` is the load-bearing schedule: correctness gates before
performance gates. Its correctness phase runs Zig tests, the mined rgsuite,
mode/flag/transform companions, the CLI-shape matrix, line and Unicode
parity, index-elision parity, fail-closed behavior, and filesystem freshness.

If any default correctness gate fails, the performance phase is skipped.
The tracked rgsuite now has zero FAIL rows, so a normal invocation produces an
all-green correctness verdict without `--allow-known`.

The performance phase validates the committed artifact bundle and cold ratio
floors, resident-session floors, matrix floors, compressed-input speed floor,
the macro certificate, index-size accounting, and fresh artifact integrity.
Some standalone gates documented in `bench/gates/README.md` are useful
focused proofs but are not all scheduled by `ci_order.sh`.

```bash
# from pkg/kernels/irregex/
./bench/gates/ci_order.sh
# escape hatch (no tracked rgsuite gaps remain, so this is now a no-op):
./bench/gates/ci_order.sh --allow-known
```

---

## 5. Resident session (correctness and latency are separate)

The warm UDS path (`src/exec/session/`) is an accelerator with a narrow
eligibility classifier. Zig tests pin answer identity and lifecycle behavior:

- eligible file-list and line-output requests preserve cold bytes and exit
  status; the wire also supports a corpus-wide count for embedders;
- explicit paths, readable stdin, TTY output, context, JSON, rank,
  replacement, multiline, and other unsupported warm shapes stay cold;
- macOS kqueue and Linux inotify can arm the watcher-clean fast path, while
  the reconcile barrier remains the safety authority;
- doubt, overflow, index-generation change, or walk error → decline warm,
  return to subprocess;
- declined warm never fabricates an empty success.

The latency gate does **not** prove correctness. It reads the published
session artifact and enforces the speed floor only when that artifact says
the watcher fast path was armed:

```bash
python3 bench/session/gate_session.py --committed
GIST_BENCH=1 python3 bench/session/gate_session.py --live
```

---

## 6. Certificate layers — `bench/certify/`

The certificate is a measured, machine- and corpus-specific evidence bundle.
Its layers answer narrower questions than the phrase "optimality" can imply:

| layer | evidence actually produced                                                                                                             | harness                                          |
| ----- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| A     | empirical cold-process comparison on 12 query classes; a win requires a lower median **and** Mann–Whitney p < 0.05                     | `zig build certify` + `bench/certify/certify.sh` |
| B/B′  | static port-pressure bounds on modeled reference CPUs plus native PMU measurements of drift-guarded hot-loop probes                    | `bench/portcert/`                                |
| C     | measured scan throughput placed against this machine's STREAM-style cache/DRAM ceilings                                                | `bench/roofline/`                                |
| D     | structural audit that the verifier touches admitted candidate bytes once (DFA) or fewer (SIMD), with verdict parity against production | `bench/lowerbound/`                              |

Important limits:

- Layer A's wins apply to the recorded corpus, hardware, tool versions, and
  12 classes; they are not a universal performance theorem.
- Layer B bounds the measured instruction sequences and modeled CPUs, not
  every possible implementation.
- Layer C reports and decomposes distance from a measured ceiling. The
  committed absent-needle scan is 61.6 GB/s against a 79.8 GB/s DRAM read
  ceiling (77%); below the pre-registered 80% near-roof threshold, so it
  proves material headroom, not DRAM saturation.
- Layer D proves one-pass verification over the candidate set admitted by the
  current filter. It does not prove that this candidate set is globally
  minimal among all possible indexes or that no different search algorithm
  can do less work on non-adversarial inputs.

Committed artifact:
[`bench/certify/artifact/CERTIFICATE.md`](../../bench/certify/artifact/CERTIFICATE.md).
Do not hand-edit — re-run to refresh. Repo-level entry:

```bash
make bench-gist-certify
# full mint + publish:
CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify
```

The current driver runs `certify_layers.sh` to splice B/B′/C/D after Layer A;
the older manual re-splice warning no longer describes the default full-mint
path. Numbers in product READMEs must cite the committed artifact rather than
being presented as universal constants.

---

## 7. Crest sieve evidence (sibling dossier)

Class-repetition pruning soundness (`matched ⇒ ¬pruned`) is Crest's
obligation: corpus-wide fail-closed harness (`zig build crest`), randomized
adversarial sweeps, count-cousin ablation. Inventory:
[`../crest/TESTING.md`](../crest/TESTING.md). Gist's product gates treat a
missing/invalid crest sidecar as sieve-off, never as authority to prune.

---

## 8. Reading verdicts correctly

| failure class                                              | correct fix                                                                                                                     |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| indexed ≠ `--no-index`                                     | fix elision / freshness — never weaken the equality gate                                                                        |
| rg oracle FAIL on scoreable surface                        | it remains a product gap even when phase-tracked; fix Gist, or reclassify only if it is genuinely outside the declared contract |
| `check_results.py --allow-fail` passes                     | accounting is internally consistent; it is not full oracle parity                                                               |
| warm returns stale / empty success                         | decline path must fire — never invent answers                                                                                   |
| certificate numbers exist while default correctness is red | the artifact is historical/measured evidence, not proof that today's full correctness slate passes                              |
| matrix reports a declared loss                             | correctness passed; that shape's performance remains explicitly below expectation                                               |
| crest false negative                                       | fix `src/kernel/math/crest.zig` calculus — see crest TESTING                                                              |

Authority is split deliberately: `gist --schema` defines the public CLI
surface; differential harness outputs define current compatibility; Zig
tests define internal invariants; committed certificate artifacts define
recorded performance. This page summarizes those sources and must not
upgrade a tracked exception into a pass.
