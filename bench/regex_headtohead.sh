#!/usr/bin/env bash
# gist vs ripgrep — the REGEX cold head-to-head, rg given its fastest honest path.
#
# Model (mirrors coldquery.sh, the literal counterpart): build + persist the
# index ONCE, then every query is a fresh process that cold-loads the index and
# reads only the candidate files. The regex tier prefilters on the required
# literal / alternation cover set when one exists, and for the no-literal case
# the scanner skips dead spans via the compiled first-byte set (`;$`, `[0-9]{4}`)
# or seeds only at line starts (`^…`).
#
# rg's path: its native gitignore-respecting parallel walk (skips target/, caches
# — its real speed), `(?-u)` byte semantics so the dialects coincide exactly,
# `-l` (list files, early-out per file), warmed. NOT `--no-ignore`: that drags rg
# through 99 GB of build artifacts gist never indexes — crippling it, not racing
# it. Both fresh-process via hyperfine, warm page cache.
#
# Patterns are grouped by the feature each exercises. Usage: bench/regex_headtohead.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$KERNEL/../../.." && pwd)"
EXE="$REPO/.local/gist-bin"
ROOTS=(services libs clients contracts scripts quality)
command -v hyperfine >/dev/null || { echo "need hyperfine"; exit 1; }
command -v rg >/dev/null || { echo "need ripgrep"; exit 1; }

echo "building gist + persisting the index once…"
( cd "$KERNEL" && zig build -Doptimize=ReleaseFast cli -- index ) || exit 1
cp "$(ls -t "$KERNEL"/.zig-cache/o/*/gist-bench | head -1)" "$EXE"

# single-token-label  pattern  — label names the feature tier each pattern exercises.
slate=(
  "lit+word     func\\s+\\w+\\("
  "lit+word     return\\s+nil"
  "lit+class    pgxpool\\.\\w+"
  "anchor^lit   ^package\\s+\\w+"
  "anchor^lit   ^func\\s"
  "anchor-lit\$  ;\$"
  "anchor-lit\$  \\)\$"
  "anchor^lit\$ ^\\}\$"
  "anchor-empty ^\$"
  "count-class  [0-9]{4}"
  "count-word   \\w{3,8}"
  "count-hex    [a-f0-9]{2,}"
  "alt-cover    return|continue|break"
  "alt-cover    func|struct|enum"
  "alt-cover    error|panic|fatal"
  "alt-mixed    panic|0x"
)

cd "$REPO" || exit 1
printf "%-13s %-22s %10s %10s %9s\n" "tier" "pattern" "gist_cold" "rg_best" "speedup"
printf "%-13s %-22s %10s %10s %9s\n" "-------------" "----------------------" "----------" "----------" "---------"
gj="$(mktemp)"; rj="$(mktemp)"
wins=0; total=0
for row in "${slate[@]}"; do
  read -r label pat <<< "$row"
  hyperfine --warmup 3 --runs 12 --export-json "$gj" "$EXE regex '$pat'"            >/dev/null 2>&1
  hyperfine --warmup 3 --runs 12 --export-json "$rj" "rg '(?-u)$pat' -l -- ${ROOTS[*]}" >/dev/null 2>&1
  g=$(python3 -c "import json;print('%.1f'%(json.load(open('$gj'))['results'][0]['mean']*1000))" 2>/dev/null || echo '?')
  r=$(python3 -c "import json;print('%.1f'%(json.load(open('$rj'))['results'][0]['mean']*1000))" 2>/dev/null || echo '?')
  s=$(python3 -c "print('%.2fx'%($r/$g))" 2>/dev/null || echo '?')
  total=$((total+1))
  python3 -c "import sys;sys.exit(0 if $r/$g>=1.0 else 1)" 2>/dev/null && wins=$((wins+1))
  printf "%-13s %-22s %8s ms %8s ms %8s\n" "$label" "$pat" "$g" "$r" "$s"
done
rm -f "$gj" "$rj"
echo "----"
echo "gist ≥ rg on $wins/$total patterns (≥1.0x). Prefilterable tiers win outright;"
echo "the no-literal full-scan tail is a pure automaton-throughput race (Pike VM"
echo "vs rg's lazy DFA) — see CHANGELOG 'regex scan accelerators'."
