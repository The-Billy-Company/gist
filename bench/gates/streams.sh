#!/usr/bin/env bash
# gist output-stream contract — the permanent guard for the agent-friendly
# unified engine (`exec/cold/engine/serial.zig` — the sole search engine since the
# search verb merged into it): query RESULTS (match lines / paths / ranked
# rows) belong on **stdout**; nothing else does.
#
# The contract is STRONGER than the old two-engine design (which printed a
# `—`-prefixed timing/count summary to stderr on every query): the default
# rg-parity path with a HIT emits NOTHING on stderr at all — a real ripgrep
# drop-in has no chatter to leak. Two deliberate exceptions: `--rank`
# (`ranked.zig`) keeps its `gist: N ranked matches …` cold-load/rank timing
# line on stderr because an agent choosing between the ranked view and a
# plain query benefits from knowing the cost; and a NO-MATCH run gets the
# structured guidance channel (`emit/hints.zig`) — every line `gist:`-prefixed,
# muted wholesale by `GIST_HINTS=0`. All three shapes are asserted below.
#
# Why this is a gate, not a nicety: gist brands itself an *agent-friendly*
# code locator, and an agent in a shell does `gist foo -l > files` or `gist
# foo | head`. A stray `std.debug.print` reintroduced into the default hot
# path would silently corrupt either capture. This script reproduces that
# failure mode as a falsifiable assertion so it can never regress.
#
# Usage: bench/gates/streams.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../races/_compete.sh
source "${HERE}/../races/_compete.sh"

command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}

echo "building gist (ReleaseFast) + copying binary…"
# Install without executing: the gate must test `zig-out/bin/gist`, never a
# hash-named cache artifact selected by timestamp.
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) \
  || {
    echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
    exit 1
  }
compete_install_gist_bin || exit 1
# The index must exist for the read-elision + --rank paths (the plain walk needs none).
[[ -f "${OUT}/index.gist" ]] || (cd "${REPO}" && "${GIST_BIN}" index > /dev/null 2>&1)

cd "${REPO}" || exit 1
O="$(mktemp)"
E="$(mktemp)"
trap 'rm -f "${O}" "${E}"' EXIT
fails=0

# check <label> <min_stdout_lines> <max_stderr_lines> -- <gist args…>
# stdin is closed so a rootless invocation never mistakes the pty for a piped
# stream and blocks on it (`readableStdin()`, see main.zig's implicit path).
check() {
  local label="$1" minlines="$2" maxerr="$3"
  shift 4
  "${GIST_BIN}" "$@" < /dev/null > "${O}" 2> "${E}"
  local olines elines
  olines="$(grep -c . "${O}")"
  elines="$(grep -c . "${E}")"
  local status="ok"
  if [[ "${olines}" -lt "${minlines}" ]]; then status="FAIL: stdout had ${olines} lines (<${minlines})"; fi
  if [[ "${elines}" -gt "${maxerr}" ]]; then status="FAIL: stderr had ${elines} line(s) (>${maxerr}): $(head -1 "${E}")"; fi
  [[ "${status}" == ok ]] || fails=$((fails + 1))
  printf "  %-34s stdout=%-5s stderr=%-3s  %s\n" "${label}" "${olines}" "${elines}" "${status}"
}

echo
echo "### OUTPUT CONTRACT — results→stdout; stderr silent except --rank's timing line ###"
# Selective literal (index-accelerated read-elision path) — a symbol that exists in this very repo.
check "literal query (index-accelerated)" 1 0 -- WalletService -l
# Ranked output (index-backed) — at least one ranked row, exactly one timing line on stderr.
check "rank (index-backed)" 1 1 -- WalletService --rank
# No-prefilter regex — many matches, still zero stderr.
check "regex query" 1 0 -- '[0-9]{4}' -l
# Sub-trigram literal (<3 B). `-F` forces the literal path rather than an
# unbalanced-regex parse error (`})` carries regex metachars).
check "literal (<3 B needle)" 1 0 -- '})' -F -l

echo
echo "### REGRESSION — the original bug: 'gist … > file' must be NON-EMPTY ###"
"${GIST_BIN}" WalletService -l < /dev/null > "${O}" 2> /dev/null
npaths="$(grep -c . "${O}")"
if [[ -s "${O}" ]]; then
  printf "  %-34s %s\n" "stdout-only capture non-empty" "ok (${npaths} paths)"
else
  printf "  %-34s %s\n" "stdout-only capture non-empty" "FAIL: empty (results went missing or to stderr)"
  fails=$((fails + 1))
fi

# Guaranteed-miss: stdout empty, exit 1 (ripgrep's "no match" code), and stderr
# carries ONLY the structured guidance channel — every line `gist:`-prefixed
# (the no-match summary + `gist: try`/`gist: note:` lines, emit/hints.zig). Under
# `GIST_HINTS=0` both streams must be byte-empty, so a parity harness or
# byte-counting capture can still buy the old total silence. The token is
# built from $RANDOM at runtime so the literal can never appear in any file —
# including this script itself (a fixed literal here would match streams.sh
# and stop being a miss).
miss="zq${RANDOM}${RANDOM}_no_such_symbol_${RANDOM}qz"
"${GIST_BIN}" "${miss}" -l < /dev/null > "${O}" 2> "${E}"
status=$?
stray="$(grep -cv '^gist:' "${E}")"
if [[ ! -s "${O}" ]] && [[ "${stray}" -eq 0 ]] && [[ "${status}" -eq 1 ]]; then
  printf "  %-34s %s\n" "guaranteed-miss structured stderr" "ok"
else
  printf "  %-34s %s\n" "guaranteed-miss structured stderr" "FAIL: stdout non-empty, un-prefixed stderr line, or exit != 1 (got ${status})"
  fails=$((fails + 1))
fi

# The kill switch: GIST_HINTS=0 mutes the guidance channel entirely — both
# streams byte-empty on the same miss, results untouched.
GIST_HINTS=0 "${GIST_BIN}" "${miss}" -l < /dev/null > "${O}" 2> "${E}"
status=$?
if [[ ! -s "${O}" ]] && [[ ! -s "${E}" ]] && [[ "${status}" -eq 1 ]]; then
  printf "  %-34s %s\n" "GIST_HINTS=0 clean streams" "ok"
else
  printf "  %-34s %s\n" "GIST_HINTS=0 clean streams" "FAIL: a stream was non-empty or exit != 1 (got ${status})"
  fails=$((fails + 1))
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: gist keeps results on stdout; stderr carries only the gist:-prefixed guidance channel (--rank timing, no-match hints — muted by GIST_HINTS=0) across the index, rank, and scan paths."
else
  echo "FAILED: ${fails} contract violation(s) — see the table above."
  exit 1
fi
