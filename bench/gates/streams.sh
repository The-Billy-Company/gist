#!/usr/bin/env bash
# gist output-stream contract — the permanent guard for the agent-friendly split:
# query RESULTS (match paths / ranked rows) go to **stdout**, human/diagnostic
# lines (the `—` summary, the `[pipeline]` straggler canary, "no index"/"bad
# pattern" guidance) go to **stderr** — exactly the convention `rg` follows.
#
# Why this is a gate, not a nicety: gist brands itself an *agent-friendly* code
# locator, and an agent in a shell does `gist search foo --show files > files`
# and `gist search foo | head`. When results went to stderr (the pre-fix bug), the
# first captured an EMPTY file and the second showed the summary line mixed into
# the paths. This script reproduces that bug as a falsifiable assertion so it
# can never regress: each path is checked for (a) results present on stdout and
# (b) NO diagnostic leaking onto stdout. Any violation ⇒ exit 1.
#
# Usage: bench/streams.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_compete.sh
source "${HERE}/_compete.sh"

command -v rg > /dev/null || { echo "ripgrep (rg) not found on PATH"; exit 1; }

echo "building gist (ReleaseFast) + copying binary…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast cli -- search 'zzqqxxvBUILDONLY' --show files > /dev/null 2>&1) \
  || { echo "  build failed (engine may be mid-refactor by a coworker) — aborting"; exit 1; }
compete_install_gist_bin || exit 1
# The index must exist for the literal/rank index paths (scan path needs none).
[[ -f "${OUT}/index.gist" ]] || (cd "${REPO}" && "${GIST_BIN}" index > /dev/null 2>&1)

cd "${REPO}" || exit 1
O="$(mktemp)"; E="$(mktemp)"
trap 'rm -f "${O}" "${E}"' EXIT
fails=0

# A diagnostic line is the `—`-prefixed summary or a `  [`-prefixed pipeline note
# — the exact two shapes scan_regress.sh strips. stdout must contain NEITHER.
diag_on_stdout() { grep -qE '^—|^  \[' "$1"; }

# check <label> <min_stdout_lines> -- <gist args…>
check() {
  local label="$1" minlines="$2"; shift 3
  "${GIST_BIN}" "$@" > "${O}" 2> "${E}"
  local olines elines
  olines="$(grep -c . "${O}")"; elines="$(grep -c . "${E}")"
  local status="ok"
  # (1) results landed on stdout; (2) no diagnostic leaked onto stdout;
  # (3) the `—` summary IS on stderr (proves the split, not a silent drop).
  if [[ "${olines}" -lt "${minlines}" ]]; then status="FAIL: stdout had ${olines} lines (<${minlines})"; fi
  if diag_on_stdout "${O}"; then status="FAIL: diagnostic line leaked onto stdout"; fi
  if ! grep -qE '^—' "${E}"; then status="FAIL: no '—' summary on stderr"; fi
  [[ "${status}" == ok ]] || fails=$((fails + 1))
  printf "  %-34s stdout=%-5s stderr=%-3s  %s\n" "${label}" "${olines}" "${elines}" "${status}"
}

echo
echo "### OUTPUT CONTRACT — results→stdout, diagnostics→stderr (the gate) ###"
# Selective literal (index path) — a symbol that exists in this very repo.
check "literal query (index path)"   1 -- search WalletService --show files
# Ranked output (index path) — at least one ranked row.
check "rank (index path)"            1 -- search WalletService --rank
# No-prefilter regex (live-tree SCAN path) — many matches + a [pipeline] line.
check "regex scan (no-prefilter)"    1 -- search '[0-9]{4}' --show files
# Sub-trigram literal (<3 B ⇒ SCAN path). `--fixed` forces the literal path the
# old `query` verb always took — `})` carries regex metachars, so without it the
# auto-detector (correctly, rg-consistently) reads it as an unbalanced regex.
check "literal scan (<3 B needle)"   1 -- search '})' --fixed --show files

echo
echo "### REGRESSION — the original bug: 'gist search … > file' must be NON-EMPTY ###"
"${GIST_BIN}" search WalletService --show files > "${O}" 2> /dev/null
npaths="$(grep -c . "${O}")"
if [[ -s "${O}" ]]; then
  printf "  %-34s %s\n" "stdout-only capture non-empty" "ok (${npaths} paths)"
else
  printf "  %-34s %s\n" "stdout-only capture non-empty" "FAIL: empty (results went to stderr)"
  fails=$((fails + 1))
fi

# Guaranteed-miss: stdout MUST be empty (no spurious bytes), summary still on
# stderr. The token is built from $RANDOM at runtime so the literal can never
# appear in any file — including this script itself (a fixed literal here would
# match streams.sh and stop being a miss).
miss="zq${RANDOM}${RANDOM}_no_such_symbol_${RANDOM}qz"
"${GIST_BIN}" search "${miss}" --show files > "${O}" 2> "${E}"
if [[ ! -s "${O}" ]] && grep -qE '^— 0 matches' "${E}"; then
  printf "  %-34s %s\n" "guaranteed-miss clean stdout" "ok"
else
  printf "  %-34s %s\n" "guaranteed-miss clean stdout" "FAIL: stdout not empty or no 0-match summary"
  fails=$((fails + 1))
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: gist routes results→stdout, diagnostics→stderr across the literal, rank, and scan paths (rg-conventional, agent-friendly)."
else
  echo "FAILED: ${fails} contract violation(s) — see the table above."
  exit 1
fi
