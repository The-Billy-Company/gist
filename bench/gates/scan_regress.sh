#!/usr/bin/env bash
# gist no-prefilter SCAN-path regression + race — the permanent guard for the
# direct live-tree scan (bench/scan.zig), the path cli.zig dispatches a regex to
# when the trigram index can filter NOTHING (no ≥3 B required literal, no all-≥3
# alternation cover). equality.sh proves the INDEX path; this proves the SCAN path
# — a different code path that walks + reads the live tree itself, so it needs its
# own soundness oracle.
#
# Two things, both kept permanent so the win can't silently rot and the next
# exploration starts from a measured floor (sins.mdc: prove with truth, not vibes):
#
#   1. SOUNDNESS (the gate). gist's scan match-set must equal `rg (?-u) -l` over
#      the IDENTICAL corpus (rg run with --no-ignore --hidden + gist's exact
#      isSkipDir excludes, so both see the same files). A file in rg's set but not
#      gist's is a FALSE NEGATIVE (a candidate scan may never drop a true match) —
#      UNLESS it is larger than the 4 MiB per_file_cap gist caps reads at by
#      contract (then it is a documented cap-skip, not a bug). A file in gist's set
#      but not rg's is a FALSE POSITIVE. Any real FN/FP ⇒ exit 1. A pattern that no
#      longer routes to the scan path (ROUTING FAIL) also ⇒ exit 1 — the test's
#      premise is void if cli.zig's dispatch silently changed.
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
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"

RUNS="${1:-12}"
PER_FILE_CAP=$((4 << 20)) # mirrors corpus.zig per_file_cap (4 MiB)

# rg must see gist's EXACT corpus: no .gitignore, include hidden, skip the same
# dirs. This list mirrors corpus.zig `isSkipDir` byte-for-byte — keep in sync.
SKIP=(.git .github .hg .svn node_modules target dist dist-types build .build out
  .next coverage .venv venv site-packages __pycache__ .pytest_cache .mypy_cache
  .ruff_cache .zig-cache zig-out .cache .local .turbo vendor .swiftpm Pods
  DerivedData .cursor .idea .vscode .parcel-cache .pnpm-store graphify-out)
GLOBS=()
for d in "${SKIP[@]}"; do GLOBS+=(-g "!**/${d}/**"); done

# The no-prefilter slate — every pattern here MUST route to the scan path (the
# routing guard asserts it). Each lacks a ≥3 B required literal AND an all-≥3
# alternation cover.
PATTERNS=('\w{3,8}' '[a-f0-9]{2,}' '[a-z]+_[a-z]+_[a-z]+' '[0-9]{4}' 'panic|0x')

command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}
need_hyperfine

echo "building gist (ReleaseFast) + copying binary…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast cli -- search 'zzqqxxv' --show files > /dev/null 2>&1) \
  || {
    echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
    exit 1
  }
compete_install_gist_bin || exit 1

fsize() { stat -f%z "$1" 2> /dev/null || stat -c%s "$1" 2> /dev/null || echo 0; }
# scan.zig's `  [pipeline] …` line — workers + worker-span Δ (the straggler canary).
gist_balance() { "${GIST_BIN}" search "$1" --show files 2>&1 | grep '^  \[pipeline\]' | sed 's/^  //'; }

cd "${REPO}" || exit 1
echo
echo "### SOUNDNESS — gist scan ≡ rg over identical corpus (the gate) ###"
fails=0
for p in "${PATTERNS[@]}"; do
  # One gist run; split its stderr into the match list + the scan diagnostic.
  "${GIST_BIN}" search "${p}" --show files > /tmp/gist_scan_out.txt 2>&1
  # Routing guard: the scan path (and only it) prints "live tree". If a dispatch
  # change re-routes this pattern to the index path, the test's premise is void.
  if ! grep -q 'live tree' /tmp/gist_scan_out.txt; then
    printf "  %-22s ROUTING FAIL — no longer dispatches to the scan path (see cli.zig runRegex)\n" "${p}"
    fails=$((fails + 1))
    continue
  fi
  grep -v '^—\|^  \[' /tmp/gist_scan_out.txt | sort -u > /tmp/gist_scan_g.txt
  rg --no-ignore --hidden "(?-u)${p}" -l "${GLOBS[@]}" -- "${ROOTS[@]}" 2> /dev/null | sort -u > /tmp/gist_scan_r.txt
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
echo "### SPEED (min of ${RUNS}) + PIPELINE BALANCE (straggler canary) ###"
printf "  %-22s %9s %9s %8s   %s\n" pattern gist_ms rg_ms verdict balance
for p in "${PATTERNS[@]}"; do
  gj="$(mktemp)"
  rj="$(mktemp)"
  hyperfine -w3 -r"${RUNS}" --export-json "${gj}" "{ \"${GIST_BIN}\" search '${p}' --show files ; } 2>&1 | wc -l >/dev/null" > /dev/null 2>&1
  hyperfine -w3 -r"${RUNS}" --export-json "${rj}" "{ rg --no-ignore --hidden '(?-u)${p}' -l ${GLOBS[*]} -- ${ROOTS[*]} ; } 2>&1 | wc -l >/dev/null" > /dev/null 2>&1
  gm="$(python3 -c "import json;print('%.1f'%(min(json.load(open('${gj}'))['results'][0]['times'])*1000))" 2> /dev/null || echo '?')"
  rr="$(python3 -c "import json;print('%.1f'%(min(json.load(open('${rj}'))['results'][0]['times'])*1000))" 2> /dev/null || echo '?')"
  v="$(python3 -c "g=${gm};r=${rr};print(f'{r/g:.2f}x' if g<r else f'-{g/r:.2f}x')" 2> /dev/null || echo '?')"
  bal="$(gist_balance "${p}")"
  printf "  %-22s %9s %9s %8s   %s\n" "${p}" "${gm}" "${rr}" "${v}" "${bal}"
  rm -f "${gj}" "${rj}"
done

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: gist scan ≡ rg over the identical corpus — ${#PATTERNS[@]} no-prefilter patterns, 0 FN / 0 FP (cap-skips are the documented 4 MiB per_file_cap)."
else
  echo "FAILED: ${fails} pattern(s) regressed (real FN/FP, or no longer routing to the scan path). See the gate table above."
  exit 1
fi
