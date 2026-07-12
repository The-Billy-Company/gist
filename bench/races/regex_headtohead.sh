#!/usr/bin/env bash
# gist vs the field — the REGEX cold head-to-head, every engine on its fastest
# honest path.
#
# Model mirrors coldquery.sh: build every index ONCE, then each query is a fresh
# process. gist + the indexed rivals (csearch RE2, zoekt) cold-load and read
# only candidates (prefiltered on the required literal / alternation cover set,
# else the no-literal scan accelerated by the compiled first-byte set or anchor
# seeding). The unindexed engines re-walk + re-scan: rg `(?-u)` (byte semantics,
# == gist's NFA dialect), ugrep/GNU-grep/git-grep with `-P` (PCRE), ag (PCRE).
#
# csearch (Google Code Search) is the apples-to-apples indexed RE2 rival — same
# trigram-prefilter-then-verify lineage as gist. zoekt is Sourcegraph's indexed
# search. Anchored/line semantics can differ slightly across the PCRE/RE2/zoekt
# engines (zoekt is file- not strictly line-oriented), so the indexed columns
# are a throughput reference; rg `(?-u)` remains gist's proven byte-exact oracle.
#
# Patterns are grouped by the feature tier each exercises. See _compete.sh for
# the field + fairness scoping. Usage: bench/regex_headtohead.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"
need_hyperfine

echo "building gist + persisting the index once…"
compete_build_gist_index || exit 1
echo "building competitor indexes…"
compete_build_csearch
compete_build_zoekt

# tier-label  pattern — the label names the feature tier each pattern exercises.
slate=(
  "lit+word     func\\s+\\w+\\("
  "lit+word     return\\s+nil"
  "lit+class    pgxpool\\.\\w+"
  "err-idiom    if\\s+err\\s*!=\\s*nil"
  "decl         const\\s+\\w+\\s*="
  "anchor^lit   ^package\\s+\\w+"
  "anchor^lit   ^func\\s"
  "anchor-lit\$  ;\$"
  "anchor-lit\$  \\)\$"
  "anchor^lit\$ ^\\}\$"
  "anchor-empty ^\$"
  "count-class  [0-9]{4}"
  "count-word   \\w{3,8}"
  "count-hex    [a-f0-9]{2,}"
  "uuid-ish     [0-9a-f]{8}-[0-9a-f]{4}"
  "snake        [a-z]+_[a-z]+_[a-z]+"
  "camel        [a-z]+[A-Z]\\w+"
  "dotted-call  \\w+\\.\\w+\\("
  "alt-cover    return|continue|break"
  "alt-cover    func|struct|enum"
  "alt-cover    error|panic|fatal"
  "alt-mixed    panic|0x"
)

cd "${REPO}" || exit 1
tools_raw="$(compete_tools regex)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "cold regex query — fresh process, warm cache (hyperfine mean, runs=8):"
echo "fields: <tool> <ms> (<gist speedup>); idx=indexed rivals, unidx=unindexed scanners"
echo

declare -A SUM CNT WINS
for t in "${tools[@]}"; do
  SUM[${t}]=0
  CNT[${t}]=0
  WINS[${t}]=0
done
csv="${COMPETE_DIR}/regex.csv"
echo "tier,pattern,tool,kind,ms,gist_ms,ratio" > "${csv}"

for row in "${slate[@]}"; do
  read -r label pat <<< "${row}"
  gcmd="$(compete_rgx_cmd gist "${pat}")"
  rcmd="$(compete_rgx_cmd rg "${pat}")"
  if ! gist_ms="$(hf_mean 3 8 "${gcmd}" "${rcmd}")"; then
    echo "aborting: gist failed semantic/status precheck for regex '${pat}'" >&2
    exit 1
  fi
  printf "%-13s %-24s gist %sms\n" "${label}" "${pat}" "${gist_ms}"
  idx_line="    idx:  "
  unidx_line="    unidx:"
  for t in "${tools[@]}"; do
    cmd="$(compete_rgx_cmd "${t}" "${pat}")"
    if ! ms="$(hf_mean 2 8 "${cmd}")"; then
      echo "aborting: ${t} hard-failed while benchmarking regex '${pat}'" >&2
      exit 1
    fi
    spd="$(ratio "${ms}" "${gist_ms}")"
    kind="$(compete_kind "${t}")"
    # Quote the pattern: several patterns contain commas (`\w{3,8}`, `[a-f0-9]{2,}`)
    # which would otherwise split into extra CSV columns and misalign every field.
    echo "${label},\"${pat}\",${t},${kind},${ms},${gist_ms},${spd}" >> "${csv}"
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
echo "── summary: geomean gist speedup · patterns gist ≥ tool ──"
for t in "${tools[@]}"; do
  [[ "${CNT[${t}]}" -eq 0 ]] && continue
  g="$(python3 -c "import math;print('%.1f'%math.exp(${SUM[${t}]}/${CNT[${t}]}))")"
  kind="$(compete_kind "${t}")"
  printf "  %-8s %-9s %sx geomean · gist ≥ on %d/%d\n" "${kind}" "${t}" "${g}" "${WINS[${t}]}" "${CNT[${t}]}"
done
echo "Prefilterable tiers win outright; the no-literal dense tail (\\w{3,8}) is a"
echo "pure automaton-throughput race — see CHANGELOG 'bit-parallel Glushkov engine'."
echo "csv → ${csv}"
