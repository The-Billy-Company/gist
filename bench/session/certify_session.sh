#!/usr/bin/env bash
# gist RESIDENT-SESSION certificate — the honest warm-product path (ADR-352 rung 2.5).
#
# The cold certificate (`../certify/`) proves gist's fresh-process query is at
# parity-or-faster than ripgrep. The warm head-to-head (`../races/headtohead.sh`)
# times gist's IN-PROCESS engine — the microsecond ceiling, but not a path a real
# client rides. THIS certificate closes that gap: it measures the number a
# long-lived client actually sees — a `gist serve` daemon dialed ONCE over a Unix
# socket, then a query slate replayed over that single warm connection (no
# per-query process spawn, no index reload). That is the resident daemon's whole
# reason to exist, and the only honest basis for a "warm is Nx faster" claim.
#
# Two truths this certificate refuses to hide:
#   * gist's matched-file set is a systematic subset of rg's (a corpus-walker
#     difference owned by the COLD certificate); the daemon tracks the COLD gist
#     set, not rg's. We print both counts so the speedup is never mistaken for a
#     like-for-like set. Exact warm==cold==oracle correctness is gated
#     hermetically by the Zig suite (serve/resident/freshness tests), not here.
#   * The warm fast path is only armed where a filesystem watcher can prove
#     quiescence (Linux inotify + macOS FSEvents today). Without one, every query
#     reconciles (a full metadata walk): correct, but it pays the freshness tax.
#     We measure and label whatever THIS platform delivers, and the latency gate
#     (`gate_session.py`) enforces a floor ONLY on the armed path.
#
# Usage:  cd pkg/kernels/gist && bench/session/certify_session.sh
#         RUNS=12 WARMUP=3 bench/session/certify_session.sh   # tune rg timing
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"
need_hyperfine

RUNS="${RUNS:-10}"
WARMUP="${WARMUP:-2}"
BENCH_EXE="${KERNEL}/zig-out/bin/gist-bench"
SESSION_CSV="${OUT}/session.csv"  # (needle, warm_p50_ns, daemon_files) — emitted by gist-bench
MACRO="${HERE}/session_macro.csv" # (needle, daemon_files, rg_files, warm_p50_ms, rg_ms, speedup)
CERT="${OUT}/CERTIFICATE_SESSION.md"

sys="$(uname -s)"
uname_sm="$(uname -sm)"
armed="no"
watcher="reconcile-always (no watcher backend)"
case "${sys}" in
  Linux)
    armed="yes"
    watcher="inotify (recursive)"
    ;;
  Darwin)
    armed="yes"
    watcher="FSEvents (recursive stream)"
    ;;
  *) ;;
esac

echo "building gist + gist-bench + index…"
compete_build_gist_index || exit 1
[[ -x "${BENCH_EXE}" ]] || {
  echo "no gist-bench at ${BENCH_EXE}" >&2
  exit 1
}

echo "measuring the persistent client → daemon path (warm p50 per needle)…"
(cd "${REPO}" && "${BENCH_EXE}" session) || exit 1
[[ -s "${SESSION_CSV}" ]] || {
  echo "gist-bench session emitted no ${SESSION_CSV}" >&2
  exit 1
}

echo
echo "warm persistent-client latency vs ripgrep cold (fresh process), runs=${RUNS}:"
printf '%-16s %8s %8s %12s %12s %9s\n' needle d_files rg_files warm_p50 rg_mean speedup
printf '%-16s %8s %8s %12s %12s %9s\n' ---------------- ------- ------- ------------ ------------ ---------

cd "${REPO}" || exit 1
: > "${MACRO}"
logsum=0
n=0
while IFS=$'\t' read -r needle p50_ns dfiles; do
  [[ -n "${needle}" ]] || continue
  warm_ms="$(python3 -c "print('%.4f'%(${p50_ns}/1e6))")"
  rcmd="$(compete_lit_cmd rg "${needle}")"
  rg_files="$(bash -c "${rcmd}" 2> /dev/null | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  if ! rg_ms="$(hf_mean "${WARMUP}" "${RUNS}" "${rcmd}")"; then
    echo "  rg hard-failed on '${needle}'" >&2
    exit 1
  fi
  spd="$(ratio "${rg_ms}" "${warm_ms}")"
  printf '%-16s %8s %8s %10s ms %10s ms %9s\n' "${needle}" "${dfiles}" "${rg_files}" "${warm_ms}" "${rg_ms}" "${spd}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${needle}" "${dfiles}" "${rg_files}" "${warm_ms}" "${rg_ms}" "${spd%x}" >> "${MACRO}"
  if [[ "${rg_ms}" != "?" ]]; then
    logsum="$(python3 -c "import math;print(${logsum}+math.log(${rg_ms}/${warm_ms}))")"
    n=$((n + 1))
  fi
done < "${SESSION_CSV}"

geo="$(python3 -c "import math;print('%.1f'%math.exp(${logsum}/${n}) if ${n} else 0)")"
echo
printf '── geomean warm speedup vs rg cold: %sx  ·  watcher: %s  ·  armed fast path: %s ──\n' "${geo}" "${watcher}" "${armed}"

# Machine-readable provenance for gate_session.py (armed decides floor enforcement).
python3 - "${HERE}/session_meta.json" "${armed}" "${watcher}" "${geo}" "${uname_sm}" "${n}" << 'PY'
import json, sys
path, armed, watcher, geo, plat, n = sys.argv[1:7]
json.dump({"armed": armed == "yes", "watcher": watcher, "platform": plat,
           "geomean_speedup": float(geo), "needles": int(n)},
          open(path, "w"), indent=2)
open(path, "a").write("\n")
PY

{
  echo "# gist resident-session certificate (ADR-352 rung 2.5)"
  echo
  echo "- **path measured:** persistent client → \`gist serve\` daemon over a Unix socket,"
  echo "  one connection reused across the whole slate (no per-query process spawn)."
  echo "- **platform:** \`${uname_sm}\`"
  echo "- **watcher backend:** ${watcher}"
  echo "- **armed fast path:** ${armed} — the latency floor (\`gate_session.py\`) is enforced"
  echo "  only when armed; otherwise every query reconciles (freshness tax) and the number"
  echo "  below is reported, not gated."
  echo "- **geomean warm speedup vs ripgrep cold:** **${geo}×**"
  echo
  echo "\`d_files\` is the daemon's matched-file count; \`rg_files\` is ripgrep's. gist's set is"
  echo "a systematic subset of rg's (a corpus-walker difference owned by the cold certificate);"
  echo "exact warm==cold==oracle parity is gated hermetically by the Zig suite, not here."
  echo
  echo '| needle | d_files | rg_files | warm p50 (ms) | rg mean (ms) | speedup |'
  echo '| --- | ---: | ---: | ---: | ---: | ---: |'
  while IFS=$'\t' read -r needle dfiles rgf warm rg spd; do
    # shellcheck disable=SC2016  # backticks here are literal Markdown, not command substitution
    printf '| `%s` | %s | %s | %s | %s | %s× |\n' "${needle}" "${dfiles}" "${rgf}" "${warm}" "${rg}" "${spd}"
  done < "${MACRO}"
} > "${CERT}"
cp "${SESSION_CSV}" "${HERE}/session.csv" 2> /dev/null || true

echo "certificate → ${CERT}"
echo "macro csv   → ${MACRO}"
