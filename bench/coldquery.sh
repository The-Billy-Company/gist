#!/usr/bin/env bash
# gist vs the field — the COLD / first query (the one unindexed greps used to
# win), now raced against the *indexed* rivals too.
#
# Model: build every index ONCE, then each query is a fresh process. gist and
# the two indexed tools (csearch, zoekt) cold-load their index and read only the
# CANDIDATE files; the unindexed tools (rg, ugrep, ag, GNU grep, git grep) have
# no index, so every invocation re-walks the whole tree and re-scans. The race
# that matters most for an indexed kernel is gist vs csearch/zoekt — same model,
# so it's pure engine + index-layout speed, not "indexed beats unindexed".
#
# All measured fresh-process via hyperfine (process spawn included), warm page
# cache. See _compete.sh for the field, the fairness scoping, and install hints.
# Usage: bench/coldquery.sh [needle...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"
need_hyperfine

echo "building gist + persisting the index once…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast cli -- index) || exit 1
compete_install_gist_bin || exit 1
echo "building competitor indexes (over gist's exact corpus where possible)…"
compete_build_csearch
compete_build_zoekt

cd "${REPO}" || exit 1
# A spread: a guaranteed MISS (pure index win), very-selective symbols, medium,
# common tokens that touch thousands of files, and a 2-byte punctuation needle.
needles=("$@")
[[ ${#needles[@]} -eq 0 ]] && needles=(zzqxvNOMATCH queryLiteral pgxpool rate_limit
  context.Context goroutine SELECT func import "func(" "})")

tools_raw="$(compete_tools literal)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "cold literal query — fresh process, warm cache (hyperfine mean, runs=8):"
echo "fields: <tool> <ms> (<gist speedup>); idx=indexed rivals, unidx=unindexed scanners"
echo

# Per-tool accumulators (geomean of ratios + win count), parallel to ${tools[@]}.
declare -A SUM CNT WINS
for t in "${tools[@]}"; do
  SUM[${t}]=0
  CNT[${t}]=0
  WINS[${t}]=0
done
csv="${COMPETE_DIR}/cold.csv"
echo "needle,tool,kind,ms,gist_ms,ratio" > "${csv}"

for n in "${needles[@]}"; do
  gcmd="$(compete_lit_cmd gist "${n}")"
  gist_ms="$(hf_mean 3 8 "${gcmd}")"
  printf "%-16s gist %sms\n" "${n}" "${gist_ms}"
  idx_line="    idx:  "
  unidx_line="    unidx:"
  for t in "${tools[@]}"; do
    cmd="$(compete_lit_cmd "${t}" "${n}")"
    ms="$(hf_mean 2 8 "${cmd}")"
    spd="$(ratio "${ms}" "${gist_ms}")"
    kind="$(compete_kind "${t}")"
    echo "${n},${t},${kind},${ms},${gist_ms},${spd}" >> "${csv}"
    if [[ "${ms}" != "?" && "${gist_ms}" != "?" ]]; then
      SUM[${t}]="$(python3 -c "import math;print(${SUM[${t}]}+math.log(${ms}/${gist_ms}))")"
      CNT[${t}]=$((CNT[${t}] + 1))
      python3 -c "import sys;sys.exit(0 if ${ms}>=${gist_ms} else 1)" && WINS[${t}]=$((WINS[${t}] + 1))
    fi
    cell="$(printf "%s %s(%s)" "${t}" "${ms}" "${spd}")"
    if [[ "${kind}" = indexed ]]; then idx_line+=" ${cell}"; else unidx_line+=" ${cell}"; fi
  done
  [[ "${idx_line}" != "    idx:  " ]] && echo "${idx_line}"
  echo "${unidx_line}"
done

echo
echo "── summary: geomean gist speedup · queries gist ≥ tool ──"
for t in "${tools[@]}"; do
  [[ "${CNT[${t}]}" -eq 0 ]] && continue
  g="$(python3 -c "import math;print('%.1f'%math.exp(${SUM[${t}]}/${CNT[${t}]}))")"
  kind="$(compete_kind "${t}")"
  printf "  %-8s %-9s %sx geomean · won %d/%d\n" "${kind}" "${t}" "${g}" "${WINS[${t}]}" "${CNT[${t}]}"
done
echo "csv → ${csv}"
