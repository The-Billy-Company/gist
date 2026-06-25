#!/usr/bin/env bash
# gist vs ripgrep — head-to-head on the SAME slate, rg at its fastest.
#
# gist: warm resident-index full pipeline (filter + parallel verify), p50 of 200
#       runs, emitted to .local/gist-verify/bench.csv by `zig build bench`.
# rg:   its happy path — native parallel walk over the real dirs, `-l` (list
#       files, early-out per file), warmed, median of N runs via hyperfine.
#
# rg always re-walks + re-reads (no index); gist answers from RAM. We report the
# honest ratio per needle. Usage: bench/headtohead.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$KERNEL/../../.." && pwd)"
OUT="$REPO/.local/gist-verify"
ROOTS=(services libs clients contracts scripts quality)
command -v hyperfine >/dev/null || { echo "need hyperfine"; exit 1; }

echo "building gist + capturing warm latency…"
( cd "$KERNEL" && zig build -Doptimize=ReleaseFast bench >/dev/null 2>&1 ) || exit 1

cd "$REPO"
printf "%-18s %12s %12s %10s\n" "needle" "gist p50" "rg median" "speedup"
printf "%-18s %12s %12s %10s\n" "------------------" "------------" "------------" "----------"

tmp="$(mktemp)"
while IFS=$'\t' read -r needle gist_ns files; do
    gist_ms=$(awk "BEGIN{printf \"%.3f\", $gist_ns/1e6}")
    # rg at its fastest: native parallel walk, fixed-string, list-files, warmed.
    hyperfine --warmup 2 --runs 8 --export-json "$tmp" \
        "rg -F -l -- \"$needle\" ${ROOTS[*]}" >/dev/null 2>&1
    rg_ms=$(python3 -c "import json;print('%.3f'%(json.load(open('$tmp'))['results'][0]['mean']*1000))" 2>/dev/null || echo "?")
    if [ "$rg_ms" = "?" ]; then spd="?"; else
        spd=$(awk "BEGIN{printf \"%.1fx\", ($rg_ms)/($gist_ms)}")
    fi
    printf "%-18s %9s ms %9s ms %10s\n" "$needle" "$gist_ms" "$rg_ms" "$spd"
done < "$OUT/bench.csv"
rm -f "$tmp"
