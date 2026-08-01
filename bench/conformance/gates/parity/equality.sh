#!/usr/bin/env bash
# gist ≡ rg equality oracle.
#
# Builds the gist index, has it emit (per needle) its verified matching-file set
# plus a byte-exact SNAPSHOT of the files it indexed (corpus files are generated
# live by coworker agents — the snapshot freezes the bytes so the diff can't
# race), then runs ripgrep over that identical snapshot and diffs. Any
# difference is a soundness bug:
#   - a file in rg's set but not gist's  ⇒ trigram filter dropped a true match
#     (a FALSE NEGATIVE — the one thing a candidate filter may never do).
#   - a file in gist's set but not rg's  ⇒ verify is unsound (a FALSE POSITIVE
#     leaking past the exact-substring check).
# Both must be zero. Usage: bench/equality.sh [battery_n] [seed]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1
OUT="${GIST_VERIFY}"
BATTERY="${1:-120}"
SEED="${2:-1}"

echo "building gist index + emitting verified match sets (battery=${BATTERY} seed=${SEED})…"
# verify lives on the product package when the harness is wired there; fall back
# to KERNEL for the historical all-in-one layout.
(cd "${PRODUCT}" && zig build -Doptimize=ReleaseFast verify -- "${BATTERY}" "${SEED}") \
  || (cd "${KERNEL}" && zig build -Doptimize=ReleaseFast verify -- "${BATTERY}" "${SEED}") \
  || exit 1

cd "${REPO}" || exit 1
command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}

i=0
fails=0
total=0
while IFS= read -r needle; do
  gist_set="$(sort -u "${OUT}/n${i}.txt" 2> /dev/null)"
  rg_set="$(xargs -0 rg --no-ignore -F -l -- "${needle}" < "${OUT}/corpus.list" 2> /dev/null | sort -u)"
  if [[ "${gist_set}" != "${rg_set}" ]]; then
    fails=$((fails + 1))
    echo "── MISMATCH [needle ${i}] = <${needle}>"
    diff <(printf '%s\n' "${gist_set}") <(printf '%s\n' "${rg_set}") | sed 's/^/    /' | head -20
  fi
  total=$((total + 1))
  i=$((i + 1))
done < "${OUT}/needles.txt"

echo "checked ${total} literal needles · ${fails} mismatches"

# ── regex parity: gist NFA vs `rg (?-u)…` (ASCII/byte mode, == the NFA) ──
ri=0
rfails=0
rtotal=0
if [[ -f "${OUT}/regexes.txt" ]]; then
  while IFS= read -r pat; do
    gist_set="$(sort -u "${OUT}/r${ri}.txt" 2> /dev/null)"
    rg_set="$(xargs -0 rg --no-ignore -l -- "(?-u)${pat}" < "${OUT}/corpus.list" 2> /dev/null | sort -u)"
    if [[ "${gist_set}" != "${rg_set}" ]]; then
      rfails=$((rfails + 1))
      echo "── REGEX MISMATCH [${ri}] = </${pat}/>"
      diff <(printf '%s\n' "${gist_set}") <(printf '%s\n' "${rg_set}") | sed 's/^/    /' | head -20
    fi
    rtotal=$((rtotal + 1))
    ri=$((ri + 1))
  done < "${OUT}/regexes.txt"
  echo "checked ${rtotal} regexes · ${rfails} mismatches"
fi

echo
if [[ "${fails}" -eq 0 ]] && [[ "${rfails}" -eq 0 ]]; then
  echo "PROVEN: gist ≡ rg over the identical corpus — ${total} literals + ${rtotal} regexes, zero false negatives, zero false positives."
else
  echo "FAILED: $((fails + rfails)) pattern(s) disagree — see diffs above."
  exit 1
fi
