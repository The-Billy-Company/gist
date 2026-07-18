#!/usr/bin/env bash
# Unicode parity gate: prove `gist rg <pat>`  ==  `rg <pat>`  BYTE-FOR-BYTE at
# ripgrep's DEFAULT (Unicode) semantics, over a frozen multi-script fixture.
#
# gist is a pure BYTE automaton; before this it folded/word-tested ASCII only
# while rg folds Unicode by default. Now gist is Unicode-default too. This gate
# is the falsifiable proof of that parity across the four surfaces the effort
# brought online — Unicode case folding (`-i`/`-S`), Unicode word boundaries
# (`\b`/`-w`), Unicode character/property classes (`\w \d \s .`, `\p{...}`) —
# AND the ASCII opt-out (`(?-u)`, `--no-unicode`) that must reproduce today's
# byte behavior exactly. Any divergence is a Unicode-parity regression.
#
# Every case is stdout+exit-code byte-identical: the fixtures are explicit
# single files (no cross-file ordering excuse). rg is the oracle; the run is
# once per gist engine (parallel pipeline.zig + serial run.zig via the internal
# GIST_NO_PARALLEL knob) since Unicode lowering flows through both.
set -uo pipefail

# Lift gist's default soft output cap so a match-dense fixture can't clip the
# byte-for-byte rg oracle (the hard OOM ceiling stays on).
export GIST_UNCAP=1

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
GIST="${GIST:-${KERNEL}/zig-out/bin/gist}"
command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}
if [[ ! -x "${GIST}" ]]; then
  echo "building gist (ReleaseFast)…"
  (cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
    echo "gist build failed"
    exit 1
  }
fi

# ── frozen multi-script fixture (bytes fixed so the diff can't race) ──────────
WORK="$(mktemp -d)"
CORPUS="${WORK}/corpus"
CAP="${WORK}/cap"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${CORPUS}" "${CAP}"
# Latin-1 diacritics (fold orbits café/CAFÉ, straße), Greek (Σ/σ/ς final-sigma
# orbit), Cyrillic, CJK (no case, word chars), digits across scripts, and a
# deliberately invalid-UTF-8 line (a lone 0xFF must read as a non-word byte).
printf 'caf\xc3\xa9 start\nR\xc3\x89SUM\xc3\x89 done\nstra\xc3\x9fe road\n' > "${CORPUS}/latin.txt"
printf '\xce\xa3\xce\xaf\xcf\x83\xcf\x85\xcf\x86\xce\xbf\xcf\x82 word\n\xce\xba\xcf\x8c\xcf\x83\xce\xbc\xce\xbf\xcf\x82 end\n' > "${CORPUS}/greek.txt"
printf '\xd0\x9c\xd0\xbe\xd1\x81\xd0\xba\xd0\xb2\xd0\xb0 city\n' > "${CORPUS}/cyrillic.txt"
printf '\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e text\n\xef\xbc\x91\xef\xbc\x92\xef\xbc\x93 nums\n' > "${CORPUS}/cjk.txt"
printf 'lead \xff tail word\n' > "${CORPUS}/invalid.txt"

cd "${CORPUS}" || exit 1
fails=0
GARGS=(-n --no-heading --sort path)

_rc=0
_run() { # <out> <bin...>
  local out="$1"
  shift
  "$@" > "${out}" 2> "${out}.err"
  _rc=$?
}

same() { # <label> <args...> — gist default MUST byte-match rg default
  local label="$1"
  shift
  local g="${CAP}/g" r="${CAP}/r" ge re
  _run "${g}" "${GIST}" rg "${GARGS[@]}" "$@"
  ge="${_rc}"
  _run "${r}" rg "${GARGS[@]}" "$@"
  re="${_rc}"
  if [[ "${ge}" == "${re}" ]] && cmp -s "${g}" "${r}"; then
    echo "  ok    : ${label}"
  else
    echo "  DIFF  : ${label}  (gist exit ${ge}, rg exit ${re})"
    diff "${r}" "${g}" | sed 's/^/          /' | head -12
    fails=$((fails + 1))
  fi
}

run_suite() { # <engine label>
  local engine="$1"
  echo "### Unicode case folding — -i / -S [${engine}] ###"
  same "fold café↔CAFÉ (-i)" -i -e 'café' latin.txt
  same "fold uppercase pattern (-i)" -i -e 'CAFÉ' latin.txt
  same "fold ß (German sharp s, -i)" -i -e 'STRASSE' latin.txt
  same "fold Greek Σ orbit incl. final sigma (-i)" -i -e 'ΣΊΣΥΦΟΣ' greek.txt
  same "fold Cyrillic (-i)" -i -e 'МОСКВА' cyrillic.txt
  same "smart-case auto-fold (lowercase, -S)" -S -e 'café' latin.txt
  same "smart-case literal (uppercase, -S)" -S -e 'CAFÉ' latin.txt

  echo "### Unicode classes — \\w \\d \\s . \\p{...} [${engine}] ###"
  same "\\w+ spans non-ASCII" -o -e '\w+' latin.txt
  same "\\w+ over CJK" -o -e '\w+' cjk.txt
  same "\\p{L}+ letters" -o -e '\p{L}+' greek.txt
  same "\\p{Greek}+ script class" -o -e '\p{Greek}+' greek.txt
  same "\\d+ fullwidth digits" -o -e '\d+' cjk.txt
  same "dot matches a codepoint not a byte" -o -e 'caf.' latin.txt
  same "\\W complement" -o -e '\W+' latin.txt

  printf '### Unicode word boundaries — \\b / -w [%s] ###\n' "${engine}"
  same "\\b at non-ASCII edge" -e 'café\b' latin.txt
  same "\\bword\\b after multibyte gap" -e '\bword\b' greek.txt
  same "-w whole-word over Unicode" -w -e 'city' cyrillic.txt
  same "invalid UTF-8 byte is non-word (\\b)" -e '\bword\b' invalid.txt

  echo "### ASCII opt-out — (?-u) / --no-unicode must revert exactly [${engine}] ###"
  same "(?-u) disables fold" -i -e '(?-u)café' latin.txt
  same "--no-unicode \\w is ASCII-only" --no-unicode -o -e '\w+' latin.txt
  same "(?-u)\\w is ASCII-only" -o -e '(?-u)\w+' latin.txt
}

unset GIST_NO_PARALLEL
run_suite "parallel/pipeline.zig"
export GIST_NO_PARALLEL=1
run_suite "serial/run.zig"
unset GIST_NO_PARALLEL

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: gist default ≡ rg default over the Unicode fixture on BOTH engines — fold, classes, boundaries, and the (?-u)/--no-unicode opt-out all byte-identical."
else
  echo "FAILED: ${fails} Unicode-parity case(s) diverge — gist is not a byte-identical rg drop-in there."
  exit 1
fi
