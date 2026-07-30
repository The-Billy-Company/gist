#!/usr/bin/env bash
# corpus-partition certificate — `gist --docs` vs the union a human hand-assembles.
#
# There is no rival flag to race here: no grep-class tool ships a docs/code axis
# (ripgrep's type globs are basename-only, so a `docs/` rule is not expressible
# there — ripgrep#3339, open). So the rival is what a competent engineer actually
# types instead: `rg -tmarkdown -trst -tman -ttex …`, one `-t` per prose type.
#
# That makes the fair construction of the rival a real question, and the answer
# is to DERIVE it rather than to write it down. The union is
#
#     (the type rows gist's docs genus is made of)  ∩  (the rows rg's registry has)
#
# read out of `gist --type-list --docs` and `rg --type-list` at run time. Deriving
# it has three consequences worth the cost: the rival cannot be strawmanned by
# omitting a type, it cannot drift when a docs type is added to `genus.zig`, and
# it cannot ask rg for a type name rg would exit on.
#
# THREE ARMS, and one of them is the whole reason this file is careful:
#
#   gist --docs (cold)   fresh process, index armed
#   gist --docs (warm)   a private resident daemon, ANSWER KEEP DISABLED
#   rg <union>           the same question, spelled the way it must be spelled today
#
# `GIST_NO_KEEP=1` on the warm arm is load-bearing, not hygiene. The keep returns
# a byte-identical rendered stdout for a query already asked against an unchanged
# corpus, so timing a repeated query with it armed measures a hash lookup and
# publishes it as a search. A number produced that way would be indefensible.
#
# Fail-closed on MEANING before speed: cold and warm must return the identical
# file set or no timing is published, and each arm must match something.
#
# The precision half is measured corpus-wide rather than per needle, over the
# INTERSECTION of the two tools' walks — so the two populations it reports are
# classification differences and not a walk difference wearing a costume:
#
#   over-claimed   files the -t union calls prose that gist classifies as code
#                  (CMakeLists.txt is the emblem: rg's `txt` type is `*.txt`, and
#                  a basename-blind glob cannot know a build recipe from a note)
#   rescued        files gist classifies as docs that no rg type name can reach
#                  (extensionless documents promoted by location or name)
#
# Usage:  cd pkg/kernels/irregex && bench/dominance/partition/certify_partition.sh
#         RUNS=12 WARMUP=3 bench/dominance/partition/certify_partition.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../races/field.sh
source "${HERE}/../races/field.sh"
need_hyperfine

RUNS="${RUNS:-10}"
WARMUP="${WARMUP:-2}"
# Lines in a file, as a bare number. Assigned rather than interpolated at every
# call site, so a failing `wc` is a failing mint instead of an empty string.
count() { wc -l < "$1" | tr -d ' '; }
# Medians only, never a ratio: the gate derives every speedup from these columns,
# so there is exactly one place a number can be wrong.
MACRO="${HERE}/partition_macro.csv" # (needle, gist_files, rg_files, cold_ms, warm_ms, rg_ms)
META="${HERE}/partition_meta.json"
WORK="${COMPETE_DIR}/partition"
DAEMON_PID=""
cleanup() {
  [[ -n "${DAEMON_PID}" ]] && kill "${DAEMON_PID}" 2> /dev/null
}
trap cleanup EXIT
rm -rf "${WORK}"
mkdir -p "${WORK}"

[[ "${HAVE_RG}" = 1 ]] || {
  echo "partition: ripgrep is the rival in every row — install it before certifying" >&2
  exit 1
}

echo "building gist + index…"
compete_build_gist_index || exit 1

# ── the rival union, derived from both registries ────────────────────────────
"${GIST_BIN}" --type-list --docs 2> /dev/null | cut -d: -f1 | LC_ALL=C sort -u > "${WORK}/gist-docs-types"
rg --type-list 2> /dev/null | cut -d: -f1 | LC_ALL=C sort -u > "${WORK}/rg-types"
comm -12 "${WORK}/gist-docs-types" "${WORK}/rg-types" > "${WORK}/union-types"
comm -23 "${WORK}/gist-docs-types" "${WORK}/union-types" > "${WORK}/unnameable-types"
n_gist_types="$(wc -l < "${WORK}/gist-docs-types" | tr -d ' ')"
n_union="$(wc -l < "${WORK}/union-types" | tr -d ' ')"
n_unnameable="$(wc -l < "${WORK}/unnameable-types" | tr -d ' ')"
[[ "${n_union}" -gt 0 ]] || {
  echo "partition: derived an EMPTY rival union — refusing to race a tool asked for nothing." >&2
  echo "           Did --type-list --docs stop narrowing? (see src/corpus/scope/types.zig)" >&2
  exit 1
}
RGT=()
while IFS= read -r t; do RGT+=("-t${t}"); done < "${WORK}/union-types"
echo "  rival union: ${n_union} rg type names (of ${n_gist_types} rows in gist's docs genus;"
echo "               ${n_unnameable} have no rg type name at all)"

# ── a private daemon, so no coworker's resident session is touched or timed ──
PRIVATE_DIR="${WORK}/gistdir"
mkdir -p "${PRIVATE_DIR}"
echo "indexing + starting a private resident session…"
(cd "${CORPUS}" && GIST_DIR="${PRIVATE_DIR}" "${GIST_BIN}" index > /dev/null 2>&1) || {
  echo "partition: could not build a private index" >&2
  exit 1
}
(cd "${CORPUS}" && GIST_DIR="${PRIVATE_DIR}" "${GIST_BIN}" serve > "${WORK}/serve.log" 2>&1) &
DAEMON_PID=$!
for _ in $(seq 1 60); do
  [[ -S "${PRIVATE_DIR}/gistd.sock" ]] && break
  sleep 0.1
done
[[ -S "${PRIVATE_DIR}/gistd.sock" ]] || {
  echo "partition: no daemon socket appeared (see ${WORK}/serve.log)" >&2
  exit 1
}

# ── the slate ────────────────────────────────────────────────────────────────
# Words that genuinely occur in prose across this tree, at three selectivities,
# because a partition flag's cost is dominated by how many files it must still
# read after the filter — one needle would measure one point on that curve.
NEEDLES=(architecture invariant "resident session")

: > "${MACRO}"
printf "  %-20s %8s %8s %10s %10s %10s %8s %8s\n" \
  needle gist_f rg_f cold_ms warm_ms rg_ms cold_x warm_x

for needle in "${NEEDLES[@]}"; do
  cold_cmd="cd '${CORPUS}' && GIST_DIR='${PRIVATE_DIR}' GIST_NO_AUTOSERVE=1 '${GIST_BIN}' -l --docs --no-index -- '${needle}'"
  warm_cmd="cd '${CORPUS}' && GIST_DIR='${PRIVATE_DIR}' GIST_NO_KEEP=1 '${GIST_BIN}' -l --docs -- '${needle}'"
  rg_cmd="cd '${CORPUS}' && rg -l --sort none ${SCOPE} ${RGT[*]} -- '${needle}'"

  bash -c "${cold_cmd}" 2> /dev/null | LC_ALL=C sort -u > "${WORK}/cold.set"
  bash -c "${warm_cmd}" 2> /dev/null | LC_ALL=C sort -u > "${WORK}/warm.set"
  bash -c "${rg_cmd}" 2> /dev/null | LC_ALL=C sort -u > "${WORK}/rg.set"
  gist_f="$(wc -l < "${WORK}/cold.set" | tr -d ' ')"
  rg_f="$(wc -l < "${WORK}/rg.set" | tr -d ' ')"

  if [[ "${gist_f}" -eq 0 || "${rg_f}" -eq 0 ]]; then
    echo "partition: needle '${needle}' matched nothing on one side (gist=${gist_f} rg=${rg_f})" >&2
    echo "           A zero-match arm times an empty walk; pick a needle that occurs." >&2
    exit 1
  fi
  if ! cmp -s "${WORK}/cold.set" "${WORK}/warm.set"; then
    echo "partition: the resident session answered a DIFFERENT question than the cold" >&2
    echo "           process for '${needle}' — refusing to publish a warm timing." >&2
    diff "${WORK}/cold.set" "${WORK}/warm.set" | head -6 >&2
    exit 1
  fi

  cold_ms="$(hf_min "${WARMUP}" "${RUNS}" "${cold_cmd} >/dev/null")"
  warm_ms="$(hf_min "${WARMUP}" "${RUNS}" "${warm_cmd} >/dev/null")"
  rg_ms="$(hf_min "${WARMUP}" "${RUNS}" "${rg_cmd} >/dev/null")"
  cold_x="$(ratio "${rg_ms}" "${cold_ms}")"
  warm_x="$(ratio "${rg_ms}" "${warm_ms}")"

  printf "  %-20s %8s %8s %10s %10s %10s %8s %8s\n" \
    "${needle}" "${gist_f}" "${rg_f}" "${cold_ms}" "${warm_ms}" "${rg_ms}" "${cold_x}" "${warm_x}"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${needle}" "${gist_f}" "${rg_f}" "${cold_ms}" "${warm_ms}" "${rg_ms}" >> "${MACRO}"
done

# ── precision, inside the intersection of the two walks ──────────────────────
# Two populations, because they answer two different questions and a number that
# doesn't name its corpus is a number nobody can check:
#
#   tracked    the live repo — what a bare `gist` / `rg` walks, the corpus an
#              agent searches all day. Here the two rosters very nearly coincide
#              (the union is DERIVED from gist's own docs types), so the honest
#              claim on this population is latency and ergonomics, not recall
#   fixture    a hermetic tree built below, holding exactly the shapes where a
#              basename-blind type glob and a genus must disagree. Same numbers on
#              any machine, so the gate can assert them EXACTLY rather than by
#              direction — this is where the mechanism is proven, not asserted
#
# Each writes its own receipt, and the gate reads the receipts rather than
# re-deriving anything.
classify() {
  local label="$1" corpus="$2" scope="$3"
  local w="${WORK}/${label}"
  mkdir -p "${w}"
  (cd "${corpus}" && "${GIST_BIN}" --files 2> /dev/null) | LC_ALL=C sort -u > "${w}/gist-all"
  # SCOPE carries quoted paths, so it must be re-parsed by a shell rather than
  # word-split by this one — the same way every race arm invokes it.
  bash -c "cd '${corpus}' && rg --files --sort none ${scope}" 2> /dev/null \
    | LC_ALL=C sort -u > "${w}/rg-all"
  comm -12 "${w}/gist-all" "${w}/rg-all" > "${w}/shared"
  local n_gist_all n_rg_all n_shared
  n_gist_all="$(count "${w}/gist-all")"
  n_rg_all="$(count "${w}/rg-all")"
  n_shared="$(count "${w}/shared")"
  [[ "${n_shared}" -gt 0 ]] || {
    echo "partition: the two ${label} walks share no file — the diff would be meaningless" >&2
    return 1
  }

  (cd "${corpus}" && "${GIST_BIN}" --files --docs 2> /dev/null) | LC_ALL=C sort -u > "${w}/gist-docs.all"
  bash -c "cd '${corpus}' && rg --files --sort none ${scope} ${RGT[*]}" 2> /dev/null \
    | LC_ALL=C sort -u > "${w}/rg-docs.all"
  comm -12 "${w}/gist-docs.all" "${w}/shared" > "${w}/gist-docs"
  comm -12 "${w}/rg-docs.all" "${w}/shared" > "${w}/rg-docs"
  comm -13 "${w}/gist-docs" "${w}/rg-docs" > "${w}/over-claimed"
  comm -23 "${w}/gist-docs" "${w}/rg-docs" > "${w}/rescued"
  local n_gist_docs n_rg_docs n_over n_rescued n_rescued_ext top_over
  n_gist_docs="$(count "${w}/gist-docs")"
  n_rg_docs="$(count "${w}/rg-docs")"
  n_over="$(count "${w}/over-claimed")"
  n_rescued="$(count "${w}/rescued")"

  # What the over-claim is MADE of, so the number is a finding and not a mystery.
  sed 's#.*/##' "${w}/over-claimed" | LC_ALL=C sort | uniq -c | sort -rn > "${w}/over-by-name"
  top_over="$(head -1 "${w}/over-by-name" | awk '{print $2" ("$1")"}')"
  [[ -n "${top_over}" ]] || top_over="none"
  # The rescued set's whole point is the paths no extension could have named.
  n_rescued_ext="$(grep -Ecv '\.[A-Za-z0-9]+$' "${w}/rescued")" || n_rescued_ext=0

  printf "  %-10s walks gist %s · rg %s · shared %s\n" "${label}" "${n_gist_all}" "${n_rg_all}" "${n_shared}"
  printf "  %-10s docs  gist --docs %s · rg union %s (inside the shared population)\n" "" "${n_gist_docs}" "${n_rg_docs}"
  printf "  %-10s over  %s files the union calls prose and gist calls code; top: %s\n" "" "${n_over}" "${top_over}"
  printf "  %-10s resc  %s only gist reaches, %s with no extension at all\n" "" "${n_rescued}" "${n_rescued_ext}"
  python3 - << PY > "${w}/receipt.json"
import json
print(json.dumps({
    "population": "${label}",
    "walks": {"gist": ${n_gist_all}, "rg": ${n_rg_all}, "shared": ${n_shared}},
    "docs_population": {"gist": ${n_gist_docs}, "rg_union": ${n_rg_docs}},
    "classification": {
        "over_claimed_by_union": ${n_over},
        "over_claim_top": "${top_over}",
        "rescued_by_genus": ${n_rescued},
        "rescued_without_extension": ${n_rescued_ext},
    },
}))
PY
}

# The hermetic tree. Every file here is a shape that exists in real repositories
# and that the two mechanisms MUST classify differently — nothing is invented to
# flatter the result, and the counts are stated in `fixture_expected.json` beside
# it so the gate asserts a written-down expectation rather than whatever ran.
fixture() {
  local f="${WORK}/tree"
  rm -rf "${f}"
  mkdir -p "${f}/docs/design" "${f}/src" "${f}/third_party/zlib" "${f}/third_party/curl"
  # Build recipes wearing a prose extension. `-t txt` is `*.txt` and cannot
  # except a basename, so the union calls all three prose; the genus keeps them
  # code because the table's build-recipe names shadow the extension.
  for p in "${f}/CMakeLists.txt" "${f}/third_party/zlib/CMakeLists.txt" "${f}/third_party/curl/CMakeLists.txt"; do
    printf 'add_library(thing thing.c)\nproject(thing)\n' > "${p}"
  done
  # A genuine note, which both must call prose — the control that keeps the row
  # above from being "the union is wrong about *.txt" in general.
  printf 'a note about the thing\n' > "${f}/notes.txt"
  # Documents with no extension to name. Promoted by where they live and what
  # they are called; no `-t` name in any tool's registry reaches them.
  printf 'the design of the thing\n' > "${f}/docs/design/OVERVIEW"
  printf '# 1.2.0\n- did the thing\n' > "${f}/CHANGELOG"
  # Controls on the other side: a docs-resident implementation file and a plain
  # source file, both of which must stay code for either tool.
  printf 'project = "thing"\n' > "${f}/docs/conf.py"
  printf 'int main(void) { return 0; }\n' > "${f}/src/main.c"
  # Prose that needs no rescuing, so `--docs` is not measured only on the hard cases.
  printf '# thing\n' > "${f}/README.md"
  python3 - << PY > "${HERE}/fixture_expected.json"
import json
print(json.dumps({
    "note": "hand-written expectation for the hermetic tree the mint builds; "
            "a change here is a change of contract, not of measurement",
    "over_claimed_by_union": 3,
    "over_claim_top": "CMakeLists.txt (3)",
    "rescued_by_genus": 2,
    "rescued_without_extension": 2,
}, indent=1))
PY
  echo "${f}"
}

echo
echo "classification difference over the population BOTH tools walk…"
classify tracked "${CORPUS}" "${SCOPE}" || exit 1
echo
FIXTURE="$(fixture)" || exit 1
classify fixture "${FIXTURE}" "" || exit 1

# ── receipts ────────────────────────────────────────────────────────────────
plat="$(uname -sm)"
python3 - << PY > "${META}"
import json, pathlib
work = pathlib.Path("${WORK}")
# The populations are whatever wrote a receipt, so adding one is a classify
# call and nothing else.
pops = [json.loads(p.read_text()) for p in sorted(work.glob("*/receipt.json"))]
print(json.dumps({
    "platform": "${plat}",
    "runs": ${RUNS},
    "warmup": ${WARMUP},
    "keep_disabled": True,
    "rival": {
        "tool": "rg",
        "derived_from": "gist --type-list --docs  ∩  rg --type-list",
        "union_types": ${n_union},
        "gist_docs_type_rows": ${n_gist_types},
        "types_rg_cannot_name": ${n_unnameable},
    },
    "populations": {p["population"]: p for p in pops},
}, indent=1))
PY

echo
echo "macro  → ${MACRO}"
echo "meta   → ${META}"
echo "raw    → ${WORK}"
echo
echo "gate:  python3 bench/dominance/partition/gate_partition.py"
