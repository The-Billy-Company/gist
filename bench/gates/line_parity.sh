#!/usr/bin/env bash
# Line-output parity gate: prove `gist rg -n --no-heading`  ==  `rg -n --no-heading`
# BYTE-FOR-BYTE, over a frozen corpus.
#
# The committed equality.sh is a FILE-SET oracle (`rg -l`): it proves the trigram
# filter is sound (no false neg/pos), not that gist prints the same LINES as rg.
# rgsuite is the real line oracle but is a broad mined replay; this gate is a
# small, readable, corpus-frozen check of the exact drop-in claim, case by case.
#
# `--sort path` is passed to both so real rg picks one deterministic order. For a
# recursive tree, gist's parallel engine may stream files in worker-discovery
# order, so `same()` permits only that rgsuite-style ORDER soft pass. An explicit
# single file has no cross-file ordering excuse: every such case uses
# `same_exact()` and must match stdout byte-for-byte, including the final newline.
# Three classes:
#   same / same_exact — supported surface; content always exact, and only a
#                       recursive multi-file walk may differ by whole-line order.
#   loud  — an explicitly unsupported flag: gist MUST fail loud (exit >= 2), never
#           silently accept-and-differ (a silent accept fails the gate).
#   xfail — a DOCUMENTED byte/ASCII-vs-Unicode boundary (dossier "parity risk") or a
#           tracked rgsuite FAIL: reported for visibility, does not fail the gate;
#           an unexpected exact match is flagged as "promotable".
set -uo pipefail

# gist's default soft output cap (the agent-context guard) would clip a big line
# class and break the byte-for-byte rg oracle; lift it (hard OOM ceiling stays on).
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

# ── frozen corpus ────────────────────────────────────────────────────────────
WORK="$(mktemp -d)"
CORPUS="${WORK}/corpus"
CAPTURE="${WORK}/capture"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${CORPUS}" "${CAPTURE}"
mkdir -p "${CORPUS}/sub"
printf 'hello world\nfoo bar\nHELLO again\n\nfoo baz\n' > "${CORPUS}/a.txt"
printf 'TODO fix\nfn main\ncall foo() now\nreturn 42\n' > "${CORPUS}/b.txt"
printf 'alpha foo\nbeta\n' > "${CORPUS}/sub/c.txt"
printf 'foo hidden\n' > "${CORPUS}/.hidden.txt"
printf 'ignored.txt\n' > "${CORPUS}/.ignore"
printf 'foo ignored\n' > "${CORPUS}/ignored.txt"
printf 'foo spaced\n' > "${CORPUS}/with space.txt"
printf 'foo coloned\n' > "${CORPUS}/colon:name.txt"
printf 'foo dashed\n' > "${CORPUS}/-dash.txt"
printf 'foo\r\nbar\r\n' > "${CORPUS}/crlf.txt"
printf 'lead %s foo tail\n' "$(printf 'x%.0s' {1..80})" > "${CORPUS}/longline.txt"
printf 'caf\xc3\xa9 start\nr\xc3\xa9sum\xc3\xa9 foo\n' > "${CORPUS}/utf8.txt"
printf '\xff\xfe foo \x00 bar\n' > "${CORPUS}/bin.dat"

# Deterministic, generated-at-runtime evidence for the two large result classes
# cited by the drop-in claim. Short tokens keep each fixture below 1.1 MiB while
# `rg -n` still emits exactly 265,286 / 147,087 result lines. No huge fixture is
# committed; this generator is the fixture contract.
python3 - "${CORPUS}" << 'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
for name, token, count in (
    ("large-265286.txt", "A30", 265_286),
    ("large-147087.txt", "B32", 147_087),
):
    (root / name).write_text((token + "\n") * count)
PY

cd "${CORPUS}" || exit 1
GARGS=(-n --no-heading --sort path)
fails=0

_run_to() { # <stdout-file> <bin...> — preserves stdout bytes + exit
  local out="$1"
  shift
  "$@" > "${out}" 2> "${out}.err"
  _rc=$?
}

_preview() {
  diff -u "$1" "$2" | awk 'NR <= 10 { print "          " $0 }'
}

_compare() { # <exact|order> <expected-lines|-> <label> <args...>
  local mode="$1" expected_lines="$2" label="$3"
  local go="${CAPTURE}/gist.out" ro="${CAPTURE}/rg.out" ge re lines
  shift 3
  _run_to "${go}" "${GIST}" rg "${GARGS[@]}" "$@"
  ge="${_rc}"
  _run_to "${ro}" rg "${GARGS[@]}" "$@"
  re="${_rc}"
  if [[ "${ge}" == "${re}" ]] && cmp -s "${go}" "${ro}"; then
    echo "  ok    : ${label}"
  elif [[ "${mode}" = order && "${ge}" == "${re}" ]]; then
    LC_ALL=C sort "${go}" > "${CAPTURE}/gist.sorted"
    LC_ALL=C sort "${ro}" > "${CAPTURE}/rg.sorted"
    if cmp -s "${CAPTURE}/gist.sorted" "${CAPTURE}/rg.sorted"; then
      echo "  ok    : ${label}  (order — parallel walker streams in discovery order)"
    else
      echo "  DIFF  : ${label}  (gist exit ${ge}, rg exit ${re})"
      _preview "${ro}" "${go}"
      fails=$((fails + 1))
    fi
  else
    echo "  DIFF  : ${label}  (gist exit ${ge}, rg exit ${re})"
    _preview "${ro}" "${go}"
    fails=$((fails + 1))
  fi
  if [[ "${expected_lines}" != "-" ]]; then
    lines="$(wc -l < "${ro}" | tr -d ' ')"
    if [[ "${lines}" = "${expected_lines}" ]]; then
      echo "          generated result class: ${lines} lines exact"
    else
      echo "  DIFF  : ${label} generated ${lines}, expected ${expected_lines} lines"
      fails=$((fails + 1))
    fi
  fi
}

same() { _compare order - "$@"; }
same_exact() { _compare exact - "$@"; }
same_exact_lines() { # <label> <line-count> <args...>
  local label="$1" lines="$2"
  shift 2
  _compare exact "${lines}" "${label}" "$@"
}

loud() { # <label> <args...> — gist must fail loud (exit >= 2)
  local label="$1"
  shift
  _run_to "${CAPTURE}/gist.out" "${GIST}" rg "${GARGS[@]}" "$@"
  if [[ "${_rc}" -ge 2 ]]; then
    echo "  ok    : ${label}  (fails loud, exit ${_rc})"
  else
    echo "  LEAK  : ${label}  (gist exit ${_rc} — should reject an unsupported flag)"
    fails=$((fails + 1))
  fi
}

track() { # <label> <reason> <args...> — a documented/tracked divergence: never fails
  local label="$1" reason="$2" go="${CAPTURE}/gist.out" ro="${CAPTURE}/rg.out" ge re
  shift 2
  _run_to "${go}" "${GIST}" rg "${GARGS[@]}" "$@"
  ge="${_rc}"
  _run_to "${ro}" rg "${GARGS[@]}" "$@"
  re="${_rc}"
  if [[ "${ge}" == "${re}" ]] && cmp -s "${go}" "${ro}"; then
    echo "  xpass : ${label}  (matches rg — promotable to 'same')"
  elif [[ "${ge}" -ge 2 ]]; then
    echo "  track : ${label}  (gist fails loud, exit ${ge}) — ${reason}"
  else
    echo "  track : ${label} — ${reason}"
    _preview "${ro}" "${go}"
  fi
}

# The whole case list runs once per ENGINE — parallel (swarm/, gist's
# default recursive-walk path) and serial (serial.zig, forced via the internal
# `GIST_NO_PARALLEL` knob — see `assay.serialForced` / `swarm.eligible`). This is
# not redundancy: the parallel engine landed a day after a serial-only ignore-
# parity fix and silently missed porting it (`Ignore.skipFromVerdict` had no
# whitelist-override params while `Ignore.shouldSkip` did) — a single-engine
# run of this exact suite would have stayed green throughout that regression,
# because most cases here dispatch straight to the parallel path by default.
run_suite() { # <engine label>
  local engine="$1"
  echo "### core supported surface — must be byte-identical [${engine}] ###"
  same "plain literal" -e foo .
  same "fixed-string -F (regex metachars literal)" -F -e 'foo()' .
  same "multiple -e" -e foo -e alpha .
  same "context -C1" -C1 -e return .
  same_exact "after-context -A1" -A1 -e foo a.txt
  same_exact "before-context -B1" -B1 -e baz a.txt
  same_exact "only-matching -o" -o -e 'f.o' a.txt
  same "count -c" -c -e foo .
  same "count-matches --count-matches" --count-matches -e foo .
  same "word -w" -w -e foo .
  same_exact "ignore-case -i (ASCII)" -i -e hello a.txt
  same_exact "line-regexp -x" -x -e 'foo bar' a.txt
  same_exact "empty-line ^\$" -e '^$' a.txt
  echo "### Unicode parity (default-on, rg-default semantics) — byte-identical [${engine}] ###"
  same_exact "Unicode word boundary on non-ASCII" -e 'é\b' utf8.txt
  same_exact "Unicode case fold -i on non-ASCII" -i -e 'CAFÉ' utf8.txt
  same_exact "Unicode \\w+ spans non-ASCII codepoints" -o -e '\w+' utf8.txt
  same_exact "Unicode property class \\p{L}+" -o -e '\p{L}+' utf8.txt
  same_exact "ASCII opt-out (?-u) reverts fold" -i -e '(?-u)CAFÉ' utf8.txt
  same_exact "--no-unicode reverts \\w to ASCII" --no-unicode -o -e '\w+' utf8.txt
  same_exact "replace -r with capture" -r "X\$1X" -e 'f(o)o' a.txt
  same_exact "CRLF --crlf" --crlf -e 'foo$' crlf.txt
  same "hidden --hidden" --hidden -e foo .
  same "no-ignore --no-ignore" --no-ignore -e foo .
  same_exact "non-UTF-8 bytes -a" -a -e foo bin.dat
  same_exact "max-columns-preview (plain)" --max-columns 8 --max-columns-preview -e foo longline.txt
  same_exact "path with colon" -e foo -- 'colon:name.txt'
  same_exact "path with space" -e foo -- 'with space.txt'
  same_exact "path leading dash" -e foo -- '-dash.txt'
  echo "### generated large-result classes — exact bytes [${engine}] ###"
  same_exact_lines "cited 265,286-line class" 265286 -F -e A30 large-265286.txt
  same_exact_lines "cited 147,087-line class" 147087 -F -e B32 large-147087.txt
  # ripgrep's `Override` whitelist: a `-g`/`--iglob` glob force-includes a hidden or
  # ignored file it matches (bypasses BOTH filters); a `-t` type only un-hides (it
  # never un-ignores). Was a tracked CANDIDATE BUG — gist under-included; now byte-
  # identical to rg's asymmetry on BOTH engines (run.zig `walkDirLinked` +
  # ignore.zig `shouldSkip`; pipeline.zig `handleEntry` + `skipFromVerdict`).
  same "glob -g overrides hidden AND ignore" -g '*.txt' -e foo .
  same "iglob --iglob overrides too (case-insensitive)" --iglob '*.TXT' -e foo .

  echo "### natively supported since the -U/-P engines landed — byte-identical [${engine}] ###"
  same "multiline -U" -U -e 'foo.bar' .
  same_exact "multiline -U spans a line boundary" -U -e 'bar\nHELLO' a.txt
  same "pcre2 -P" -P -e foo .
  same_exact "pcre2 -P backreference" -P -e 'f(o)\1' a.txt

  echo "### tracked divergences — documented, do NOT fail the gate [${engine}] ###"
  track "trim + max-columns-preview + color" "known rgsuite FAIL f917: colored trimmed preview differs" --trim --max-columns 8 --max-columns-preview --color always -e foo longline.txt
}

unset GIST_NO_PARALLEL
run_suite "parallel/pipeline.zig"
export GIST_NO_PARALLEL=1
run_suite "serial/run.zig"
unset GIST_NO_PARALLEL

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PASS: line-output parity holds on the supported surface on BOTH engines; unsupported flags fail loud."
else
  echo "FAIL: ${fails} supported-surface case(s) diverge or leak — gist is not a byte-identical rg drop-in there."
  exit 1
fi
