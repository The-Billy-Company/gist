#!/usr/bin/env bash
# gist vs the field — WARM head-to-head: gist's resident RAM index (the
# long-lived agent-session model) vs every unindexed scanner at its warm fastest.
#
# gist: warm resident-index full pipeline (filter + parallel verify), p50 of 200
#       runs, emitted to .gist/bench.csv by `zig build bench`.
# unindexed (rg, ugrep, ag, GNU grep, git grep): their happy path — fixed-string
#       list-files, warmed, hyperfine mean. They always re-walk + re-read (no
#       resident index); gist answers from RAM.
#
# The *indexed* rivals (csearch, zoekt) have no resident-server CLI here — each
# invocation reloads the index from disk — so their honest model is the
# fresh-process race in bench/coldquery.sh, not this warm one. See _compete.sh
# for the field + fairness scoping. Usage: bench/headtohead.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=field.sh
source "${HERE}/field.sh"
need_hyperfine

warm_needles=(pgxpool context.Context "func " TODO queryLiteral rate_limit zzqxv ctx
  :// "func(" "return nil" SELECT import "})" AAAAAA goroutine "panic(" "Result<"
  "def " ".unwrap()")

echo "building gist + prechecking every warm cell against rg…"
compete_build_gist_index || exit 1
cd "${CORPUS}" || exit 1
for needle in "${warm_needles[@]}"; do
  gcmd="$(compete_lit_cmd gist "${needle}")"
  rcmd="$(compete_lit_cmd rg "${needle}")"
  compete_precheck_equivalent "${gcmd}" "${rcmd}" "warm/${needle}" || exit 1
done

echo "capturing warm latency…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast bench > /dev/null 2>&1) || exit 1
[[ -s "${OUT}/bench.csv" ]] || {
  echo "warm benchmark did not emit ${OUT}/bench.csv" >&2
  exit 1
}

# Warm race is gist-resident vs the unindexed scanners only (see header).
tools_raw="$(compete_tools literal)"
mapfile -t all_tools <<< "${tools_raw}"
tools=()
for t in "${all_tools[@]}"; do
  kind="$(compete_kind "${t}")"
  [[ "${kind}" = unindexed ]] && tools+=("${t}")
done

cd "${CORPUS}" || exit 1
echo
echo "warm query — gist resident p50 vs unindexed scanners (hyperfine mean, runs=8):"
echo "fields: <tool> <ms> (<gist speedup>)"
echo

declare -A SUM CNT WINS
for t in "${tools[@]}"; do
  SUM[${t}]=0
  CNT[${t}]=0
  WINS[${t}]=0
done
csv="${COMPETE_DIR}/warm.csv"
echo "needle,tool,ms,gist_ms,ratio" > "${csv}"

row=0
while IFS=$'\t' read -r needle gist_ns _; do
  if [[ "${needle}" != "${warm_needles[${row}]:-}" ]]; then
    echo "warm needle contract drift at row ${row}: ${needle}" >&2
    exit 1
  fi
  row=$((row + 1))
  gist_ms="$(python3 -c "print('%.3f'%(${gist_ns}/1e6))")"
  line="$(printf "%-16s gist %sms" "${needle}" "${gist_ms}")"
  for t in "${tools[@]}"; do
    cmd="$(compete_lit_cmd "${t}" "${needle}")"
    if ! ms="$(hf_mean 2 8 "${cmd}")"; then
      echo "aborting: ${t} hard-failed while benchmarking literal '${needle}'" >&2
      exit 1
    fi
    spd="$(ratio "${ms}" "${gist_ms}")"
    echo "${needle},${t},${ms},${gist_ms},${spd}" >> "${csv}"
    if [[ "${ms}" != "?" ]]; then
      SUM[${t}]="$(python3 -c "import math;print(${SUM[${t}]}+math.log(${ms}/${gist_ms}))")"
      CNT[${t}]=$((CNT[${t}] + 1))
      python3 -c "import sys;sys.exit(0 if ${ms}>=${gist_ms} else 1)" && WINS[${t}]=$((WINS[${t}] + 1))
    fi
    line+="$(printf "  %s %s(%s)" "${t}" "${ms}" "${spd}")"
  done
  echo "${line}"
done < "${OUT}/bench.csv"
if [[ "${row}" -ne "${#warm_needles[@]}" ]]; then
  echo "warm needle contract drift: bench emitted ${row}/${#warm_needles[@]} rows" >&2
  exit 1
fi

echo
echo "── summary: geomean gist warm speedup · queries gist ≥ tool ──"
for t in "${tools[@]}"; do
  [[ "${CNT[${t}]}" -eq 0 ]] && continue
  g="$(python3 -c "import math;print('%.0f'%math.exp(${SUM[${t}]}/${CNT[${t}]}))")"
  printf "  %-9s %sx geomean · won %d/%d\n" "${t}" "${g}" "${WINS[${t}]}" "${CNT[${t}]}"
done
echo "csv → ${csv}"
