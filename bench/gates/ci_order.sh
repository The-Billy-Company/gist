#!/usr/bin/env bash
# §15 — the canonical gist CI order: CORRECTNESS gates first, PERFORMANCE last.
#
# The rule the audit asked for: a benchmark verdict is only trustworthy once the
# thing it times is proven correct. So this runner executes every correctness gate
# first and refuses to run (or trust) the performance certificate until they ALL
# pass. It is the one command CI shells to enforce that ordering.
#
#   correctness : zig build test · rgsuite parity · line-output parity ·
#                 index-elision parity · fail-closed contract · freshness
#   performance : certify.sh · certificate-artifacts · index-size accounting
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

correctness_failed=0
run() { # <label> <cmd...>
  echo "── ${1}"
  shift
  if "$@"; then
    echo "   PASS"
  else
    echo "   FAIL (exit $?)"
    correctness_failed=$((correctness_failed + 1))
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
run "line-output parity (line_parity.sh)" bash bench/gates/line_parity.sh
run "index-elision parity (index_elision_parity.sh)" bash bench/gates/index_elision_parity.sh
run "fail-closed contract (fail_closed.sh)" bash bench/gates/fail_closed.sh
run "freshness (freshness_fs.sh)" bash bench/gates/freshness_fs.sh

echo
echo "═══ PHASE 2 · PERFORMANCE (only after correctness is clean) ═══"
if [[ "${correctness_failed}" -ne 0 ]]; then
  echo "SKIPPED: ${correctness_failed} correctness gate(s) failed — a perf verdict over unproven"
  echo "behavior is untrustworthy. Fix correctness (or re-run with --allow-known), then rerun."
  exit 1
fi
missing=""
for t in hyperfine csearch zoekt rg; do command -v "${t}" > /dev/null || missing="${missing} ${t}"; done
if [[ -n "${missing}" ]]; then
  echo "SKIPPED: perf tools not on PATH (${missing# }). Correctness passed; the certificate"
  echo "needs the full field (rg/csearch/zoekt) + hyperfine. Install them to certify."
  exit 0
fi
run "macro certificate (certify.sh)" bash bench/certify/certify.sh
run "certificate artifacts (check_artifacts.py)" python3 bench/certify/check_artifacts.py --artifacts
run "index-size accounting (index_size_accounting.py)" python3 bench/gates/index_size_accounting.py

echo
if [[ "${correctness_failed}" -eq 0 ]]; then
  echo "OK: correctness clean; performance certificate produced."
else
  exit 1
fi
