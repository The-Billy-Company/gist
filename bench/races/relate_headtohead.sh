#!/usr/bin/env bash
# hydra vs the field — the RELATE race: retrieval by conditional description
# length ("which files would describe this text most cheaply?").
#
# This class has no exact-search competitor: the queries are PARAPHRASES —
# reworded fragments that appear verbatim in no file — so gist/rg answer 0
# hits by design (proven below, not asserted). The honest baseline is what an
# agent actually does today with an exact-search tool: split the query into
# tokens, run one gist per token, and rank files by aggregate hit count. The
# race is therefore three-lane:
#
#   hydra search   one pass — winnowed fingerprint lexicon nominates, the
#                  suffix-automaton cross-parse decides (engine/lexicon.zig +
#                  engine/zipper.zig)
#   gist exact     the paraphrase as a literal — must find NOTHING (capability
#                  line, not a timing lane)
#   gist tokens    K single-token gist runs + awk count aggregation — today's
#                  workflow, timed end-to-end
#
# QUALITY GATE (regression guard): hydra must rank the planted source file
# top-1 for every paraphrase query. A miss exits 1 — this script doubles as
# the relate-class regression check, not just a stopwatch.
#
# Corpus: synthetic + deterministic (never the coworker-mutated live tree):
# COUNT files of source-shaped text sharing heavy boilerplate, each with its
# own topical vocabulary; queries are minted from K of them by rewording.
# Usage:
#   bench/races/relate_headtohead.sh            (COUNT=400 RUNS=8)
#   COUNT=800 RUNS=12 bench/races/relate_headtohead.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"
need_hyperfine

COUNT="${COUNT:-400}"
RUNS="${RUNS:-8}"
WORK="${COMPETE_DIR}/relate"
rm -rf "${WORK}"
mkdir -p "${WORK}/corpus"

echo "building gist+hydra (ReleaseFast) + installing the binaries…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
  exit 1
}
compete_install_gist_bin || exit 1
[[ -x "${HYDRA_BIN}" ]] || {
  echo "  no hydra binary staged — aborting"
  exit 1
}

# ── mint the corpus ──────────────────────────────────────────────────────────
# Every file: the same license/import boilerplate (which must price at ~0
# bits) + 40 lines of file-specific prose built from a per-file vocabulary.
# Deterministic: vocabulary derives from the file index, no RNG.
FILES_PER_DIR=16
echo "minting ${COUNT} files under ${WORK}/corpus (nested, ${FILES_PER_DIR}/dir)…"
python3 - "${WORK}/corpus" "${COUNT}" "${FILES_PER_DIR}" << 'PY'
import pathlib
import sys

root, count, per_dir = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
BOILER = (
    "// SPDX-License-Identifier: MIT\n"
    "// Copyright Billy Co. All rights reserved.\n"
    "const std = @import(\"std\");\n"
    "const testing = std.testing;\n"
)
NOUNS = "ledger wallet socket buffer parser cursor beacon anchor kernel mirror".split()
VERBS = "credits drains frames zeroes walks prices ranks folds seals routes".split()

for i in range(1, count + 1):
    noun, verb = NOUNS[i % len(NOUNS)], VERBS[(i // len(NOUNS)) % len(VERBS)]
    body = [BOILER]
    for j in range(40):
        body.append(
            f"/// the {noun}{i} {verb} the {noun} row {j} atomically and "
            f"records the {noun}{i} outcome in slot {j % 7}\n"
        )
    sub = root / f"sub{(i - 1) // per_dir}"
    sub.mkdir(parents=True, exist_ok=True)
    (sub / f"f{i}.zig").write_text("".join(body))
PY

# ── queries: paraphrases of three planted files ──────────────────────────────
# Reworded (verb moved, filler swapped) so the sentence appears verbatim
# nowhere; the topical vocabulary (noun+index) appears only in the source.
declare -a QUERIES EXPECT
QUERIES+=("atomically the wallet1 credits each wallet row and the wallet1 outcome lands in its slot")
EXPECT+=("f1.zig")
QUERIES+=("every ledger200 outcome is recorded after the ledger200 credits the ledger row")
EXPECT+=("f200.zig")
QUERIES+=("the beacon346 walks its beacon row then the beacon346 outcome fills a slot")
EXPECT+=("f346.zig")

cd "${REPO}" || exit 1
csv="${COMPETE_DIR}/relate.csv"
echo "query,tool,ms,top1,expected,ok" > "${csv}"

echo
echo "── quality gate: hydra top-1 must be the planted source ──"
fail=0
for qi in "${!QUERIES[@]}"; do
  q="${QUERIES[${qi}]}"
  want="${EXPECT[${qi}]}"
  top1="$("${HYDRA_BIN}" search "${q}" --top 1 "${WORK}/corpus" 2> /dev/null | awk '{print $2}')"
  ok=no
  [[ "${top1}" == *"${want}" ]] && ok=yes
  printf "  q%d  hydra → %-40s (want %s)  %s\n" "$((qi + 1))" "${top1:-<none>}" "${want}" "${ok}"
  [[ "${ok}" == yes ]] || fail=1

  # capability line: the paraphrase as an exact literal finds nothing
  if "${GIST_BIN}" -F -c "${q}" "${WORK}/corpus" > /dev/null 2>&1; then
    echo "       unexpected: gist exact-matched a paraphrase (corpus minting bug?)" >&2
    fail=1
  else
    printf "  q%d  gist exact literal → 0 hits (the class is outside exact search)\n" "$((qi + 1))"
  fi
done
[[ "${fail}" -eq 0 ]] || {
  echo "RELATE QUALITY GATE FAILED" >&2
  exit 1
}

# ── timing: hydra one-pass vs the token-grep emulation ───────────────────────
# The emulation is the real workflow this verb replaces: one gist -c per
# token ≥ 4 chars, awk-aggregated per file, sorted. Timed as one pipeline.
emulate_cmd() { # <query> — echoes the full shell pipeline
  local q="$1" toks tok cmds=""
  toks="$(tr ' ' '\n' <<< "${q}" | awk 'length($0)>=4' | sort -u)"
  while read -r tok; do
    cmds+="${GIST_BIN} -F -c '${tok}' '${WORK}/corpus' 2>/dev/null; "
  done <<< "${toks}"
  echo "{ ${cmds} } | awk -F: '{n[\$1]+=\$2} END {for (f in n) print n[f], f}' | sort -rn | head -1"
}

echo
echo "── cold retrieval — fresh process, corpus of ${COUNT} files (hyperfine mean, runs=${RUNS}) ──"
echo "fields: <tool> <ms> (<hydra speedup>)"
echo
for qi in "${!QUERIES[@]}"; do
  q="${QUERIES[${qi}]}"
  want="${EXPECT[${qi}]}"
  hydra_ms="$(hf_mean 3 "${RUNS}" "${HYDRA_BIN} search '${q}' --top 5 '${WORK}/corpus'")" || {
    echo "aborting: hydra failed while timing q$((qi + 1))" >&2
    exit 1
  }
  emu_pipeline="$(emulate_cmd "${q}")"
  emu_ms="$(hf_mean 2 "${RUNS}" "${emu_pipeline}")" || emu_ms="?"
  spd="$(ratio "${emu_ms}" "${hydra_ms}")"
  printf "q%d  hydra %sms   gist-tokens %sms (%s)\n" "$((qi + 1))" "${hydra_ms}" "${emu_ms}" "${spd}"
  echo "q$((qi + 1)),hydra,${hydra_ms},,${want},yes" >> "${csv}"
  echo "q$((qi + 1)),gist-tokens,${emu_ms},,${want}," >> "${csv}"
done

echo
echo "hydra answers the relate class in one pass (fingerprint lexicon → exact"
echo "cross-parse); the exact-search emulation runs one process per token and"
echo "still only counts tokens — it never measures description length. csv → ${csv}"
