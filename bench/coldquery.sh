#!/usr/bin/env bash
# gist vs ripgrep — the COLD / first query (the one rg used to win).
#
# Model: build the index ONCE (persist to disk), then every query is a fresh
# process that cold-loads the index and reads only the CANDIDATE files. rg has
# no index, so every invocation re-walks the whole tree and reads every byte.
#
# Both measured fresh-process via hyperfine (process spawn included), warm page
# cache. gist's edge is architectural: candidate-only IO vs rg's full walk.
# Usage: bench/coldquery.sh [needle...]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$KERNEL/../../.." && pwd)"
ROOTS=(services libs clients contracts scripts quality)
EXE="$REPO/.local/gist-bin"
command -v hyperfine >/dev/null || { echo "need hyperfine"; exit 1; }

echo "building gist + persisting the index once…"
( cd "$KERNEL" && zig build -Doptimize=ReleaseFast cli -- index ) || exit 1
# Snapshot the freshly-built exe to a stable path for repeated fresh-process runs.
cp "$(ls -t "$KERNEL"/.zig-cache/o/*/gist-bench | head -1)" "$EXE"

cd "$REPO"
needles=("$@"); [ ${#needles[@]} -eq 0 ] && needles=(pgxpool queryLiteral rate_limit context.Context func import)
printf "%-18s %12s %12s %10s\n" "needle" "gist cold" "rg cold" "speedup"
printf "%-18s %12s %12s %10s\n" "------------------" "------------" "------------" "----------"
gj="$(mktemp)"; rj="$(mktemp)"
for n in "${needles[@]}"; do
    hyperfine --warmup 3 --runs 10 --export-json "$gj" "$EXE query $n"            >/dev/null 2>&1
    hyperfine --warmup 3 --runs 10 --export-json "$rj" "rg -l -- $n ${ROOTS[*]}"  >/dev/null 2>&1
    g=$(python3 -c "import json;print('%.1f'%(json.load(open('$gj'))['results'][0]['mean']*1000))")
    r=$(python3 -c "import json;print('%.1f'%(json.load(open('$rj'))['results'][0]['mean']*1000))")
    s=$(python3 -c "print('%.1fx'%($r/$g))")
    printf "%-18s %9s ms %9s ms %10s\n" "$n" "$g" "$r" "$s"
done
rm -f "$gj" "$rj"
