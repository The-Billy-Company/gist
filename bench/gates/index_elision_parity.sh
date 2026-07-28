#!/usr/bin/env bash
# gist index-elision parity — the permanent guard for the unified engine's core
# safety claim: the persisted trigram index is an ACCELERATION structure only,
# never a semantic one. `gist <pattern>` uses the index solely to elide *reading*
# files the live walk already found but that provably can't match (see
# `src/exec/cold/engine/serial.zig` `IndexSkip`); the walk stays the sole
# authority on the file set, ignore semantics, and per-file output. So for every
# query, the index-accelerated run MUST have the same byte-exact line multiset as
# `--no-index` (a full live read of every walked file). The parallel engine
# intentionally streams worker-discovery order, so independent runs compare the
# line multiset (C-locale sorted, duplicates retained), not incidental cross-file
# scheduling order. This gate proves exactly that — the differential twin of
# `scan_regress.sh` (which proves the live scan
# ≡ rg) and rgsuite (which proves the walk ≡ rg): here the oracle is gist's own
# `--no-index` path, so "the index only changes speed, never results" is
# continuously verified, not merely asserted (sins.mdc: truth, not vibes).
#
# Hermetic: builds a throwaway corpus under one of gist's indexed roots (`libs/`
# so `gist index`'s default_roots covers it), indexes it, then diffs auto-index
# vs --no-index across a battery of modes — INCLUDING a post-index edit, to prove
# the freshness overlay (`corpus/fresh.zig`) closes the stale-index gap (a file
# that GAINS the needle after the build is still found, no false negative).
#
# `gist index` also emits the content shard (`corpus/index/content/shard.zig`),
# so the same oracle covers it for free: `--no-index` forces the pure live walk
# (shard OFF), while the auto run serves unchanged files from the shard mmap —
# the 2-byte-literal `shard-*` cases below are the full-scan classes with no
# trigram prefilter, where every matching file rides the shard, and
# `shard-freshness` proves a post-index edit defeats a stale shard slice.
#
# Usage: bench/gates/index_elision_parity.sh
set -uo pipefail
# Lift gist's default soft output cap so the auto-index vs --no-index diff sees
# identical full output (the hard OOM ceiling stays on).
export GIST_UNCAP=1
HERE="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$(cd "${HERE}/../.." && pwd)" # pkg/kernels/irregex

echo "building gist (ReleaseFast)…"
(cd "${KERNEL}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
  exit 1
}
GIST="${KERNEL}/zig-out/bin/gist"
[[ -x "${GIST}" ]] || {
  echo "  no gist binary at ${GIST}"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1
git init -q . 2> /dev/null || true # a repo so the rg-compat walk honors .gitignore

# A corpus with signal + noise: a handful of files that DO contain the needles
# scattered among many that don't (so elision has something to elide), plus a
# .gitignored file and a hidden file. Both are invisible to the DEFAULT walk,
# but a `-t`/`-g` query un-hides/un-ignores them (rg parity): the `type-scoped`
# case below (`-tzig`) surfaces `.hidden.zig`, so the index-accelerated run must
# too — the guard against the warm mirror silently omitting an un-hidden file.
mkdir -p libs/deep/nested
for i in $(seq 1 200); do printf 'package noise\nfn f%d() void {}\n' "${i}" > "libs/noise_${i}.zig"; done
printf 'const needle_alpha = 1;\nfn Handler() void {}\n' > libs/hit_a.zig
printf 'fn Handler() void {}\n// needle_alpha again\n' > libs/deep/hit_b.zig
printf 'const NEEDLE_ALPHA = 2; // caseless-only hit\n' > libs/deep/nested/hit_c.zig
printf 'secret needle_alpha\n' > libs/ignored.zig && echo 'ignored.zig' > libs/.gitignore
printf 'hidden needle_alpha\n' > libs/.hidden.zig

echo "indexing throwaway corpus…"
"${GIST}" index > /dev/null 2>&1 || {
  echo "  gist index failed"
  exit 1
}

fails=0
# One case: assert auto-index stdout has the same line multiset as --no-index.
# Every emitted line remains byte-exact and duplicate counts remain load-bearing;
# only cross-file scheduling order is normalized.
chk() {
  local label="$1"
  shift
  "${GIST}" "$@" --no-index < /dev/null > "${WORK}/.a" 2> /dev/null
  local ea=$?
  "${GIST}" "$@" < /dev/null > "${WORK}/.b" 2> /dev/null
  local eb=$?
  if [[ "${ea}" -ne "${eb}" ]]; then
    printf "  FAIL  %-22s exit differs (no-index=%s auto=%s)\n" "${label}" "${ea}" "${eb}"
    fails=$((fails + 1))
    return
  fi
  LC_ALL=C sort "${WORK}/.a" > "${WORK}/.a.norm"
  LC_ALL=C sort "${WORK}/.b" > "${WORK}/.b.norm"
  if diff -q "${WORK}/.a.norm" "${WORK}/.b.norm" > /dev/null; then
    local lines
    lines=$(wc -l < "${WORK}/.a" | tr -d ' ')
    printf "  ok    %-22s (%s lines)\n" "${label}" "${lines}"
  else
    printf "  FAIL  %-22s stdout differs:\n" "${label}"
    diff "${WORK}/.a.norm" "${WORK}/.b.norm" | head -12 | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

echo
echo "### index-elided ≡ full live read (the gate) ###"
chk "literal" needle_alpha
chk "literal-lines" -n needle_alpha
chk "regex" 'needle_\w+'
chk "caseless" -i needle_alpha
chk "word" -w needle_alpha
chk "count" -c needle_alpha
chk "files-with" -l needle_alpha
chk "files-without" --files-without-match needle_alpha
chk "context" -C1 needle_alpha
chk "invert" -v needle_alpha
chk "only-matching" -o needle_alpha
chk "no-match" zzz_nonexistent_qxv
chk "type-scoped" -tzig needle_alpha
# `-tzig` un-HIDES `.hidden.zig` (a dotfile) but must NOT un-ignore `ignored.zig`
# (a type filter never un-ignores — rg parity); `-g '*.zig'` un-hides AND
# un-ignores, so it surfaces BOTH. These are the reachable file-level extras the
# default walk skips: the warm mirror lacks them, so the daemon must decline a
# filtered query to cold rather than answer short (the flagship parity claim).
chk "glob-unhide-unignore" -g '*.zig' needle_alpha
chk "path-scoped" needle_alpha libs/deep

# Content-shard path: a 2-byte literal extracts no trigram, so the index cannot
# prefilter — the auto run serves every unchanged file's bytes from the mmap'd
# `content.shard` while `--no-index` opens each live. Same body, so the multiset
# must match. These are the full-scan classes the shard exists to win (`{}`/`()`
# appear in nearly every noise file); `--no-index` disables the shard too, so it
# stays the pure-live oracle.
chk "shard-2byte" -F '{}'
chk "shard-2byte-lines" -nF '()'
chk "shard-2byte-count" -cF '{}'
chk "shard-2byte-files" -lF '{}'

# Freshness: append the needle to a file that had NONE at index time. The index's
# trigram data for it is now stale (says "no needle"); the freshness overlay must
# still force it to be read (mtime > build anchor) so the auto run finds it — else
# a silent false negative. Both runs must still agree.
sleep 1
printf '\nfn late() void {} // needle_alpha arrives post-index\n' >> libs/noise_7.zig
chk "freshness-gained" needle_alpha
chk "freshness-lines" -n needle_alpha
# Shard freshness: the same post-index edit added a `{}`/`()` pair to a file the
# shard snapshotted WITHOUT it. The 2-byte full-scan run must reject that stale
# slice (mtime > anchor) and read the file live, or its count falls short.
chk "shard-freshness" -cF '{}'
chk "shard-freshness-lines" -nF '()'

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: every query's index-accelerated output has the same byte-exact line multiset as its --no-index full read — the index changes speed, never results (freshness overlay verified)."
else
  echo "FAILED: ${fails} case(s) diverged — the index is altering results, not just accelerating. See the table above."
  exit 1
fi
