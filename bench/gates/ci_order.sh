#!/usr/bin/env bash
# §15 — the canonical gist CI order: CORRECTNESS gates first, PERFORMANCE last.
#
# The rule the audit asked for: a benchmark verdict is only trustworthy once the
# thing it times is proven correct. So this runner executes every correctness gate
# first and refuses to run (or trust) the performance certificate until they ALL
# pass. It is the one command CI shells to enforce that ordering.
#
#   correctness : zig build test · rgsuite parity · line-output parity ·
#                 index-elision parity · enumeration determinism ·
#                 fail-closed contract · freshness
#   performance : certify.sh · certificate-artifacts · ratio regression ·
#                 index-size accounting
#
# Flags:
#   --gates-only   skip `zig build test` (fast orchestration check)
#   --allow-known  pass --allow-fail to the rgsuite gate (treat the tracked FAILs
#                  as non-blocking so a dev can reach the perf phase)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
cd "${KERNEL}" || exit 1

gates_only=0
allow_known=0
for a in "$@"; do case "${a}" in
  --gates-only) gates_only=1 ;;
  --allow-known) allow_known=1 ;;
  *)
    echo "unknown arg: ${a}" >&2
    exit 2
    ;;
esac done

failures=0
run() { # <label> <cmd...>
  echo "── ${1}"
  shift
  if "$@"; then
    echo "   PASS"
  else
    echo "   FAIL (exit $?)"
    failures=$((failures + 1))
  fi
}

echo "═══ PHASE 1 · CORRECTNESS ═══"
if [[ "${gates_only}" -eq 0 ]]; then
  run "zig build test" zig build test
else
  echo "── zig build test (skipped: --gates-only)"
fi
if [[ "${allow_known}" -eq 1 ]]; then
  run "rgsuite parity (check_results.py --allow-fail)" python3 bench/rgsuite/check_results.py --allow-fail
else
  run "rgsuite parity (check_results.py)" python3 bench/rgsuite/check_results.py
fi
# The `-U`/`-P` modes rgsuite defers (mined-suite boundaries #1/#6): the
# hand-authored differential proof for exactly those two, both fully green
# (`run.py` marks them NA/SKIP). Blocking here so a multiline/PCRE2 regression
# can never reach the perf phase. See `bench/rgsuite/modes.py`.
run "multiline parity -U (modes.py)" python3 bench/rgsuite/modes.py run --mode multiline
run "pcre parity -P (modes.py)" python3 bench/rgsuite/modes.py run --mode pcre
# The indexed-PCRE2 win — gist runs PCRE2 behind a trigram/shadow prefilter, the
# one capability no competitor has — proven RIGHT, not just self-consistent. The
# oracle is Python's stdlib `re` (an independent engine lineage) scanning the raw
# corpus bytes; the corpus plants literal-carrying decoys, shadow-splices, and a
# noise floor a naïve prefilter would mis-elide. Each pattern is a THREE-WAY diff:
# idx == oracle (independent parity) AND idx == --no-index (index safety). Blocking
# so a required-literal over-claim (a silent false negative) can't reach the perf
# phase — this gate caught exactly that. See `bench/gates/indexed_pcre_oracle.py`.
run "indexed-PCRE2 oracle (indexed_pcre_oracle.py)" python3 bench/gates/indexed_pcre_oracle.py run
# The walk/order/ignore flags the mined suite can't pin (results depend on file
# timestamps, device ids, thread counts, and global git config): --sort/--sortr/
# --sort-files, -j/--threads, --one-file-system, --no-ignore-global, and the
# negation last-wins toggles. Hand-authored differential proof, ripgrep the
# oracle, once per engine. Blocking here so an ordering/ignore regression can't
# reach the perf phase. See `bench/rgsuite/flags.py`.
run "flags parity (flags.py, both engines)" python3 bench/rgsuite/flags.py run --engine both
# The content-transform flags rgsuite can't mine from plain source (-z decompress,
# --pre preprocess, -E transcode, --binary NUL search): hand-authored differential
# vs rg over minted fixtures, once per engine, each also asserting indexed ==
# --no-index. Blocking so a transform regression can't reach the perf phase. See
# `bench/rgsuite/transforms.py`.
run "transforms parity -z/--pre/-E/--binary (transforms.py, both engines)" python3 bench/rgsuite/transforms.py run --engine both
# The CLI-shape admission matrix: one row per supported shape (mode × flags ×
# walk-scope × emit × selectivity), each driven as REAL argv three ways and
# asserted gist-idx == gist-noidx == rg at its bar (set/lines/count + exit class).
# Blocking so a per-shape parity or index-elision regression can't reach the perf
# phase. See `bench/matrix/`.
run "CLI-shape matrix parity (matrix.py)" python3 bench/matrix/matrix.py parity
run "line-output parity (line_parity.sh)" bash bench/gates/line_parity.sh
run "Unicode parity (unicode_parity.sh)" bash bench/gates/unicode_parity.sh
run "index-elision parity (index_elision_parity.sh)" bash bench/gates/index_elision_parity.sh
run "enumeration determinism (enum_determinism.sh)" bash bench/gates/enum_determinism.sh
run "fail-closed contract (fail_closed.sh)" bash bench/gates/fail_closed.sh
run "freshness (freshness_fs.sh)" bash bench/gates/freshness_fs.sh

echo
echo "═══ PHASE 2 · PERFORMANCE (only after correctness is clean) ═══"
if [[ "${failures}" -ne 0 ]]; then
  echo "SKIPPED: ${failures} correctness gate(s) failed — a perf verdict over unproven"
  echo "behavior is untrustworthy. Fix correctness (or re-run with --allow-known), then rerun."
  exit 1
fi
# Bundle provenance is recorded in machine.git_commit as a reference only —
# integrity is judged from the committed bytes, never from the current HEAD.
# What the certificate claimed over time is in bench/certify/LEDGER.md.
set +e
python3 bench/certify/check_artifacts.py \
  --artifacts-dir bench/certify/artifact --artifacts
art_rc=$?
set -e
case "${art_rc}" in
  0)
    echo "OK: committed certificate bundle"
    run "cold speedup floors (ratio_regress.py --committed)" \
      python3 bench/certify/ratio_regress.py --committed
    ;;
  2)
    echo "NOTE: no committed certificate yet — regenerate with"
    echo "      CERT_FULL=1 CERT_PUBLISH=1 CERT_SUDO=1 make bench-gist-certify"
    echo "      (or CERT_PUBLISH_DIR=bench/certify/artifact bash bench/certify/certify.sh)"
    echo "      on a clean tree (or isolated git worktree)."
    ;;
  *)
    echo "FAIL: committed certificate bundle"
    failures=$((failures + 1))
    echo "SKIPPED: committed evidence bundle is invalid; refusing to replace it with an unvalidated run."
    exit 1
    ;;
esac
# Warm (resident-session) evidence: committed + hermetic (no daemon, no timing),
# and armed-only — report-only on an unarmed platform's freshness-taxed number.
run "warm session floors (gate_session.py --committed)" \
  python3 bench/session/gate_session.py --committed
# Per-shape cold floors: every non-loss matrix row cleared its committed floor at
# publish time (hermetic — no re-timing on this shared box). Declared `loss` rows
# (serial -U, literal-less backref) are report-only so no aggregate buries them.
run "CLI-shape matrix floors (matrix.py gate)" \
  python3 bench/matrix/matrix.py gate
# The flags agents reach for most (-i/-n/-v/-l/-c/-o/-w/-r): each self-checks
# byte-identity as it profiles (the -v/-l/-c paths against independent oracles;
# -o/-w/-r byte-identity is the parity gates above), then its one hot function
# clears a conservative regression floor — the caseless tax and writeDecimal
# speedup are same-run ratios (jitter cancels), the emit-mode floors absolutes far
# below observed. Blocking under --gate. No external tool needed, so it runs
# before the hyperfine/rg field check.
run "flag hot-path floors (flagbench --gate)" \
  zig build flagbench -- pkg/kernels/irregex/src --gate
missing=""
for t in hyperfine csearch zoekt rg; do command -v "${t}" > /dev/null || missing="${missing} ${t}"; done
if [[ -n "${missing}" ]]; then
  echo "SKIPPED: perf tools not on PATH (${missing# }). Correctness passed; the certificate"
  echo "needs the full field (rg/csearch/zoekt) + hyperfine. Install them to certify."
  exit 0
fi
# The -z decode-speed regression floor: gist's in-process `std.compress` decode
# of the common formats must stay materially faster than rg's fork-a-decompressor-
# per-file (blocking `--floor-rg`, conservative vs the real ~5-15x so jitter never
# false-trips). Back-to-back over identical bytes, so hardware cancels. See
# `bench/rgsuite/transforms.py` `do_bench`.
run "-z decode speed floor (transforms.py bench)" python3 bench/rgsuite/transforms.py bench
run "macro certificate (certify.sh)" bash bench/certify/certify.sh
run "index-size accounting (index_size_accounting.py)" python3 bench/gates/index_size_accounting.py
run "fresh certificate artifacts (check_artifacts.py)" python3 bench/certify/check_artifacts.py --artifacts --require-head

echo
if [[ "${failures}" -eq 0 ]]; then
  echo "OK: correctness clean; fresh and committed performance evidence validated."
else
  exit 1
fi
