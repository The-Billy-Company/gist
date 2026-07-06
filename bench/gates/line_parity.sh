#!/usr/bin/env bash
# Line-output parity gate: prove `gist rg -n --no-heading`  ==  `rg -n --no-heading`
# BYTE-FOR-BYTE, over a frozen corpus.
#
# The committed equality.sh is a FILE-SET oracle (`rg -l`): it proves the trigram
# filter is sound (no false neg/pos), not that gist prints the same LINES as rg.
# rgsuite is the real line oracle but is a broad mined replay; this gate is a
# small, readable, corpus-frozen check of the exact drop-in claim, case by case.
#
# `--sort path` is passed to both so multi-file output has one deterministic order
# (rg honors it; gist already sorts and ignores it) — then a raw string compare is
# a true byte diff. Three classes, so the gate stays green on the supported surface
# while still surfacing the boundaries:
#   same  — core supported surface: MUST be byte-identical (a diff fails the gate).
#   loud  — an explicitly unsupported flag: gist MUST fail loud (exit >= 2), never
#           silently accept-and-differ (a silent accept fails the gate).
#   xfail — a DOCUMENTED byte/ASCII-vs-Unicode boundary (dossier "parity risk") or a
#           tracked rgsuite FAIL: reported for visibility, does not fail the gate;
#           an unexpected exact match is flagged as "promotable".
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)"
GIST="${GIST:-${KERNEL}/zig-out/bin/gist}"
command -v rg > /dev/null || {
  echo "ripgrep (rg) not found on PATH"
  exit 1
}
if [[ ! -x "$GIST" ]]; then
  echo "building gist (ReleaseFast)…"
  (cd "$KERNEL" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
    echo "gist build failed"
    exit 1
  }
fi

# ── frozen corpus ────────────────────────────────────────────────────────────
CORPUS="$(mktemp -d)"
trap 'rm -rf "${CORPUS}"' EXIT
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

cd "${CORPUS}" || exit 1
GARGS=(-n --no-heading --sort path)
fails=0

_run() { # <bin...> — captures stdout+exit into _out/_rc
  local out
  out="$("$@" 2> /dev/null)"
  _rc=$?
  _out="${out}"
}

same() { # <label> <args...>
  local label="$1"
  shift
  _run "$GIST" rg "${GARGS[@]}" "$@"
  local go="$_out" ge="$_rc"
  _run rg "${GARGS[@]}" "$@"
  local ro="$_out" re="$_rc"
  if [[ "$go" == "$ro" && "$ge" == "$re" ]]; then
    echo "  ok    : ${label}"
  else
    echo "  DIFF  : ${label}  (gist exit ${ge}, rg exit ${re})"
    diff <(printf '%s\n' "$ro") <(printf '%s\n' "$go") | head -10 | sed 's/^/          /'
    fails=$((fails + 1))
  fi
}

loud() { # <label> <args...> — gist must fail loud (exit >= 2)
  local label="$1"
  shift
  _run "$GIST" rg "${GARGS[@]}" "$@"
  if [[ "$_rc" -ge 2 ]]; then
    echo "  ok    : ${label}  (fails loud, exit ${_rc})"
  else
    echo "  LEAK  : ${label}  (gist exit ${_rc} — should reject an unsupported flag)"
    fails=$((fails + 1))
  fi
}

track() { # <label> <reason> <args...> — a documented/tracked divergence: never fails
  local label="$1" reason="$2"
  shift 2
  _run "$GIST" rg "${GARGS[@]}" "$@"
  local go="$_out" ge="$_rc"
  _run rg "${GARGS[@]}" "$@"
  local ro="$_out" re="$_rc"
  if [[ "$go" == "$ro" && "$ge" == "$re" ]]; then
    echo "  xpass : ${label}  (matches rg — promotable to 'same')"
  elif [[ "$ge" -ge 2 ]]; then
    echo "  track : ${label}  (gist fails loud, exit ${ge}) — ${reason}"
  else
    echo "  track : ${label} — ${reason}"
    diff <(printf '%s\n' "$ro") <(printf '%s\n' "$go") | head -6 | sed 's/^/          /'
  fi
}

echo "### core supported surface — must be byte-identical ###"
same "plain literal" -e foo .
same "fixed-string -F (regex metachars literal)" -F -e 'foo()' .
same "multiple -e" -e foo -e alpha .
same "context -C1" -C1 -e return .
same "after-context -A1" -A1 -e foo a.txt
same "before-context -B1" -B1 -e baz a.txt
same "only-matching -o" -o -e 'f.o' a.txt
same "count -c" -c -e foo .
same "count-matches --count-matches" --count-matches -e foo .
same "word -w" -w -e foo .
same "ignore-case -i (ASCII)" -i -e hello a.txt
same "line-regexp -x" -x -e 'foo bar' a.txt
same "empty-line ^\$" -e '^$' a.txt
same "replace -r with capture" -r 'X$1X' -e 'f(o)o' a.txt
same "CRLF --crlf" --crlf -e 'foo$' crlf.txt
same "hidden --hidden" --hidden -e foo .
same "no-ignore --no-ignore" --no-ignore -e foo .
same "non-UTF-8 bytes -a" -a -e foo bin.dat
same "max-columns-preview (plain)" --max-columns 8 --max-columns-preview -e foo longline.txt
same "path with colon" -e foo -- 'colon:name.txt'
same "path with space" -e foo -- 'with space.txt'
same "path leading dash" -e foo -- '-dash.txt'

echo "### unsupported flags — must fail loud (never silently differ) ###"
loud "multiline -U" -U -e 'foo.bar' .
loud "pcre2 -P" -P -e foo .

echo "### tracked divergences — documented, do NOT fail the gate ###"
track "glob -g vs hidden/ignore" "CANDIDATE BUG: gist -g includes hidden/ignored files matching the glob; rg keeps them filtered" -g '*.txt' -e foo .
track "trim + max-columns-preview + color" "known rgsuite FAIL f917: colored trimmed preview differs" --trim --max-columns 8 --max-columns-preview --color always -e foo longline.txt
track "Unicode word boundary on non-ASCII" "gist is a byte/ASCII (?-u) engine; rg default \\b is Unicode-aware" -e 'é\b' utf8.txt
track "Unicode case fold -i on non-ASCII" "gist folds ASCII only; rg default -i folds Unicode" -i -e 'CAFÉ' utf8.txt

echo
if [[ "$fails" -eq 0 ]]; then
  echo "PASS: line-output parity holds on the supported surface; unsupported flags fail loud."
else
  echo "FAIL: ${fails} supported-surface case(s) diverge or leak — gist is not a byte-identical rg drop-in there."
  exit 1
fi
