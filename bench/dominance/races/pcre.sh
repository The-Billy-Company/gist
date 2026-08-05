#!/usr/bin/env bash
# gist vs the field — the PCRE cold head-to-head: lookaround + backreferences,
# the one regex class RE2 engines cannot express at all.
#
# This is gist's sharpest structural claim. Every other tool that can run this
# class (rg -P, ugrep -P, ag, GNU grep -P, git grep -P) is an *unindexed* PCRE2
# scanner: it re-walks and re-scans the whole tree on every query. The two
# indexed rivals from the other races — csearch (RE2) and zoekt (RE2) — are
# absent BY CONSTRUCTION: their engines have neither lookaround nor
# backreferences, so they cannot answer a single pattern in this slate. gist is
# the ONLY indexed tool in the field: it extracts the pattern's sound required
# literal, prunes the read set with the SAME trigram index it uses for the linear
# engine, and PCRE2-JIT-matches only the surviving candidates. On a prefilterable
# pattern that is a whole-tree scan avoided; on a literal-free pattern
# (`(\w+) \1`) it degrades to the same fused parallel scan the linear engine
# uses, still JIT-matching in one pass — so it wins or ties the throughput race
# too. rg `-P` is gist's byte-exact correctness oracle (identical PCRE2 UTF+UCP
# defaults); the gist cell is only timed once its file set matches rg's exactly.
#
# Model mirrors regex_headtohead.sh: build the index ONCE, each query a fresh
# process. See _compete.sh for the field + fairness scoping.
# Usage: bench/races/pcre_headtohead.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=field.sh
source "${HERE}/field.sh"
need_hyperfine

echo "building gist + persisting the index once…"
compete_build_gist_index || exit 1
echo "(csearch + zoekt are excluded from this race — RE2 has no lookaround/backreferences)"

# tier-label  pattern — each label names the PCRE-only construct it exercises.
# Patterns are single-quoted downstream (our slate has no single quotes); most
# carry a ≥3-byte required literal so gist prefilters, and two are literal-free
# to force the pure-throughput scan race.
slate=(
  "lookahead-lit   func\\s+\\w+(?=\\()"
  "neg-lookahead   import\\s+(?!type)"
  "lookbehind-lit  (?<=return\\s)nil"
  "lookahead-err   err(?=\\s*!=\\s*nil)"
  "lookahead-const const\\s+\\w+(?=\\s*=)"
  "backref-tag     <(\\w+)>.*</\\1>"
  "backref-word    \\b(\\w{3,})\\b.*\\b\\1\\b"
)

cd "${CORPUS}" || exit 1
tools_raw="$(compete_pcre_tools)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "cold PCRE query — fresh process, warm cache (hyperfine mean, runs=8):"
echo "fields: <tool> <ms> (<gist speedup>); gist is the only INDEXED tool in this class"
echo

declare -A SUM CNT WINS
for t in "${tools[@]}"; do
  SUM[${t}]=0
  CNT[${t}]=0
  WINS[${t}]=0
done
csv="${COMPETE_DIR}/pcre.csv"
mkdir -p "${COMPETE_DIR}"
echo "tier,pattern,tool,ms,gist_ms,ratio" > "${csv}"

for row in "${slate[@]}"; do
  read -r label pat <<< "${row}"
  gcmd="$(compete_pcre_cmd gist "${pat}")"
  rcmd="$(compete_pcre_cmd rg "${pat}")"
  # gist is timed only once its file set matches the rg -P oracle exactly.
  if ! gist_ms="$(hf_mean 3 8 "${gcmd}" "${rcmd}")"; then
    echo "aborting: gist failed semantic/status precheck for PCRE '${pat}'" >&2
    exit 1
  fi
  printf "%-15s %-26s gist %sms\n" "${label}" "${pat}" "${gist_ms}"
  line="    field:"
  for t in "${tools[@]}"; do
    cmd="$(compete_pcre_cmd "${t}" "${pat}")"
    if ! ms="$(hf_mean 2 8 "${cmd}")"; then
      echo "aborting: ${t} hard-failed while benchmarking PCRE '${pat}'" >&2
      exit 1
    fi
    spd="$(ratio "${ms}" "${gist_ms}")"
    # Quote the pattern: several contain commas (`\w{3,}`) that would otherwise
    # split into extra CSV columns and misalign every field.
    echo "${label},\"${pat}\",${t},${ms},${gist_ms},${spd}" >> "${csv}"
    if [[ "${ms}" != "?" && "${gist_ms}" != "?" ]]; then
      SUM[${t}]="$(python3 -c "import math;print(${SUM[${t}]}+math.log(${ms}/${gist_ms}))")"
      CNT[${t}]=$((CNT[${t}] + 1))
      python3 -c "import sys;sys.exit(0 if ${ms}>=${gist_ms} else 1)" && WINS[${t}]=$((WINS[${t}] + 1))
    fi
    line+=" $(printf "%s %s(%s)" "${t}" "${ms}" "${spd}")"
  done
  echo "${line}"
done

echo
echo "── summary: geomean gist speedup · patterns gist ≥ tool ──"
for t in "${tools[@]}"; do
  [[ "${CNT[${t}]}" -eq 0 ]] && continue
  g="$(python3 -c "import math;print('%.1f'%math.exp(${SUM[${t}]}/${CNT[${t}]}))")"
  printf "  unindexed %-8s %sx geomean · gist ≥ on %d/%d\n" "${t}" "${g}" "${WINS[${t}]}" "${CNT[${t}]}"
done
echo "gist prefilters this class with its trigram index; every rival re-scans the"
echo "whole tree because RE2's indexed engines (csearch/zoekt) can't express it."
echo "csv → ${csv}"
