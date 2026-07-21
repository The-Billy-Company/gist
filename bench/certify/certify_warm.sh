#!/usr/bin/env bash
# certify_warm.sh — the WARM tier of the Certificate of Optimality (ADR-352 rung 2.5).
#
# The macroscopic Layer A race in certify.sh times gist COLD: a fresh process per
# query that reloads the index and reads candidates — the same regime csearch and
# zoekt run in, and the regime where csearch's index-only path can edge gist on an
# ultra-rare literal because it skips the freshness walk gist pays. That cold race
# is the honest apples-to-apples floor and stays the headline.
#
# But an agent does not fork a fresh gist per query — it drives the resident daemon
# (`gist serve`), which holds the corpus + trigram index warm in RAM and, when its
# FSEvents/inotify watcher proves the tree quiescent, elides the walk entirely
# (`seqlock.skip()`) OR reconciles only the exact dirty set. This tier measures THAT
# path — the one the warm workload actually uses — against the same field.
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
#     The `cold_ms` column separately times INDEX-BACKED cold gist over the same
#     roots — the honest "warm vs cold" speedup. csearch/zoekt/rg stay TIMING rivals
#     over their near-identical corpus (the ~0.1% build-output delta the cold tier documents).
#   * Quiescence is the warm regime by construction: the cert runs in an isolated,
#     clean worktree (no coworker edits), so the watcher stays armed and the skip
#     path fires. On a live tree the scoped reconcile keeps warm correct (never
#     stale), just not maximally fast — that honesty is stated in the certificate.
#
# Usage:  bench/certify/certify_warm.sh          (RUNS=30 WARMUP=5 by default)
#         CERT_OUT=DIR  certificate dir (default <repo>/.local/gist-verify)
# Assumes certify.sh already built the gist index + csearch/zoekt indexes this run
# (it calls this script after the cold race); rebuilds the gist bin/index if missing.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"
need_hyperfine

RUNS="${RUNS:-30}"
WARMUP="${WARMUP:-5}"
CERT="${OUT}/CERTIFICATE.md"
WARM_CSV="${OUT}/certify_warm.csv"
WSOCK="${COMPETE_DIR}/warmcert.$$.sock"

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
echo "  $(tail -1 "${COMPETE_DIR}/warmcert.serve.log")"

# The env prefix every warm query carries: the private socket + autoserve off (a
# cold miss must never fork a rootless daemon onto this socket and re-scope it).
warm_env() { echo "env GIST_SESSION_SOCK='${WSOCK}' GIST_NO_AUTOSERVE=1"; }

# Warm client command for a probe (bare, resident-eligible: no fairness flags).
warm_cmd() { # <literal|regex> <pat>
  local kind="$1" pat="$2"
  if [[ "${kind}" = literal ]]; then
    echo "$(warm_env) ${GIST_BIN} '${pat}' -F -l"
  else echo "$(warm_env) ${GIST_BIN} '${pat}' -l"; fi
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
  bash -c "$(warm_cmd "${kind}" "${pat}")" > /dev/null 2>&1
done

tools_raw="$(compete_tools regex)"
mapfile -t tools <<< "${tools_raw}"
echo
echo "warm-tier race — resident daemon, hyperfine runs=${RUNS} (+${WARMUP} warmup)"
echo "field: gist-warm gist-cold ${tools[*]}"
echo

: > "${WARM_CSV}.tmp"
echo "class,warm_ms,cold_ms,csearch_ms,zoekt_ms,rg_ms,vs_cold,vs_csearch" >> "${WARM_CSV}.tmp"

# One class row: warm gist (equivalence-checked vs the `--no-index` ground truth),
# index-backed cold gist, and each rival. Missing/failed cells become "?" and drop
# out of the geomeans.
for row in "${PROBES[@]}"; do
  read -r class kind pat <<< "${row}"
  wc="$(warm_cmd "${kind}" "${pat}")"
  oracle="$(oracle_cmd "${kind}" "${pat}")"
  cc="$(cold_cmd "${kind}" "${pat}")"

  # Warm must equal the `--no-index` ground truth before it may be timed.
  warm_ms="$(hf_mean "${WARMUP}" "${RUNS}" "${wc}" "${oracle}")" || {
    echo "  ${class}: warm gist failed equivalence/timing — excluded" >&2
    warm_ms="?"
  }
  cold_ms="$(hf_mean "${WARMUP}" "${RUNS}" "${cc}")" || cold_ms="?"

  declare -A rival=([csearch]="?" [zoekt]="?" [rg]="?")
  for t in "${tools[@]}"; do
    [[ -v "rival[${t}]" ]] || continue
    if [[ "${kind}" = literal ]]; then cmd="$(compete_lit_cmd "${t}" "${pat}")"; else cmd="$(compete_rgx_cmd "${t}" "${pat}")"; fi
    rival[${t}]="$(hf_mean "${WARMUP}" "${RUNS}" "${cmd}")" || rival[${t}]="?"
  done

  vs_cold="$(ratio "${cold_ms}" "${warm_ms}")"
  vs_csearch="$(ratio "${rival[csearch]}" "${warm_ms}")"
  printf "  %-18s warm=%-7s cold=%-7s csearch=%-7s zoekt=%-7s rg=%-7s | %s vs cold, %s vs csearch\n" \
    "${class}" "${warm_ms}" "${cold_ms}" "${rival[csearch]}" "${rival[zoekt]}" "${rival[rg]}" "${vs_cold}" "${vs_csearch}"
  echo "${class},${warm_ms},${cold_ms},${rival[csearch]},${rival[zoekt]},${rival[rg]},${vs_cold},${vs_csearch}" >> "${WARM_CSV}.tmp"
done
mv "${WARM_CSV}.tmp" "${WARM_CSV}"
echo
echo "warm-tier CSV → ${WARM_CSV}"

# ── splice the warm section into CERTIFICATE.md (idempotent) ─────────────────
if [[ -s "${CERT}" ]]; then
  python3 "${HERE}/certify_warm_report.py" --certificate "${CERT}" --csv "${WARM_CSV}" \
    --runs "${RUNS}" --warmup "${WARMUP}" --roots "${ROOTS[*]}" \
    && echo "warm tier spliced into ${CERT}"
fi
