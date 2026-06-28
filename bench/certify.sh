#!/usr/bin/env bash
# certify.sh — Layer A of the optimality certificate, MACROSCOPIC half.
#
# The microscopic half (`zig build certify`) proves gist's in-process verify
# kernel runs at N cycles/byte. This half proves the *end-to-end* claim the user
# actually cares about: for every regex class ripgrep supports, gist's cold
# fresh-process query is **at parity or faster than ripgrep**, established with a
# real statistic — a 95% bootstrap-CI median + a Mann-Whitney significance test —
# not a single mean. The verdict is fail-closed (a WIN needs a lower median AND
# p<0.05); every class is shown, losses included.
#
# The 11 classes are byte-identical to certify.zig's probes, so the macroscopic
# table and the microscopic table in CERTIFICATE.md map 1:1 by class name.
#
# Field + fairness scoping come from _compete.sh (same roots, same ignore set,
# each tool on its fastest honest path). gist + indexed rivals cold-load an index
# built ONCE over the same corpus; rg/ugrep/ag/grep re-walk + re-scan.
#
# Usage:  bench/certify.sh            (RUNS=20 WARMUP=3 by default)
#         RUNS=40 bench/certify.sh    (tighten the CIs)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"
need_hyperfine

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
WORK="${COMPETE_DIR}/certify"
CERT="${OUT}/CERTIFICATE.md"
MACRO_CSV="${OUT}/certify_macro.csv"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT}"

# class  kind  pattern — byte-identical to certify.zig's `probes` (patterns have
# no spaces, so `read class kind pat` recovers the pattern as the trailing field).
PROBES=(
  "literal-rare literal pgxpool"
  "literal-dotted literal context.Context"
  "literal-common literal func"
  "literal-punct2 literal })"
  "regex-decl regex func\\s+\\w+\\("
  "regex-dotted regex pgxpool\\.\\w+"
  "regex-anchored regex ^func\\s"
  "regex-classcount regex [0-9a-f]{8}-[0-9a-f]{4}"
  "regex-alternation regex return|continue|break"
  "regex-dense-scan regex \\w{3,8}"
  "regex-eol regex ;\$"
)

echo "building gist + persisting the index once…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast cli -- index) || exit 1
compete_install_gist_bin || exit 1
echo "building competitor indexes…"
compete_build_csearch
compete_build_zoekt

tools_raw="$(compete_tools regex)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "macroscopic race — fresh-process cold query, hyperfine runs=${RUNS} (+${WARMUP} warmup)"
echo "field: gist ${tools[*]}"
echo

# one hyperfine JSON per (class, tool); fair wrapper drains output + neutralizes
# the no-match exit code (see hf_mean in _compete.sh for the rationale).
bench_one() { # <class> <tool> <cmd>
  local class="$1" tool="$2" cmd="$3"
  [[ -z "${cmd}" || "${cmd}" = "false" ]] && return 0
  hyperfine --warmup "${WARMUP}" --runs "${RUNS}" \
    --export-json "${WORK}/${class}__${tool}.json" \
    "{ ${cmd} ; } 2>&1 | wc -l >/dev/null" > /dev/null 2>&1 || true
}

cd "${REPO}" || exit 1
: > "${WORK}/order.tsv"
for row in "${PROBES[@]}"; do
  read -r class kind pat <<< "${row}"
  printf '%s\t%s\t%s\n' "${class}" "${kind}" "${pat}" >> "${WORK}/order.tsv"
  if [[ "${kind}" = literal ]]; then
    gcmd="$(compete_lit_cmd gist "${pat}")"
  else
    gcmd="$(compete_rgx_cmd gist "${pat}")"
  fi
  bench_one "${class}" gist "${gcmd}"
  printf "  %-18s " "${class}"
  for t in "${tools[@]}"; do
    if [[ "${kind}" = literal ]]; then
      cmd="$(compete_lit_cmd "${t}" "${pat}")"
    else cmd="$(compete_rgx_cmd "${t}" "${pat}")"; fi
    bench_one "${class}" "${t}" "${cmd}"
  done
  echo "done"
done

# meta for the report
roots_str="${ROOTS[*]}"
cat > "${WORK}/meta.json" << EOF
{ "runs": ${RUNS}, "warmup": ${WARMUP}, "roots": "${roots_str}" }
EOF

echo
echo "computing bootstrap-CI medians + Mann-Whitney dominance (gist vs rg)…"
python3 "${HERE}/certify_stats.py" "${WORK}" \
  --certificate "${CERT}" \
  --csv "${MACRO_CSV}" \
  --order "${WORK}/order.tsv" \
  --meta "${WORK}/meta.json"

echo "macroscopic section appended to ${CERT}"
