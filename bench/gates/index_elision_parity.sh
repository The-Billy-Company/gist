#!/usr/bin/env bash
# gist index-elision parity — the permanent guard for the unified engine's core
# safety claim: the persisted trigram index is an ACCELERATION structure only,
# never a semantic one. `gist <pattern>` uses the index solely to elide *reading*
# files the live walk already found but that provably can't match (see
# `src/commands/ripgrep/run.zig` `IndexSkip`); the walk stays the sole authority
# on the file set, ignore semantics, ordering, and output. So for every query,
# the index-accelerated run MUST be byte-for-byte identical to the same run with
# `--no-index` (a full live read of every walked file). This gate proves exactly
# that — the differential twin of `scan_regress.sh` (which proves the live scan
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
# .gitignored file and a hidden file (both must be walk-invisible either way).
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
# One case: assert auto-index stdout == --no-index stdout, byte-for-byte.
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
  if diff -q "${WORK}/.a" "${WORK}/.b" > /dev/null; then
    local lines
    lines=$(wc -l < "${WORK}/.a" | tr -d ' ')
    printf "  ok    %-22s (%s lines)\n" "${label}" "${lines}"
  else
    printf "  FAIL  %-22s stdout differs:\n" "${label}"
    diff "${WORK}/.a" "${WORK}/.b" | head -12 | sed 's/^/        /'
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
chk "path-scoped" needle_alpha libs/deep

# Freshness: append the needle to a file that had NONE at index time. The index's
# trigram data for it is now stale (says "no needle"); the freshness overlay must
# still force it to be read (mtime > build anchor) so the auto run finds it — else
# a silent false negative. Both runs must still agree.
sleep 1
printf '\nfn late() void {} // needle_alpha arrives post-index\n' >> libs/noise_7.zig
chk "freshness-gained" needle_alpha
chk "freshness-lines" -n needle_alpha

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: every query's index-accelerated output is byte-identical to its --no-index full read — the index changes speed, never results (freshness overlay verified)."
else
  echo "FAILED: ${fails} case(s) diverged — the index is altering results, not just accelerating. See the table above."
  exit 1
fi
