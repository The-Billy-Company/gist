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
# exploration starts from a measured floor (sins.mdc: prove with truth, not vibes):
#
#   1. SOUNDNESS (the gate). gist's match-set must equal plain `rg (?-u) -l` over
#      the SAME roots — gist's tree-walk now honors `.gitignore` and excludes
#      hidden files exactly like rg's default (no `--no-ignore`/`--hidden` skew;
#      confirmed byte-for-byte against `rg` for regular, non-ignored files). A
#      file in rg's set but not gist's is a FALSE NEGATIVE (a candidate scan may
#      never drop a true match) — UNLESS it is larger than the 4 MiB
#      per_file_cap gist caps reads at by contract (then it is a documented
#      cap-skip, not a bug). A file in gist's set but not rg's is a FALSE
#      POSITIVE. Any real FN/FP ⇒ exit 1. (There's no separate stderr
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
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"

RUNS="${1:-12}"
PER_FILE_CAP=$((4 << 20)) # mirrors corpus.zig per_file_cap (4 MiB)

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
  "${GIST_BIN}" "${p}" -l -- "${ROOTS[@]}" < /dev/null 2> /dev/null | sort -u > /tmp/gist_scan_g.txt
  rg "(?-u)${p}" -l -- "${ROOTS[@]}" 2> /dev/null | sort -u > /tmp/gist_scan_r.txt
  comm -12 /tmp/gist_scan_g.txt /tmp/gist_scan_r.txt > /tmp/gist_scan_shared.txt
  comm -23 /tmp/gist_scan_g.txt /tmp/gist_scan_r.txt > /tmp/gist_scan_fp.txt # gist-only
  comm -13 /tmp/gist_scan_g.txt /tmp/gist_scan_r.txt > /tmp/gist_scan_rgonly.txt
  shared="$(wc -l < /tmp/gist_scan_shared.txt | tr -d ' ')"
  fp="$(wc -l < /tmp/gist_scan_fp.txt | tr -d ' ')"
  fn=0
  cap=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    sz="$(fsize "${f}")"
    if [[ "${sz}" -gt "${PER_FILE_CAP}" ]]; then cap=$((cap + 1)); else fn=$((fn + 1)); fi
  done < /tmp/gist_scan_rgonly.txt
  status="ok"
  if [[ "${fn}" -gt 0 || "${fp}" -gt 0 ]]; then
    status="FAIL"
    fails=$((fails + 1))
  fi
  printf "  %-22s shared=%-6s FN=%-3s FP=%-3s cap_skip=%-3s  %s\n" "${p}" "${shared}" "${fn}" "${fp}" "${cap}" "${status}"
done

echo
echo "### SPEED (min of ${RUNS}) — no-prefilter patterns, full-read floor ###"
printf "  %-22s %9s %9s %8s\n" pattern gist_ms rg_ms verdict
for p in "${PATTERNS[@]}"; do
  gj="$(mktemp)"
  rj="$(mktemp)"
  hyperfine -w3 -r"${RUNS}" --export-json "${gj}" "{ \"${GIST_BIN}\" '${p}' -l -- ${ROOTS[*]} < /dev/null ; } 2>&1 | wc -l >/dev/null" > /dev/null 2>&1
  hyperfine -w3 -r"${RUNS}" --export-json "${rj}" "{ rg '(?-u)${p}' -l -- ${ROOTS[*]} ; } 2>&1 | wc -l >/dev/null" > /dev/null 2>&1
  gm="$(python3 -c "import json;print('%.1f'%(min(json.load(open('${gj}'))['results'][0]['times'])*1000))" 2> /dev/null || echo '?')"
  rr="$(python3 -c "import json;print('%.1f'%(min(json.load(open('${rj}'))['results'][0]['times'])*1000))" 2> /dev/null || echo '?')"
  v="$(python3 -c "g=${gm};r=${rr};print(f'{r/g:.2f}x' if g<r else f'-{g/r:.2f}x')" 2> /dev/null || echo '?')"
  printf "  %-22s %9s %9s %8s\n" "${p}" "${gm}" "${rr}" "${v}"
  rm -f "${gj}" "${rj}"
done

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: gist ≡ rg over the live tree — ${#PATTERNS[@]} no-prefilter patterns, 0 FN / 0 FP (cap-skips are the documented 4 MiB per_file_cap)."
else
  echo "FAILED: ${fails} pattern(s) regressed (real FN/FP). See the gate table above."
  exit 1
fi
