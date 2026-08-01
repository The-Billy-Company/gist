#!/usr/bin/env bash
# gist phantom-walk parity — the permanent guard for the `tree.map` snapshot's
# safety claim: the persisted directory-membership snapshot
# (`src/corpus/index/phantom/treemap.zig`) is an ACCELERATION structure only. It
# answers "which names live in this directory" for a directory whose own clocks
# prove its membership unchanged, and it answers NOTHING about file content. So
# for every query, a phantom-served run MUST have the same byte-exact line
# multiset as the same run with `GIST_NO_PHANTOM=1` (every directory listed
# live). The parallel engine streams worker-discovery order, so independent runs
# compare the line multiset (C-locale sorted, duplicates retained), not
# incidental cross-file scheduling order.
#
# `GIST_NO_PHANTOM` was introduced as the escape hatch "for parity gates" and no
# gate consumed it; this is that gate. It is the differential twin of
# `index_elision_parity.sh` (oracle: `--no-index`) with the snapshot as the
# subject instead of the trigram index.
#
# Two branches must both be exercised, because the walk CHOOSES between them per
# directory on cost (`descent.zig` `servePhantomDir` vs `phantom_stat_budget`): a
# snapshot-served entry carries no timestamps, so when the walk wants clocks each
# admitted file pays its own `lstat`, and that only undercuts the live listing it
# replaces while the admitted count stays under the budget.
#
#   * the `broad-*` cases admit every child, so the walk declines the snapshot
#     and lists live — parity here is the guard that declining is invisible;
#   * the `glob-*` cases admit ~one child per directory, so the snapshot serves
#     and the per-file `lstat` recovers the clocks — parity here is the guard on
#     the phantom path proper, and `glob-content-edit` below is its adverse case.
#
# The freshness cases are the ones that matter most. A directory's mtime/ctime
# move on MEMBERSHIP change only (POSIX: create/unlink/rename of a direct
# child), NOT on a child's content being rewritten in place. So a content edit
# leaves the directory provably "unchanged" and still phantom-servable — and the
# needle it just gained may only be found because the admitted file's own clocks
# were read live. `glob-content-edit` fails the moment that per-file freshness is
# dropped, which is precisely the false negative the snapshot could otherwise
# manufacture.
#
# Usage: bench/conformance/gates/parity/phantom_walk_parity.sh
set -uo pipefail
# Lift gist's default soft output cap so the two runs diff over identical full
# output (the hard OOM ceiling stays on) — same posture as the sibling gates.
export GIST_UNCAP=1
# The snapshot is a cold-path artifact; a resident session would answer from its
# own mirror and take both arms off the walk this gate is about.
export GIST_NO_AUTOSERVE=1
# Neutralize the internal knobs that would silently take both arms off the path
# under test. An inherited `GIST_TEST_REQUIRE_ELISION` makes every invocation die
# before it searches, and two empty outputs diff clean — 26 of these cases passed
# vacuously that way once. `GIST_NO_PHANTOM` is set per-arm by `chk`, so an
# inherited one would collapse the comparison to a single path.
unset GIST_TEST_REQUIRE_ELISION GIST_NO_PHANTOM GIST_NO_SHARD GIST_NO_INDEX GIST_ROOTS
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../../apparatus/roots.sh
source "${HERE}/../../../apparatus/roots.sh"
gist_resolve_roots "${HERE}" || exit 1

echo "building gist (ReleaseFast)…"
(cd "${PRODUCT}" && zig build -Doptimize=ReleaseFast > /dev/null 2>&1) || {
  echo "  build failed (engine may be mid-refactor by a coworker) — aborting"
  exit 1
}
GIST="${GIST:-${PRODUCT}/zig-out/bin/gist}"
[[ -x "${GIST}" ]] || GIST+=".exe"
[[ -x "${GIST}" ]] || {
  echo "  no gist binary at ${GIST%.exe}[.exe]"
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
cd "${WORK}" || exit 1
git init -q . 2> /dev/null || true # a repo so the rg-compat walk honors .gitignore
# Pin the artifact home INSIDE the throwaway tree. Without this the gate
# inherits whatever `GIST_DIR` the caller exported and `gist index` below
# overwrites that index with this 200-file corpus — silently destroying a
# developer's (or a sibling benchmark's) real artifacts, and leaving the gate
# asserting `tree.map` at a path it only guessed.
export GIST_DIR="${WORK}/.gist"

# Enough directories that the snapshot has real work to do, and a deliberate
# per-directory mix: many `.zig` files (so an unfiltered query admits far more
# than the live listing costs) beside exactly one `.rst` (so a `-g '*.rst'`
# query admits one child and the snapshot wins). A .gitignored and a hidden file
# cover the admission-widening flags, which can only ever RE-admit a subtree the
# snapshot never descended — that subtree walks live.
for d in libs libs/deep libs/deep/nested libs/other libs/other/leaf; do
  mkdir -p "${d}"
  for i in $(seq 1 40); do printf 'package noise\nfn f%d() void {}\n' "${i}" > "${d}/noise_${i}.zig"; done
  printf 'plain prose, no needle\n' > "${d}/notes.rst"
done
printf 'const needle_alpha = 1;\nfn Handler() void {}\n' > libs/hit_a.zig
printf 'fn Handler() void {}\n// needle_alpha again\n' > libs/deep/hit_b.zig
printf 'const NEEDLE_ALPHA = 2; // caseless-only hit\n' > libs/deep/nested/hit_c.zig
printf 'needle_alpha in prose\n' > libs/other/leaf/notes.rst
printf 'secret needle_alpha\n' > libs/ignored.zig && echo 'ignored.zig' > libs/.gitignore
printf 'hidden needle_alpha\n' > libs/.hidden.zig

# A deliberately LONG relative path. `--iglob` is the only path filter that
# allocates (it case-folds the glob AND the path, once per pattern), and the
# phantom pre-pass folds on a fixed stack buffer, so its capacity guard is a
# function of path length × pattern count. Short paths would never reach it.
LONGDIR="libs"
for i in 1 2 3 4 5 6; do LONGDIR="${LONGDIR}/deeply_nested_path_segment_${i}"; done
mkdir -p "${LONGDIR}"
printf 'needle_alpha at the end of a very long path\n' > "${LONGDIR}/notes.rst"
printf 'package noise\n' > "${LONGDIR}/noise_1.zig"

echo "indexing throwaway corpus…"
"${GIST}" index > /dev/null 2>&1 || {
  echo "  gist index failed"
  exit 1
}
# The snapshot is what this gate is about; without it both arms are the same
# live walk and every case would pass vacuously.
[[ -s "${GIST_DIR}/tree.map" ]] || {
  echo "  no tree.map published under ${GIST_DIR} — gate would pass vacuously"
  exit 1
}

fails=0
# Positive control. Every case below compares two runs, so two runs that both
# emit NOTHING agree perfectly — a binary that dies on startup would score a
# clean sweep. Prove the corpus is actually being walked and matched before any
# agreement is allowed to count as evidence.
control_files="$("${GIST}" --files < /dev/null 2> /dev/null | wc -l | tr -d ' ')"
control_hits="$("${GIST}" -l needle_alpha < /dev/null 2> /dev/null | wc -l | tr -d ' ')"
if [[ "${control_files}" -lt 200 || "${control_hits}" -ne 4 ]]; then
  echo "  positive control FAILED: walked ${control_files} files (want ≥200), found ${control_hits} needle files (want 4)"
  echo "  every parity case would agree vacuously — refusing to report a pass"
  exit 1
fi
echo "positive control: ${control_files} files walked, ${control_hits} needle files found"

# One case: assert the phantom-served run has the same line multiset as the
# all-live-listing run. Every emitted line stays byte-exact and duplicate counts
# stay load-bearing; only cross-file scheduling order is normalized.
chk() {
  local label="$1"
  shift
  GIST_NO_PHANTOM=1 "${GIST}" "$@" < /dev/null > "${WORK}/.a" 2> /dev/null
  local ea=$?
  "${GIST}" "$@" < /dev/null > "${WORK}/.b" 2> /dev/null
  local eb=$?
  if [[ "${ea}" -ne "${eb}" ]]; then
    printf "  FAIL  %-24s exit differs (no-phantom=%s phantom=%s)\n" "${label}" "${ea}" "${eb}"
    fails=$((fails + 1))
    return
  fi
  LC_ALL=C sort "${WORK}/.a" > "${WORK}/.a.norm"
  LC_ALL=C sort "${WORK}/.b" > "${WORK}/.b.norm"
  if diff -q "${WORK}/.a.norm" "${WORK}/.b.norm" > /dev/null; then
    printf "  ok    %-24s (%s lines)\n" "${label}" "$(wc -l < "${WORK}/.a" | tr -d ' ')"
  else
    printf "  FAIL  %-24s stdout differs:\n" "${label}"
    diff "${WORK}/.a.norm" "${WORK}/.b.norm" | head -12 | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

echo
echo "### phantom-served ≡ all-live-listing (the gate) ###"
# Broad classes: every child is admitted, so the walk declines the snapshot per
# directory. Parity proves declining changes nothing but syscalls.
chk "broad-literal" needle_alpha
chk "broad-lines" -n needle_alpha
chk "broad-regex" 'needle_\w+'
chk "broad-caseless" -i needle_alpha
chk "broad-files-with" -l needle_alpha
chk "broad-files-without" --files-without-match needle_alpha
chk "broad-count" -c needle_alpha
chk "broad-context" -C1 needle_alpha
chk "broad-invert" -v needle_alpha
chk "broad-no-match" zzz_nonexistent_qxv
# `--files` wants no clocks at all, so the snapshot serves EVERY directory —
# the one class that is pure phantom with no per-file lstat.
chk "files-listing" --files
chk "files-listing-glob" --files -g '*.rst'

# Filtered classes: ~one admitted child per directory, so the snapshot serves
# and the per-file lstat recovers the clocks index elision needs.
chk "glob-rst" -g '*.rst' needle_alpha
chk "glob-rst-lines" -n -g '*.rst' needle_alpha
chk "glob-rst-files" -l -g '*.rst' needle_alpha
chk "type-scoped" -tzig needle_alpha
# `-g` un-hides AND un-ignores; a type filter only un-hides. Both widen
# admission past what the snapshot recorded, so both must re-walk live.
chk "glob-unhide-unignore" -g '*.zig' needle_alpha
chk "path-scoped" needle_alpha libs/deep

# `--iglob` is the one path filter whose verdict ALLOCATES, and the phantom
# pre-pass folds on a fixed stack buffer whose `lowerDup` aborts the process
# rather than reporting a short buffer. So the pre-pass must prove capacity
# before it folds, and decline the directory when it cannot. All three widths
# below must agree with the live listing: one pattern (fits trivially), many
# patterns over the long path built above (approaches the bound), and patterns so
# wide the guard MUST trip and route every directory to the live listing.
chk "iglob-single" --iglob '*.RST' needle_alpha
iglobs_many=()
for i in $(seq 1 24); do iglobs_many+=(--iglob "*.RS${i}T"); done
chk "iglob-many" "${iglobs_many[@]}" --iglob '*.RST' needle_alpha
iglobs_wide=()
for i in $(seq 1 12); do iglobs_wide+=(--iglob "*$(printf 'X%.0s' $(seq 1 500))${i}"); done
chk "iglob-fold-overflow" "${iglobs_wide[@]}" --iglob '*.RST' needle_alpha
# Non-vacuity for the three cases above: a caseless `*.RST` must actually reach
# the `.rst` hits (including the one at the end of the long path), or all three
# would be agreeing on an empty set.
iglob_hits="$("${GIST}" -l --iglob '*.RST' needle_alpha < /dev/null 2> /dev/null | wc -l | tr -d ' ')"
iglob_wide_hits="$("${GIST}" -l "${iglobs_wide[@]}" --iglob '*.RST' needle_alpha < /dev/null 2> /dev/null | wc -l | tr -d ' ')"
if [[ "${iglob_hits}" -eq 2 && "${iglob_wide_hits}" -eq 2 ]]; then
  printf "  ok    %-24s (caseless glob reached %s .rst hits, fold-guarded run agreed)\n" "iglob-not-vacuous" "${iglob_hits}"
else
  printf "  FAIL  %-24s --iglob '*.RST' found %s hits (want 2), fold-guarded %s (want 2)\n" "iglob-not-vacuous" "${iglob_hits}" "${iglob_wide_hits}"
  fails=$((fails + 1))
fi

echo
echo "### freshness: content change under an unchanged directory ###"
# A rewrite in place does NOT move the parent directory's clocks, so the
# directory stays phantom-servable while the FILE is stale. The needle must
# still be found — this is the adverse case for per-file freshness on the
# phantom path, and the exact false negative the snapshot could manufacture.
sleep 1
printf 'needle_alpha arrives post-index\n' >> libs/deep/notes.rst
printf '\nfn late() void {} // needle_alpha arrives post-index\n' >> libs/noise_7.zig
chk "glob-content-edit" -g '*.rst' needle_alpha
chk "glob-content-edit-lines" -n -g '*.rst' needle_alpha
chk "broad-content-edit" needle_alpha
# The gained needle must actually be REACHED, not merely agreed upon: two runs
# that both miss it would diff clean. Assert the post-index hit is present.
if "${GIST}" -l -g '*.rst' needle_alpha < /dev/null 2> /dev/null | grep -q 'libs/deep/notes.rst'; then
  printf "  ok    %-24s (post-index hit reached through the snapshot)\n" "glob-edit-not-missed"
else
  printf "  FAIL  %-24s post-index needle NOT found — stale snapshot served a false negative\n" "glob-edit-not-missed"
  fails=$((fails + 1))
fi

echo
echo "### freshness: membership change stales the directory ###"
# Create, delete, and rename each move the parent's clocks, so the directory
# must fall back to the live listing. A snapshot that kept serving would report
# a vanished file or miss a new one.
sleep 1
printf 'needle_alpha in a brand new file\n' > libs/other/added.rst
rm -f libs/other/leaf/notes.rst
mv libs/deep/nested/hit_c.zig libs/deep/nested/renamed_c.zig
chk "member-added" needle_alpha
chk "member-added-files" -l needle_alpha
chk "member-added-listing" --files
chk "member-glob" -g '*.rst' needle_alpha
if "${GIST}" -l needle_alpha < /dev/null 2> /dev/null | grep -q 'libs/other/added.rst' &&
  ! "${GIST}" --files < /dev/null 2> /dev/null | grep -q 'libs/other/leaf/notes.rst'; then
  printf "  ok    %-24s (new file found, deleted file gone)\n" "member-reflected"
else
  printf "  FAIL  %-24s snapshot served stale membership\n" "member-reflected"
  fails=$((fails + 1))
fi

echo
if [[ "${fails}" -eq 0 ]]; then
  echo "PROVEN: every query's phantom-served output has the same byte-exact line multiset as its all-live-listing run, across both the declined (broad) and served (filtered) branches — the snapshot changes syscalls, never results (per-file content freshness and membership staleness both verified)."
else
  echo "FAILED: ${fails} case(s) diverged — the phantom snapshot is altering results, not just accelerating. See the table above."
  exit 1
fi
