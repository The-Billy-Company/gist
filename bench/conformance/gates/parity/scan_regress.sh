#!/usr/bin/env bash
# gist no-prefilter regression + race — the permanent guard for patterns that
# defeat the trigram prefilter (no ≥3 B required literal, no all-≥3 alternation
# cover), so the unified `ripgrep/` engine's tree-walk falls back to reading and
# regex-scanning every candidate itself instead of eliding files the index
# proves can't match. equality.sh proves the index-elision path against a frozen
# snapshot; this proves the full-read fallback against the LIVE tree, which
# needs its own soundness oracle since it's a different traversal.
#
# Two things, both kept permanent so the win can't silently rot and the next
# exploration starts from a measured floor (prove with measurement, not assertion):
#
#   1. SOUNDNESS (the gate). gist's match-set must equal plain `rg (?-u) -l` over
#      the SAME roots — gist's tree-walk now honors `.gitignore` and excludes
#      hidden files exactly like rg's default (no `--no-ignore`/`--hidden` skew;
#      confirmed byte-for-byte against `rg` for regular, non-ignored files). A
#      file in rg's set but not gist's is a FALSE NEGATIVE (a candidate scan may
#      never drop a true match). Files above gist's 4 MiB per-file cap are called
#      out separately, but remain a semantic mismatch and block timing: a race
#      cell is only valid when the complete file sets are exact. A file in gist's
#      set but not rg's is a FALSE POSITIVE. Any mismatch ⇒ exit 1. (There's no
#      separate stderr
#      announcement for "took the no-prefilter path" in the unified engine — the
#      index only elides reads, it never changes the result — so this no longer
#      asserts routing, only the output soundness + the speed floor below.)
#
#   2. SPEED + PIPELINE BALANCE (the exploration floor, informational). min-of-N
#      wall-clock vs rg on its fastest gitignore-respecting path, plus the
#      worker-span Δ scan.zig prints — the straggler regression canary. The scan
#      tier is pattern-INDEPENDENT for gist (it sits at the per-file syscall floor,
#      the DFA being one early-exiting pass) and pattern-DEPENDENT for rg (floor +
#      per-byte scan), so gist wins every scan-expensive pattern and ties the
#      cheapest sparse-literal — read the numbers, don't assume.
#
# Usage: bench/scan_regress.sh [runs]   (default runs=12)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../dominance/races/field.sh
source "${HERE}/../../../dominance/races/field.sh"

RUNS="${1:-12}"
PER_FILE_CAP=$((4 << 20)) # mirrors corpus.zig per_file_cap (4 MiB)
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The no-prefilter slate — patterns lacking a ≥3 B required literal AND an
# all-≥3 alternation cover, so the trigram index can't elide a single read.
PATTERNS=('\w{3,8}' '[a-f0-9]{2,}' '[a-z]+_[a-z]+_[a-z]+' '[0-9]{4}' 'panic|0x')

command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}
need_hyperfine

echo "building gist (ReleaseFast) + copying binary…"
# Fail-closed: the default install step COMPILES + installs the `gist` binary
# without running it, so a nonzero exit is an unambiguous build failure. (The old
# `cli -- 'zzqqxxv' -l` form RAN the fresh binary against a non-matching needle,
# whose exit 1 is indistinguishable from a compile error's exit 1 — the trailing
# `true` papered over both, letting compete_install_gist_bin copy a stale binary.)
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) \
  || {
    echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
    exit 1
  }
compete_install_gist_bin || exit 1

fsize() { stat -f%z "$1" 2> /dev/null || stat -c%s "$1" 2> /dev/null || echo 0; }

cd "${REPO}" || exit 1
echo
echo "### SOUNDNESS — gist ≡ rg over the live tree, no-prefilter patterns (the gate) ###"
fails=0
for p in "${PATTERNS[@]}"; do
  gcmd="$(compete_rgx_cmd gist "${p}")"
  rcmd="$(compete_rgx_cmd rg "${p}")"
  if ! compete_capture_set "${gcmd}" "${TMP}/gist" "${p}/gist" \
    || ! compete_capture_set "${rcmd}" "${TMP}/rg" "${p}/rg"; then
    printf "  %-22s HARD ERROR\n" "${p}"
    fails=$((fails + 1))
    continue
  fi
  comm -12 "${TMP}/gist" "${TMP}/rg" > "${TMP}/shared"
  comm -23 "${TMP}/gist" "${TMP}/rg" > "${TMP}/fp" # gist-only
  comm -13 "${TMP}/gist" "${TMP}/rg" > "${TMP}/rgonly"
  shared="$(wc -l < "${TMP}/shared" | tr -d ' ')"
  fp="$(wc -l < "${TMP}/fp" | tr -d ' ')"
  fn=0
  cap=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    sz="$(fsize "${f}")"
    if [[ "${sz}" -gt "${PER_FILE_CAP}" ]]; then cap=$((cap + 1)); else fn=$((fn + 1)); fi
  done < "${TMP}/rgonly"
  status="ok"
  if [[ "${fn}" -gt 0 || "${fp}" -gt 0 || "${cap}" -gt 0 ]]; then
    status="FAIL"
    fails=$((fails + 1))
  fi
  printf "  %-22s shared=%-6s FN=%-3s FP=%-3s cap_skip=%-3s  %s\n" "${p}" "${shared}" "${fn}" "${fp}" "${cap}" "${status}"
done

if [[ "${fails}" -ne 0 ]]; then
  echo
  echo "FAILED: ${fails} pattern(s) diverged or hard-failed. SPEED SKIPPED: unproven cells are never timed."
  exit 1
fi

echo
echo "### SPEED (min of ${RUNS}) — no-prefilter patterns, full-read floor ###"
printf "  %-22s %9s %9s %8s\n" pattern gist_ms rg_ms verdict
for p in "${PATTERNS[@]}"; do
  gcmd="$(compete_rgx_cmd gist "${p}")"
  rcmd="$(compete_rgx_cmd rg "${p}")"
  if ! gm="$(hf_min 3 "${RUNS}" "${gcmd}" "${rcmd}")" \
    || ! rr="$(hf_min 3 "${RUNS}" "${rcmd}")"; then
    echo "aborting: SPEED cell '${p}' failed status/equivalence precheck" >&2
    exit 1
  fi
  v="$(python3 -c "g=${gm};r=${rr};print(f'{r/g:.2f}x' if g<r else f'-{g/r:.2f}x')" 2> /dev/null || echo '?')"
  printf "  %-22s %9s %9s %8s\n" "${p}" "${gm}" "${rr}" "${v}"
done

echo
echo "PROVEN: gist ≡ rg over the live tree — ${#PATTERNS[@]} no-prefilter patterns, exact file sets, 0 FN / 0 FP / cap-skips."
