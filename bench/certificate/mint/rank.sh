#!/usr/bin/env bash
# certify_rank.sh — the `--rank` LANE of Layer A (the one output shape rg can't express).
#
# `gist <pat>` answers WHERE a pattern appears, ripgrep-identically. `--rank`
# answers WHICH of those hits matters most: it cold-loads the trigram index,
# resolves the SAME candidate set the locate path uses, extracts per-file features
# in a parallel read pass, fuses them with the weighted-RRF kernel (`rank/rank.zig`),
# and prints the top-K as `path:line [kind] ×count line` — a definition outranking
# its call sites, codegen sunk below authored code. No scanner can produce this at
# all, so it inherits no Layer-A dominance claim; this lane certifies it directly.
#
# FAIL-CLOSED evidence (the report enforces all five; any violation aborts the mint):
#   1. SET-EQUALITY — the ranked set (`--rank=∞`, every row) is byte-identical to the
#      plain `gist -l` set over the same query+roots. Ranking is a REORDERING, never a
#      filtering: --rank hides nothing a locate would find, and invents nothing it
#      wouldn't. This is the correctness spine of the whole lane.
#   2. DEFINITION BOOST — where a probe's match set holds both definitions and uses,
#      the median rank position of `[def]` rows is above the median `[use]` position.
#      (Aggregate, not "#1 is always a def" — a single hot test file legitimately
#      tops a use; the fusion boosts defs systematically, which is the honest claim.)
#   3. CODEGEN DEMOTION — where authored and demoted (`[gen]`/`[mirror]`) rows coexist,
#      the median demoted position sinks below the median authored position (the
#      generated weight in rank.zig is set to outrank the codegen double-boost).
#   4. BOUNDED OVERHEAD — --rank's median never exceeds a small multiple of plain
#      `gist -l` (it reads+scores every candidate, yet surfaces only top-K).
#   5. BEATS RIPGREP (SELECTIVE regime) — where the trigram prefilter prunes the corpus
#      to a small candidate minority, --rank is significantly faster than `rg` (Mann-Whitney
#      win): it reads that minority where rg re-walks the whole tree. A saturating needle (a
#      common token matching a large fraction of files) gets no prefilter edge and ranking is
#      strictly more work than a raw scan, so rg legitimately wins there — its certified claim
#      is #4 (bounded vs `gist -l`), and beats-rg is reported but not gated.
#
# Usage:  bench/certify/certify_rank.sh   (RUNS=20 WARMUP=3 by default)
# Assumes certify.sh already built the gist index this run (it calls this after warm).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../dominance/races/field.sh
source "${HERE}/../../dominance/races/field.sh"
need_hyperfine
command -v rg > /dev/null || {
  echo "rank lane needs ripgrep (brew install ripgrep)" >&2
  exit 1
}

RUNS="${RUNS:-20}"
WARMUP="${WARMUP:-3}"
CERT="${OUT}/CERTIFICATE.md"
RANK_CSV="${OUT}/certify_rank.csv"
WORK="${COMPETE_DIR}/rankcert"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT}"

# Symbol probes chosen for structure, not rarity: each has authored + generated
# hits; most carry both definitions and uses (pgxpool/Store/func/NewStore/
# compileOpts), and WalletService deliberately has uses + generated but NO
# definition — it exercises the "skip def-boost when no def exists, still demote
# codegen" path so the invariants can't silently pass by vacuity.
PROBES=(
  "pgxpool pgxpool"
  "Store Store"
  "func func"
  "NewStore NewStore"
  "compileOpts compileOpts"
  "WalletService WalletService"
)

[[ -x "${GIST_BIN}" ]] || compete_build_gist_index || exit 1
[[ -f "${OUT}/index.gist" ]] || (cd "${CORPUS}" && "${GIST_BIN}" index) || {
  echo "certify_rank: no persisted index at ${OUT}/index.gist" >&2
  exit 1
}

roots="${ROOTS[*]}"
# Autoserve off on every gist cell: --rank reads the persisted index directly, so a
# stray resident daemon must never re-scope or shadow it — the cold-rank path is the
# honest, deterministic one to certify (matches the isolated-worktree mint conditions).
GENV="GIST_NO_AUTOSERVE=1"

# Export a full per-run hyperfine sample vector for one cell (status-gated, one retry).
bench_cell() { # <name> <cell> <cmd> → 0 timed, 1 rejected
  local name="$1" cell="$2" cmd="$3" _attempt
  compete_precheck_status "${cmd}" "${name}/${cell}" || return 1
  for _attempt in 1 2; do
    rm -f "${WORK}/${name}__${cell}.json"
    compete_hyperfine --warmup "${WARMUP}" --runs "${RUNS}" \
      --export-json "${WORK}/${name}__${cell}.json" "${cmd}" > /dev/null 2>&1 && return 0
  done
  echo "  rank CELL FAILED ${name}/${cell}: ${cmd}" >&2
  return 1
}

echo "rank lane — index-backed --rank vs plain gist -l vs ripgrep (roots: ${roots})"
echo "hyperfine runs=${RUNS} (+${WARMUP} warmup)"
echo

: > "${WORK}/probes.tsv"
for row in "${PROBES[@]}"; do
  read -r name pat <<< "${row}"
  printf '%s\t%s\t%s\n' "${name}" "${pat}" "${roots}" >> "${WORK}/probes.tsv"

  # The oracle SET from a plain locate over the DEFAULT walk (no fairness flags:
  # --rank uses gist's default ignore semantics, so the -l oracle must too).
  compete_capture_set "${GENV} ${GIST_BIN} '${pat}' -l --sort none -- ${roots}" \
    "${WORK}/${name}.setl" "${name}/gist-l-set" || exit 1
  # The FULL ranked output (every row) — the set + per-row kind source.
  if ! env GIST_NO_AUTOSERVE=1 "${GIST_BIN}" "${pat}" --rank=1000000 -- "${ROOTS[@]}" > "${WORK}/${name}.rank" 2> /dev/null; then
    echo "certify_rank: --rank query failed for ${name}" >&2
    exit 1
  fi

  # Timing cells: default top-20 --rank, plain -l, fair rg.
  bench_cell "${name}" rank "${GENV} ${GIST_BIN} '${pat}' --rank=20 -- ${roots}" || exit 1
  bench_cell "${name}" gistl "${GENV} ${GIST_BIN} '${pat}' -l --sort none -- ${roots}" || exit 1
  bench_cell "${name}" rg "rg '${pat}' -l --sort none --no-ignore-vcs --ignore-file '${CORPUS}/.gitignore' -- ${roots}" \
    || echo "  (rg cell missing for ${name} — beats-rg skipped)"
  printf "  %-16s ranked+timed\n" "${name}"
done

# Corpus size splits selective (prefilter prunes → beats-rg gated) from saturating
# needles in the report. Prefer the machine.json the mint already wrote; fall back to
# the persisted paths.list; 0 = unknown (report then uses an absolute-count threshold).
corpus_files="$(
  python3 - "${OUT}/machine.json" "${PATHS_LIST}" << 'PY'
import json, sys

machine_json, paths_list = sys.argv[1], sys.argv[2]
n = 0
try:
    n = int(json.load(open(machine_json)).get("corpus_file_count") or 0)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    n = 0
if n <= 0:
    try:
        with open(paths_list, "rb") as fh:
            n = sum(1 for p in fh.read().split(b"\0") if p)
    except OSError:
        n = 0
print(n)
PY
)"

cat > "${WORK}/meta.json" << EOF
{ "runs": ${RUNS}, "warmup": ${WARMUP}, "roots": "${roots}", "corpus_files": ${corpus_files} }
EOF

echo
echo "checking set-equality + rank invariants + dominance…"
python3 "${HERE}/../report/rank.py" "${WORK}" \
  --certificate "${CERT}" \
  --csv "${RANK_CSV}" \
  --probes "${WORK}/probes.tsv" \
  --meta "${WORK}/meta.json" || exit 1
echo "rank lane (fail-closed) spliced into ${CERT}"
echo "rank-lane CSV → ${RANK_CSV}"
