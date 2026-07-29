#!/usr/bin/env bash
# certify_warm.sh — the WARM tier of the Dominance-and-Fit Certificate (ADR-352 rung 2.5).
#
# The macroscopic Layer A race in certify.sh times gist COLD: a fresh process per
# query that reloads the index and reads candidates — the same regime csearch and
# zoekt run in, and the regime where csearch's index-only path can edge gist on an
# ultra-rare literal because it skips the freshness walk gist pays. That cold race
# is the honest apples-to-apples floor and stays the headline.
#
# But an agent does not fork a fresh gist per query — it drives the resident daemon
# (`gist serve`), which holds the corpus + trigram index warm in RAM and, when its
# FSEvents/inotify watcher proves the tree quiescent, elides the freshness walk
# (`seqlock.skip()`) OR reconciles only the exact dirty set. This tier measures THAT
# path — the one the warm workload actually uses — against the same field.
#
# FAIL-CLOSED (this is the upgrade over the old descriptive-geomean tier): each
# probe class now exports the full per-run hyperfine sample vector, and the report
# renders the SAME statistic the cold macro uses — a 95% bootstrap-CI median + a
# Mann-Whitney U verdict vs ripgrep. A warm WIN requires a lower median AND
# p < 0.05; a warm LOSS vs ripgrep on any class aborts the mint (a real regression,
# not box noise). Warm no longer inherits Layer A's claim descriptively — it earns
# its own statistically-significant one.
#
# FAIRNESS — same corpus, honest oracle:
#   * The daemon is scoped to the SAME ROOTS as the cold race (`gist serve $ROOTS`)
#     on a PRIVATE socket, so it never collides with the shared rootless autoserve
#     daemon coworker CLIs spawn. Warm queries dial that socket with autoserve off.
#   * The warm client cannot take the cold race's `--no-ignore-vcs --ignore-file`
#     fairness flags (the resident classifier declines any flag/PATH → cold), so
#     warm gist walks gist's DEFAULT set. Its equivalence ORACLE is `gist --no-index`
#     over that same default walk — a pure live scan that is the certified ground
#     truth of the elision-parity invariant (`index == --no-index == rg`) and is
#     immune to a concurrently-rebuilt `index.gist` (the one flake a live coworking
#     tree can inject). Proving `warm == --no-index` therefore proves `warm == cold`
#     transitively, without a shared index the two paths could disagree on mid-mint.
#     The `cold` cell separately times INDEX-BACKED cold gist over the same
#     roots — the honest "warm vs cold" speedup. csearch/zoekt/rg stay TIMING rivals
#     over their near-identical corpus (the ~0.1% build-output delta the cold tier documents).
#   * Quiescence is the warm regime by construction: the cert runs in an isolated,
#     clean worktree (no coworker edits), so the watcher stays armed and the skip
#     path fires. On a live tree the scoped reconcile keeps warm correct (never
#     stale), just not maximally fast — that honesty is stated in the certificate.
#
# Usage:  bench/certificate/mint/warm.sh          (RUNS=30 WARMUP=5 by default)
#         CERT_OUT=DIR  certificate dir (default <repo>/.local/gist-verify)
# Assumes mint.sh already built the gist index + csearch/zoekt indexes this run
# (it calls this script after the cold race); rebuilds the gist bin/index if missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../dominance/races/field.sh
source "${HERE}/../../dominance/races/field.sh"
need_hyperfine

RUNS="${RUNS:-30}"
WARMUP="${WARMUP:-5}"
CERT="${OUT}/CERTIFICATE.md"
WARM_CSV="${OUT}/certify_warm.csv"
WORK="${COMPETE_DIR}/warmcert"
WSOCK="${COMPETE_DIR}/warmcert.$$.sock"
rm -rf "${WORK}"
mkdir -p "${WORK}" "${OUT}"

# The 12 classes — byte-identical to certify.sh's PROBES so the warm table maps
# 1:1 onto the cold macroscopic table by class name.
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
  "regex-litalt regex panic|0x"
)

[[ -x "${GIST_BIN}" ]] || compete_build_gist_index || exit 1
[[ -f "${PATHS_LIST}" ]] || {
  echo "certify_warm: no ${PATHS_LIST} — run gist index (or certify.sh) first" >&2
  exit 1
}

# ── scoped resident daemon on a private socket ───────────────────────────────
DAEMON_PID=""
cleanup() {
  [[ -n "${DAEMON_PID}" ]] && kill -9 "${DAEMON_PID}" 2> /dev/null
  rm -f "${WSOCK}" "${WSOCK}.lock"
}
trap cleanup EXIT

echo "starting scoped resident daemon (roots: ${ROOTS[*]})…"
GIST_SESSION_SOCK="${WSOCK}" "${GIST_BIN}" serve "${ROOTS[@]}" > "${COMPETE_DIR}/warmcert.serve.log" 2>&1 &
DAEMON_PID=$!
bound=""
for _ in $(seq 1 40); do
  [[ -S "${WSOCK}" ]] && {
    bound=1
    break
  }
  kill -0 "${DAEMON_PID}" 2> /dev/null || {
    echo "certify_warm: daemon exited before binding — see ${COMPETE_DIR}/warmcert.serve.log" >&2
    exit 1
  }
  sleep 1
done
[[ -n "${bound}" ]] || {
  echo "certify_warm: daemon never bound ${WSOCK}" >&2
  exit 1
}
serve_status="$(tail -1 "${COMPETE_DIR}/warmcert.serve.log")"
echo "  ${serve_status}"

# The env prefix every warm query carries: the private socket + autoserve off (a
# cold miss must never fork a rootless daemon onto this socket and re-scope it).
WARM_ENV="env GIST_SESSION_SOCK='${WSOCK}' GIST_NO_AUTOSERVE=1"

# Warm client command for a probe (bare, resident-eligible: no fairness flags).
warm_cmd() { # <literal|regex> <pat>
  local kind="$1" pat="$2"
  if [[ "${kind}" = literal ]]; then
    echo "${WARM_ENV} ${GIST_BIN} '${pat}' -F -l"
  else echo "${WARM_ENV} ${GIST_BIN} '${pat}' -l"; fi
}

# The equivalence ORACLE: `gist --no-index` over the same default walk — the
# certified live-scan ground truth (`index == --no-index == rg`), immune to a
# coworker rebuilding index.gist mid-mint. Proving warm == this proves warm == cold.
oracle_cmd() { # <literal|regex> <pat>
  local kind="$1" pat="$2" roots="${ROOTS[*]}"
  if [[ "${kind}" = literal ]]; then
    echo "${GIST_BIN} '${pat}' -F -l --no-index -- ${roots}"
  else echo "${GIST_BIN} '${pat}' -l --no-index -- ${roots}"; fi
}

# INDEX-BACKED cold gist over the same roots — the honest "warm vs cold" timing
# reference (a fresh process reloading the index + reading candidates per query).
cold_cmd() { # <literal|regex> <pat>
  local kind="$1" pat="$2" roots="${ROOTS[*]}"
  if [[ "${kind}" = literal ]]; then
    echo "${GIST_BIN} '${pat}' -F -l -- ${roots}"
  else echo "${GIST_BIN} '${pat}' -l -- ${roots}"; fi
}

# Warm the session: one covering query per probe so the daemon's first-full-pass
# is paid before timing, and the watcher's armed-clean state is reached.
echo "warming the resident session…"
for row in "${PROBES[@]}"; do
  read -r _ kind pat <<< "${row}"
  cmd="$(warm_cmd "${kind}" "${pat}")"
  bash -c "${cmd}" > /dev/null 2>&1
done

tools_raw="$(compete_tools regex)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "warm-tier race — resident daemon, hyperfine runs=${RUNS} (+${WARMUP} warmup)"
echo "field: gist-warm gist-cold ${tools[*]}"
echo

# One hyperfine JSON per (class, cell) into ${WORK}, exactly like the cold macro,
# so the report can run the same bootstrap-CI + Mann-Whitney statistic. A warm
# cell is equivalence-gated vs its `--no-index` oracle before it may be timed; a
# competitor cell is status-gated. Retries one clean cell on a transient failure.
bench_cell() { # <class> <cell-id> <cmd> [oracle] → 0 timed, 1 rejected
  local class="$1" cell="$2" cmd="$3" oracle="${4:-}" attempt
  [[ -z "${cmd}" || "${cmd}" = "false" ]] && return 1
  if [[ -n "${oracle}" ]]; then
    compete_precheck_equivalent "${cmd}" "${oracle}" "${class}/${cell}" || return 1
  else
    compete_precheck_status "${cmd}" "${class}/${cell}" || return 1
  fi
  for attempt in 1 2; do
    rm -f "${WORK}/${class}__${cell}.json"
    if compete_hyperfine --warmup "${WARMUP}" --runs "${RUNS}" \
      --export-json "${WORK}/${class}__${cell}.json" "${cmd}" > /dev/null 2>&1; then
      return 0
    fi
    [[ "${attempt}" = 1 ]] && echo "  transient warm-timing failure ${class}/${cell}; retrying…" >&2
  done
  echo "  warm CELL FAILED ${class}/${cell}: ${cmd}" >&2
  return 1
}

: > "${WORK}/order.tsv"
for row in "${PROBES[@]}"; do
  read -r class kind pat <<< "${row}"
  printf '%s\t%s\t%s\n' "${class}" "${kind}" "${pat}" >> "${WORK}/order.tsv"

  # Warm gist is the subject: it must equal the --no-index ground truth AND time
  # cleanly, or the warm certificate is invalid — abort the mint (fail-closed).
  warm="$(warm_cmd "${kind}" "${pat}")"
  oracle="$(oracle_cmd "${kind}" "${pat}")"
  bench_cell "${class}" warm "${warm}" "${oracle}" || {
    echo "certificate aborted: warm gist failed equivalence/timing on ${class}" >&2
    exit 1
  }
  # Index-backed cold gist — the honest vs-cold reference (subject too: abort).
  cold="$(cold_cmd "${kind}" "${pat}")"
  bench_cell "${class}" cold "${cold}" || {
    echo "certificate aborted: cold gist reference failed on ${class}" >&2
    exit 1
  }
  printf "  %-18s warm+cold timed" "${class}"
  # Rivals: a competitor hard failure warns + excludes that cell, never aborts.
  for t in "${tools[@]}"; do
    if [[ "${kind}" = literal ]]; then cmd="$(compete_lit_cmd "${t}" "${pat}")"; else cmd="$(compete_rgx_cmd "${t}" "${pat}")"; fi
    bench_cell "${class}" "${t}" "${cmd}" && printf " %s" "${t}"
  done
  echo " done"
done

cat > "${WORK}/meta.json" << EOF
{ "runs": ${RUNS}, "warmup": ${WARMUP}, "roots": "${ROOTS[*]}" }
EOF

echo
echo "computing bootstrap-CI medians + Mann-Whitney dominance (warm gist vs rg)…"
python3 "${HERE}/../report/warm.py" "${WORK}" \
  --certificate "${CERT}" \
  --csv "${WARM_CSV}" \
  --order "${WORK}/order.tsv" \
  --meta "${WORK}/meta.json" || exit 1
echo "warm tier (fail-closed dominance) spliced into ${CERT}"
echo "warm-tier CSV → ${WARM_CSV}"
