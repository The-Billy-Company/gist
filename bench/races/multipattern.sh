#!/usr/bin/env bash
# hydra patterns — the BATCHED multi-pattern race (irregex match half).
#
# The workload relocator/lints actually run: N patterns over the tree, needing
# per-pattern attribution. Three honest strategies race:
#
#   sequential   N separate `gist -l <p>` processes (today's consumer loop)
#   fused        one `gist -l '(?:p0)|(?:p1)|…'` alternation — fast, but the
#                answer loses WHICH pattern hit (the re-derive-in-Python tax)
#   patterns     one `hydra patterns -e p0 -e p1 … --by pattern` — one walk,
#                exact per-pattern attribution, loom-grouped engine-side
#
# `patterns` should land near `fused` while answering the question `fused`
# cannot. Usage: bench/races/multipattern.sh [ROOT...]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"
need_hyperfine

ROOTS=("${@:-services libs clients contracts scripts quality}")

echo "building gist…"
compete_build_gist_index || exit 1

# A relocator-shaped slate: identifier literals of mixed selectivity.
pats=(
  "WalletService"
  "pgxpool"
  "CompiledQuery"
  "billing_check"
  "SearchRequest"
  "extractSortedUnique"
  "voiceSplitEnabled"
  "graphify"
  "MONOLITHIC"
  "doc_radar"
)

seq_cmd=""
for p in "${pats[@]}"; do
  seq_cmd+="${GIST_BIN} -F -l '${p}' ${ROOTS[*]} >/dev/null; "
done

fused=""
for p in "${pats[@]}"; do
  fused+="${fused:+|}(?:${p})"
done
fused_cmd="${GIST_BIN} -l '${fused}' ${ROOTS[*]} >/dev/null"

pat_flags=""
for p in "${pats[@]}"; do
  pat_flags+=" -e '${p}'"
done
patterns_cmd="${HYDRA_BIN} patterns -F ${pat_flags} --by pattern ${ROOTS[*]} >/dev/null"

hyperfine --warmup 1 --min-runs 5 \
  --command-name "sequential (${#pats[@]}× gist -l)" "${seq_cmd}" \
  --command-name "fused alternation (no attribution)" "${fused_cmd}" \
  --command-name "hydra patterns (attributed)" "${patterns_cmd}"
