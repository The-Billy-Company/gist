---
doc_radar:
  sentinels:
    - description: "Layer D consumes the shared first and last certificate classes"
      file: pkg/kernels/irregex/bench/harness/probes.zig
      contains: ['.class = "literal-rare"', '.class = "regex-litalt"']
    - description: "the generated certificate cites the current production kernels"
      file: pkg/kernels/irregex/bench/lowerbound/lowerbound_report.py
      contains: ["src/kernel/scan/simd.zig", "src/kernel/regex/linear/dfa/dfa.zig"]
---

# gist/bench/lowerbound — Layer D (algorithmic lower bound)

Layer D of gist's [Dominance-and-Fit Certificate](../README.md#dominance-and-fit-certificate-layers-ag).
Where Layer A proves empirical dominance over ripgrep on the registered
workloads and Layer C places its cycles/byte against the _hardware_ ceiling,
Layer D proves the last thing
left to prove: gist's **algorithm** matches the **information-theoretic floor**
for the search operation — no algorithm on any machine can do asymptotically
less work.

## What it is

A **fail-closed, structural byte-touch audit**. `gist-lowerbound` builds the
trigram index over the real Billy corpus, then for each of the twelve regex
classes (imported from [`../harness/probes.zig`](../harness/probes.zig), the
_same_ module [`certify.zig`](../harness/certify.zig) uses, so Layer D lines
up 1:1 with Layers A–C by construction, not by a hand-kept copy) it measures:

- **candidate bytes** — Σ lengths of the documents the trigram filter admits
  (the full-scan verify floor);
- **passes / candidate byte** — the bytes an _independent single-pass
  re-implementation_ touches ÷ candidate bytes;
- **cand%** — candidate bytes ÷ corpus bytes (the pruning the filter achieves).

`lowerbound_report.py` splices the formal argument + the measured table into
`.local/gist-verify/CERTIFICATE.md` as the `## Layer D` section.

No production code is instrumented. The audit is _structural_: it re-implements
the fused scan in the harness with a byte counter, asserts (a) that reference's
match verdict equals gist's **real** verify (`simd.contains` / `Regex.docMatch`)
on **every** document — a disagreement is a real correctness defect — and (b)
that the fused DFA path touches **exactly** the floor while the SIMD literal
path stays **≤** it.

## Why it exists

"Fastest it can mathematically be" is a claim you either prove or don't make.
The floor has two independently-citable parts, and gist meets both — measured,
not asserted:

1. **The verify stage is Ω(candidate bytes), in one pass.** Deciding whether a
   pattern occurs in a candidate document forces you, in the worst (adversarial)
   case, to examine every one of its bytes: an unread byte could _be_ the match,
   or could _break_ one — the adversary sets it after you commit. gist's fused
   byte-class DFA (`src/kernel/regex/linear/dfa/dfa.zig`) reads each candidate
   byte **exactly once** — `passes ≡ 1.0000` for every DFA class — with none of
   the memchr-then-rescan _double_ byte-traffic a per-line matcher pays. The SIMD
   literal path (`src/kernel/scan/simd.zig`) reads **≤ N** through vector
   first/last-byte skips and early exit on the first hit. A **dense class**
   (`\w{3,8}`) is served in production by the SIMD class-run kernel
   (`src/kernel/scan/classrun.zig`), which skips DFA construction entirely;
   Layer D certifies its floor against an independent one-pass DFA reference it
   force-builds for the same pattern, asserting `docMatch` agrees on **every**
   candidate document — so the class-run verdict is pinned to an exact-one-pass
   oracle.

2. **The trigram filter makes total work sublinear.** gist never touches most of
   the corpus, because the index prunes candidates _before_ verify runs. On this
   corpus the selective classes admit only a measured fraction of the bytes;
   the generated certificate records that live fraction and its complement.

Together: trigram prune → single fused verify pass = the minimum reads any
correct algorithm can make. **12/12 classes at the floor, fail-closed.**

The gate is proven non-tautological by fault injection: adding a single extra
byte-read per line drives `passes` to 1.02 and trips a hard `exit 1`.

## How to run

```bash
# 1. Layer A must exist first (Layer D splices into its CERTIFICATE.md):
zig build certify                       # or: gist-bench certify

# 2. build + run the Layer D audit (parent wires the `lowerbound` build step;
#    until then it runs as its own executable):
zig build lowerbound                    # → .local/gist-verify/lowerbound.csv

# 3. splice the Layer D section into the certificate:
python3 pkg/kernels/irregex/bench/lowerbound/lowerbound_report.py \
    --csv .local/gist-verify/lowerbound.csv \
    --certificate .local/gist-verify/CERTIFICATE.md
```

`gist-lowerbound` exits non-zero (mirroring
[`gates/scan_regress.sh`](../gates/scan_regress.sh)) if any candidate byte is
read past the single-pass floor, or if the independent reference disagrees with
gist's real verify — a failure is a real finding about gist, never something to
paper over by weakening the assertion.

## Prior art

- **Donald E. Knuth, James H. Morris, Vaughan R. Pratt, "Fast Pattern Matching
  in Strings" (1977), _SIAM Journal on Computing_ 6(2):323–350.** The
  linear-time exact string-match result; establishes the Θ(n+m) worst case and,
  with it, the Ω(n) worst-case _read_ floor for verifying a match.
- **Robert S. Boyer, J Strother Moore, "A Fast String Searching Algorithm"
  (1977), _Communications of the ACM_ 20(10):762–772.** Sublinear on _average_
  (skips via the bad-character / good-suffix heuristics — Ω(n/m) reads minimum),
  but still Ω(n) in the adversarial worst case. gist's SIMD literal path is in
  this family (first/last-byte vector skips), which is why it reads **≤** the
  candidate-byte floor.
- **Russ Cox, "Regular Expression Matching with a Trigram Index, or How Google
  Code Search Worked" (2012), <https://swtch.com/~rsc/regexp/regexp4.html>.**
  The trigram-index prefilter that makes whole-corpus search sublinear for
  selective patterns — gist's direct ancestor (see also `../README.md` and
  `src/kernel/regex/linear/dfa/dfa.zig`, which cites Cox's linear-time NFA/DFA work). The `cand%`
  column is the empirical measure of this pruning.
- gist's own [`../harness/probes.zig`](../harness/probes.zig) — the shared
  probe-class registry [`certify.zig`](../harness/certify.zig) (Layer A) also
  imports, so the four layers of the certificate speak about the same twelve
  classes by construction.
