#!/usr/bin/env bash
# gist — what the PRODUCTION query path admits, and what that costs in wall time.
#
# `indexq` measures the planner against csearch's on a shared index: the right
# instrument for "is this filter better", the wrong one for "does a user get
# it". This measures the wired path itself — `gist <pattern>`, the same binary a
# user runs — on two axes:
#
#   candidate bytes   read out of `elide.assemble` AFTER the crest subtraction
#                     (`GIST_CANDIDATE_BYTES`), so it is the oracle's real final
#                     candidate set, not the trigram answer alone.
#   end-to-end wall   best-of-N of the whole process: argv, index load, plan,
#                     posting decode, walk, read, match, emit, exit.
#
# Both arms are the SAME binary — `GIST_NO_COVER=1` stands the planner down —
# so an A/B cannot be confounded by a build difference.
#
# Emits `production.tsv` beside this script for `certify_indexq_report.py`.
#
# Usage: bench/dominance/races/production.sh [--runs N] [corpus-root]
set -uo pipefail
export GIST_UNCAP=1

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../apparatus/roots.sh
source "${HERE}/../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1
GIST="${KERNEL}/zig-out/bin/gist"
RUNS=7
if [[ "${1:-}" == "--runs" ]]; then
  RUNS="$2"
  shift 2
fi
ROOT="${1:-${CORPUS}}"
# Beside every other layer's artifact, not beside the script.
OUT="${OUT:-${GIST_VERIFY}/production.tsv}"
mkdir -p "$(dirname "${OUT}")"

[[ -x "${GIST}" ]] || {
  echo "no gist binary at ${GIST} — run: cd ${KERNEL} && zig build -Doptimize=ReleaseFast"
  exit 1
}
cd "${ROOT}" || exit 1

# The same slate `indexq` measures, so the production column is comparable to
# the head-to-head column row for row. `stress-isodate` appears twice on purpose:
# gist's Unicode default reads `\d` as `\p{Nd}` (~680 codepoints, past the
# planner's class ceiling) where csearch's Go `\d` is the 10 ASCII digits, so the
# ASCII spelling is the one that compares like for like.
slate() {
  cat << 'EOF'
stress-goerr	if\s+err\s*!=\s*nil
stress-pubfn	pub\s+fn\s+\w+\(
stress-isodate	\d{4}-\d{2}-\d{2}
stress-isodate-ascii	(?-u)\d{4}-\d{2}-\d{2}
stress-hexlit	0x[0-9a-fA-F]{6}
stress-url	https?://[\w.]+
stress-adr	ADR-\d{3}
stress-wraperr	\.(Unwrap|Wrap)Err\(
stress-nilassign	\w+\s*:=\s*nil
EOF
}

# Candidate bytes + docs for one arm, straight out of the wired path. `worth=0`
# means the oracle declined the table, so the run READ THE WHOLE CORPUS — the
# candidate set it would have had is not what it paid, and reporting that number
# would credit the planner for an elision that never happened.
#
# `GIST_TEST_REQUIRE_ELISION` forces the oracle to load SYNCHRONOUSLY. In
# production it loads on a detached thread the process does not wait for, so a
# query that finishes first simply never completes the stat pass and reports
# nothing — which read as "admitted nothing" and silently dropped six of nine
# rows before this line existed. It affects only this probe: `wall` below times
# the real asynchronous path, unset.
admits() {
  env GIST_CANDIDATE_BYTES=1 GIST_TEST_REQUIRE_ELISION=1 "$@" 2>&1 > /dev/null \
    | sed -n 's/.*candidate_bytes=\([0-9]*\) corpus_bytes=\([0-9]*\) candidate_docs=\([0-9]*\)\/\([0-9]*\) worth=\([0-9]*\).*/\1 \2 \3 \4 \5/p' | head -1
}

# Best-of-N wall microseconds for the whole process. Timed inside ONE python3 so
# the interpreter's own ~20 ms startup never lands inside a measured interval.
wall() {
  python3 - "${RUNS}" "$@" << 'PY'
import subprocess, sys, time

runs, argv = int(sys.argv[1]), sys.argv[2:]
null = subprocess.DEVNULL


def once() -> int:
    start = time.monotonic_ns()
    subprocess.run(argv, stdout=null, stderr=null)
    return time.monotonic_ns() - start


print(min(once() for _ in range(runs)) // 1000)
PY
}

# The corpus's own size, from a probe the oracle always admits. It is the price
# of a run that elides nothing, so it is what BOTH arms are charged whenever
# they decline — without it, a declining arm reports nothing and disappears from
# the average instead of counting as the worst case it is.
read -r _ CORPUS _ TOTAL _ <<< "$(admits "${GIST}" -c 'if\s+err\s*!=\s*nil' .)"
[[ -n "${CORPUS:-}" && "${CORPUS}" -gt 0 ]] || {
  echo "could not size the corpus — is there an index here? (gist index)"
  exit 1
}
printf 'corpus: %s docs, %.1f MB\n\n' "${TOTAL}" "$(python3 -c "print(${CORPUS}/1048576)")"

printf 'class\tpattern\tflat_bytes\tcover_bytes\tcorpus_bytes\tflat_docs\tcover_docs\ttotal_docs\tflat_us\tcover_us\n' > "${OUT}"
printf '%-22s %12s %12s %8s %10s %10s %8s\n' class flat_MB cover_MB delta flat_us cover_us speedup

while IFS=$'\t' read -r class pat; do
  [[ -z "${class}" ]] && continue
  read -r cb _ cd_ _ cw <<< "$(admits "${GIST}" -c "${pat}" .)"
  read -r fb _ fd_ _ fw <<< "$(admits env GIST_NO_COVER=1 "${GIST}" -c "${pat}" .)"
  # No report at all, or `worth=0`: this arm read the WHOLE corpus. Both are the
  # same fact — no elision happened — and both must be charged as such, or the
  # planner gets credit exactly where it helped least.
  corpus=${CORPUS}
  total=${TOTAL}
  if [[ -z "${cb}" || "${cw:-0}" -eq 0 ]]; then
    cb=${corpus}
    cd_=${total}
  fi
  if [[ -z "${fb}" || "${fw:-0}" -eq 0 ]]; then
    fb=${corpus}
    fd_=${total}
  fi
  cus=$(wall "${GIST}" -c "${pat}" .)
  fus=$(wall env GIST_NO_COVER=1 "${GIST}" -c "${pat}" .)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${class}" "${pat}" "${fb}" "${cb}" "${corpus}" "${fd_}" "${cd_}" "${total}" "${fus}" "${cus}" >> "${OUT}"
  printf '%-22s %12.1f %12.1f %7s%% %10s %10s %7sx\n' "${class}" \
    "$(python3 -c "print(${fb}/1048576)")" "$(python3 -c "print(${cb}/1048576)")" \
    "$(python3 -c "print(f'{-100*(${fb}-${cb})/${fb}:.1f}' if ${fb} else '0.0')")" \
    "${fus}" "${cus}" "$(python3 -c "print(f'{${fus}/${cus}:.2f}')")"
done < <(slate)

echo
echo "wrote ${OUT}  (best-of-${RUNS} wall, same binary both arms)"
