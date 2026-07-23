#!/usr/bin/env bash
# certify_relate.sh — Layer G of the Certificate of Optimality (the relate face).
#
# relate answers a question exact search CANNOT: "which files would DESCRIBE this
# text most cheaply?" — retrieval by conditional description length, not pattern
# match. It inherits no Layer-A dominance claim because it is not the same query;
# Layer G certifies what relate actually promises — a retrieval-quality contract
# and the boundary that defines its territory. It is FAIL-CLOSED on four claims
# (the report enforces all four; any violation aborts the mint):
#
#   G1 BOUNDARY      — every paraphrase query finds 0 hits under exact `gist -F`.
#                      The class is provably outside exact search (proven, not
#                      asserted): this is *why* relate exists.
#   G2 RECALL@1      — relate `search` ranks the planted source file top-1 for
#                      every paraphrase (recall@1 = 100%).
#   G3 PACK          — `relate pack` over a two-topic query returns BOTH planted
#                      sources (anti-redundant multi-source retrieval).
#   G4 SHORT RECALL  — `relate search` recalls the single 3-byte planted needle
#                      (sub-trigram recall the persisted codebook handles).
#
# Corpus is synthetic + deterministic (never the coworker-mutated live tree):
# COUNT files sharing heavy boilerplate, each with its own topical vocabulary;
# queries are paraphrases of three planted files, reworded so they appear
# verbatim in no file. Self-contained so the certificate reproduces from its own
# bytes (mirrors bench/races/relate_headtohead.sh, the sibling stopwatch).
#
# Usage:  bench/certify/certify_relate.sh   (COUNT=400 by default)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"

COUNT="${RELATE_COUNT:-400}"
FILES_PER_DIR=16
CERT="${OUT}/CERTIFICATE.md"
RELATE_CSV="${OUT}/relate.csv"
WORK="${COMPETE_DIR}/relatecert"
rm -rf "${WORK}"
mkdir -p "${WORK}/corpus" "${OUT}"

# gist + relate binaries staged deterministically (gist already built by certify.sh;
# this stages the relate face beside it and is a no-op cost if already present).
compete_install_gist_bin || exit 1
[[ -x "${RELATE_BIN}" ]] || {
  echo "certify_relate: no relate binary staged at ${RELATE_BIN}" >&2
  exit 1
}

echo "minting ${COUNT} deterministic files under ${WORK}/corpus…"
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
    if i == 1:
        body.append("// dog\n")
    sub = root / f"sub{(i - 1) // per_dir}"
    sub.mkdir(parents=True, exist_ok=True)
    (sub / f"f{i}.zig").write_text("".join(body))
PY

# Paraphrases of three planted files — reworded so the sentence appears verbatim
# nowhere; the topical vocabulary (noun+index) appears only in the source file.
declare -a QUERIES EXPECT
QUERIES+=("atomically the wallet1 credits each wallet row and the wallet1 outcome lands in its slot")
EXPECT+=("f1.zig")
QUERIES+=("every ledger200 outcome is recorded after the ledger200 credits the ledger row")
EXPECT+=("f200.zig")
QUERIES+=("the beacon346 walks its beacon row then the beacon346 outcome fills a slot")
EXPECT+=("f346.zig")

cd "${REPO}" || exit 1
export GIST_DIR="${WORK}/index"
"${GIST_BIN}" index "${WORK}/corpus" > /dev/null || exit 1

# Results TSV the report validates: claim<TAB>detail<TAB>want<TAB>got<TAB>ok
res="${WORK}/results.tsv"
: > "${res}"
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "${res}"; }

echo "running relate quality contract…"
for qi in "${!QUERIES[@]}"; do
  q="${QUERIES[${qi}]}"
  want="${EXPECT[${qi}]}"
  top1="$("${RELATE_BIN}" search "${q}" --top 1 "${WORK}/corpus" 2> /dev/null | awk '{print $2}')"
  ok=no; [[ "${top1}" == *"${want}" ]] && ok=yes
  row recall "q$((qi + 1))" "${want}" "${top1:-<none>}" "${ok}"

  # boundary: the paraphrase as an exact literal must find nothing.
  if "${GIST_BIN}" -F -c "${q}" "${WORK}/corpus" > /dev/null 2>&1; then
    row boundary "q$((qi + 1))" "0-hits" "matched" no
  else
    row boundary "q$((qi + 1))" "0-hits" "0-hits" yes
  fi
done

# G3 complementary pack — both planted sources in one anti-redundant set.
packed="$("${RELATE_BIN}" pack "wallet1 ledger200" --top 2 "${WORK}/corpus" 2> /dev/null)"
pack_ok=no
[[ "${packed}" == *"f1.zig"* && "${packed}" == *"f200.zig"* ]] && pack_ok=yes
row pack "wallet1+ledger200" "f1.zig+f200.zig" "$([[ "${pack_ok}" == yes ]] && echo both || echo partial)" "${pack_ok}"

# G4 short recall — the 3-byte planted needle.
short="$("${RELATE_BIN}" search dog --top 1 "${WORK}/corpus" 2> /dev/null | awk '{print $2}')"
short_ok=no; [[ "${short}" == *"f1.zig" ]] && short_ok=yes
row short "dog" "f1.zig" "${short:-<none>}" "${short_ok}"

cat > "${WORK}/meta.json" << EOF
{ "count": ${COUNT}, "queries": ${#QUERIES[@]} }
EOF

echo
echo "checking relate quality invariants (fail-closed)…"
python3 "${HERE}/certify_relate_report.py" "${res}" \
  --certificate "${CERT}" \
  --csv "${RELATE_CSV}" \
  --meta "${WORK}/meta.json" || exit 1
echo "relate lane (Layer G, fail-closed) spliced into ${CERT}"
echo "relate-lane CSV → ${RELATE_CSV}"
