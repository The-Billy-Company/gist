# Gist — the complete evidence story

Every layer of Gist is tested at the level where its failure would be
invisible elsewhere, and every soundness gate is **fail-closed**: a
violation exits non-zero, and the fix is always the product or the calculus,
never the assertion (sins.mdc Sin #2 — no bandaids).

The properties that matter:

1. **Answer identity** — indexed path ≡ `--no-index` path ≡ (when eligible)
   warm path, for every supported request.
2. **Oracle parity** — stdout + exit code match a live ripgrep oracle on the
   scoreable surface (documented NAs are explicit product differences, never
   silent).
3. **No false negatives from acceleration** — trigram elision and crest
   pruning may only skip files that cannot match; freshness exempts changed
   files.
4. **Correctness before speed** — a faster wrong answer cannot earn a
   Certificate win.

---

## 1. Unit + integration (rides `zig build test`)

Kernel, corpus, index, search, runtime, and CLI packages carry Zig tests for
the load-bearing rules: trigram extraction, query planning, freshness
overlay, crest sieve (see also [`../crest/TESTING.md`](../crest/TESTING.md)),
rank fusion inputs, argv catalog buckets, resident request classifier, and
FFI smoke (real C compile/link/run against `libirregex`).

Reproduce from `pkg/kernels/irregex/`:

```bash
zig build test
```

---

## 2. Ripgrep differential oracle — `bench/rgsuite/`

I compare gist with a live `rg` oracle instead of writing expectations by
hand. Parallel and serial walk engines are scored separately (same contract,
different implementation paths — never added together to inflate counts).

Recorded slate against ripgrep 15.1.0 (refresh by re-running; prose is not
the authority):

| suite | result shape |
|---|---|
| mined upstream | 441 rg invocations × both engines; scoreable surface 306/306 PASS, 0 ORDER, 0 FAIL; NA = documented difference; SKIP = unscored assertion |
| multiline | 30/30 — stdout, exit, indexed≡`--no-index` |
| PCRE2 (`-P`) | 30/30 — lookaround, backreferences, Unicode toggles, resource-limit failures |
| walk / ignore flags | 26/26 per engine |
| content transforms | 22/22 per engine (preprocess, binary, encodings, gzip/bzip2/xz/zstd/lz4/Brotli) |

Reproduce from `pkg/kernels/irregex/bench/rgsuite/`:

```bash
python3 run.py
python3 modes.py run --mode multiline
python3 modes.py run --mode pcre
python3 flags.py run
python3 transforms.py run
```

---

## 3. Permanent gate order — `bench/gates/`

`ci_order.sh` is the load-bearing schedule: correctness gates before
performance gates. Representative gates:

| gate | pins |
|---|---|
| line / Unicode / stream parity | framing and encoding vs oracle |
| PCRE2 parity (`-P`) | backtracking lane matches selected semantics |
| index-elision parity | indexed ≡ `--no-index` on covering queries |
| freshness | edits since anchor are visible |
| fail-closed certificate prelude | speed work never runs on a red correctness slate |

```bash
# from pkg/kernels/irregex/
./bench/gates/ci_order.sh
```

---

## 4. Resident session (fail-open, not fail-silent)

The warm UDS path (`src/runtime/session/`) is an accelerator with a narrow
eligibility classifier. Tests and gates pin:

- ineligible shapes (paths, stdin, TTY, context, JSON, rank, replacement,
  multiline, …) stay cold;
- FSEvents/inotify may narrow work, but a reconcile barrier decides safety;
- doubt, overflow, index-generation change, or walk error → decline warm,
  return to subprocess;
- declined warm never fabricates an empty success.

---

## 5. Certificate of Optimality — `bench/certify/`

Performance claims are measured artifacts, not vibes. Four layers, cheapest
evidence first:

| layer | question | harness |
|---|---|---|
| A | empirical dominance vs field (fail-closed: lower median **and** Mann–Whitney p < 0.05) | `zig build certify` + `bench/certify.sh` |
| B | port-optimality (llvm-mca vs hot loop) | `bench/portcert/` |
| C | roofline (cycles/byte on hardware ceiling) | `zig build roofline` |
| D | algorithmic lower bound | `zig build lowerbound` |

Committed artifact:
[`bench/certify/artifact/CERTIFICATE.md`](../../bench/certify/artifact/CERTIFICATE.md).
Do not hand-edit — re-run to refresh. Repo-level entry:

```bash
make bench-gist-certify
# full mint (when needed): CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 …
```

Honesty rule: Layer A rewrites the whole certificate file; Layers B–D must
be re-spliced afterward per each layer's README. Numbers in product READMEs
cite this artifact and are not universal constants.

---

## 6. Crest sieve evidence (sibling dossier)

Class-repetition pruning soundness (`matched ⇒ ¬pruned`) is Crest's
obligation: corpus-wide fail-closed harness (`zig build crest`), randomized
adversarial sweeps, count-cousin ablation. Inventory:
[`../crest/TESTING.md`](../crest/TESTING.md). Gist's product gates treat a
missing/invalid crest sidecar as sieve-off, never as authority to prune.

---

## 7. What a failure means

| failure class | correct fix |
|---|---|
| indexed ≠ `--no-index` | fix elision / freshness — never weaken the equality gate |
| rg oracle FAIL on scoreable surface | fix gist — or promote to documented NA with schema + README |
| warm returns stale / empty success | decline path must fire — never invent answers |
| Certificate win with red correctness | impossible under `ci_order.sh`; do not reorder |
| crest false negative | fix `src/math/crest.zig` calculus — see crest TESTING |

The product contract (`gist --schema`), this evidence inventory, and the
committed certificate are the three authorities. Prose follows them.
